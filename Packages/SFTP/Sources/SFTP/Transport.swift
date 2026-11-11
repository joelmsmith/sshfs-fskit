import Foundation

/// A bidirectional byte stream to an SFTP server: one fd to read server
/// output from, one to write requests to (they may be the same socket).
///
/// The transport owns the fds and closes them on `close()` / deinit.
public final class SFTPTransport: @unchecked Sendable {
    public let readFD: Int32
    public let writeFD: Int32
    private let process: Process?
    private let lock = NSLock()
    private var closed = false

    private let onClose: (@Sendable () -> Void)?
    private var stderrHandle: FileHandle?

    /// Wraps existing fds (e.g. pipes to an ssh that another process started
    /// and handed over). Takes ownership of all of them.
    ///
    /// - Parameters:
    ///   - stderrFD: if given, each line read from it goes to `stderrHandler`
    ///     (or is discarded without one, so the writer never blocks on it).
    ///   - onClose: runs once when the transport closes (e.g. to tell the
    ///     process that owns the peer to clean it up).
    public init(readFD: Int32, writeFD: Int32, stderrFD: Int32? = nil,
                stderrHandler: (@Sendable (String) -> Void)? = nil,
                onClose: (@Sendable () -> Void)? = nil) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.process = nil
        self.onClose = onClose
        Self.configure(writeFD)
        if let stderrFD {
            let handle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: true)
            Self.forwardLines(from: handle, to: stderrHandler ?? { _ in })
            stderrHandle = handle
        }
    }

    private init(readFD: Int32, writeFD: Int32, process: Process, stderrHandle: FileHandle?) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.process = process
        self.onClose = nil
        self.stderrHandle = stderrHandle
        Self.configure(writeFD)
    }

    private static func forwardLines(from handle: FileHandle, to handler: @escaping @Sendable (String) -> Void) {
        let buffer = LineBuffer(handler: handler)
        handle.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; buffer.finish() } else { buffer.append(data) }
        }
    }

    private static func configure(_ fd: Int32) {
        // Writing to a dead peer should return EPIPE, not kill us.
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    /// Spawns `executable` and speaks SFTP over its stdin/stdout.
    ///
    /// stderr is inherited unless `stderrHandler` is given, in which case each
    /// line the child writes to stderr is passed to it (useful where there is
    /// no terminal, e.g. inside an FSKit extension).
    public static func spawn(executable: URL, arguments: [String] = [],
                             environment: [String: String]? = nil,
                             stderrHandler: (@Sendable (String) -> Void)? = nil) throws -> SFTPTransport {
        let toChild = Pipe()
        let fromChild = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = toChild.fileHandleForReading
        process.standardOutput = fromChild.fileHandleForWriting
        var stderrHandle: FileHandle?
        if let stderrHandler {
            let errPipe = Pipe()
            process.standardError = errPipe
            forwardLines(from: errPipe.fileHandleForReading, to: stderrHandler)
            stderrHandle = errPipe.fileHandleForReading
        }
        try process.run()

        // Close the child's ends in our process so EOF propagates when it exits.
        try toChild.fileHandleForReading.close()
        try fromChild.fileHandleForWriting.close()

        // Take ownership of our ends as raw fds.
        let r = dup(fromChild.fileHandleForReading.fileDescriptor)
        let w = dup(toChild.fileHandleForWriting.fileDescriptor)
        try fromChild.fileHandleForReading.close()
        try toChild.fileHandleForWriting.close()
        guard r >= 0, w >= 0 else { throw SFTPError.connectionLost("dup failed: errno \(errno)") }
        return SFTPTransport(readFD: r, writeFD: w, process: process, stderrHandle: stderrHandle)
    }

    /// Runs `ssh ... -s <destination> sftp`, honouring the user's ssh config,
    /// keys and agent.
    public static func ssh(destination: String, port: Int? = nil, user: String? = nil,
                           options: [String] = [],
                           sshPath: String = "/usr/bin/ssh",
                           environment: [String: String]? = nil,
                           stderrHandler: (@Sendable (String) -> Void)? = nil) throws -> SFTPTransport {
        try spawn(executable: URL(fileURLWithPath: sshPath),
                  arguments: sshArguments(destination: destination, port: port, user: user, options: options),
                  environment: environment, stderrHandler: stderrHandler)
    }

    /// The arguments for `ssh` to start the sftp subsystem on `destination`.
    public static func sshArguments(destination: String, port: Int? = nil, user: String? = nil,
                                    options: [String] = []) -> [String] {
        var args = ["-x", "-a", "-o", "ClearAllForwardings=yes"]
        if let port { args += ["-p", String(port)] }
        if let user { args += ["-l", user] }
        for o in options { args += ["-o", o] }
        return args + ["-s", "--", destination, "sftp"]
    }

    /// The process ID of the spawned helper, if any.
    public var processIdentifier: Int32? { process?.processIdentifier }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(writeFD)
        if readFD != writeFD { Darwin.close(readFD) }
        // A grandchild of ssh (ProxyCommand, ControlMaster) may hold stderr
        // open long after ssh exits: stop reading it now rather than at EOF.
        stderrHandle?.readabilityHandler = nil
        try? stderrHandle?.close()
        if let process, process.isRunning {
            // SIGKILL rather than terminate(): a wedged or stopped child
            // (e.g. ssh stuck on a dead network) may never act on SIGTERM.
            kill(process.processIdentifier, SIGKILL)
        }
        onClose?()
    }

    deinit { close() }
}

/// Splits a byte stream into lines for a callback.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) { self.handler = handler }

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        lock.unlock()
        lines.forEach(handler)
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        if !rest.isEmpty { handler(String(decoding: rest, as: UTF8.self)) }
    }
}
