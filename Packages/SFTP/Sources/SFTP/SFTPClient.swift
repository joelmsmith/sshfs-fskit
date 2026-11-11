import Foundation

/// An SFTP v3 client. Thread-safe; any number of calls may be in flight.
public final class SFTPClient: Sendable {
    public let serverVersion: UInt32
    /// Extensions advertised in VERSION, e.g. `posix-rename@openssh.com` -> `1`.
    public let serverExtensions: [String: String]
    public let limits: ServerLimits

    private let connection: Connection

    private init(connection: Connection, version: UInt32,
                 extensions: [String: String], limits: ServerLimits) {
        self.connection = connection
        self.serverVersion = version
        self.serverExtensions = extensions
        self.limits = limits
    }

    /// Performs the SFTP handshake over `transport`.
    public static func connect(transport: SFTPTransport) async throws -> SFTPClient {
        let connection = Connection(transport: transport)
        do {
            let response = try await connection.handshake(version: 3)
            var r = response.reader
            let version = try r.u32()
            guard version == 3 else { throw SFTPError.unsupportedVersion(version) }
            var extensions: [String: String] = [:]
            while r.remaining > 0 {
                extensions[try r.string()] = try r.string()
            }
            var limits = ServerLimits.fallback
            if extensions["limits@openssh.com"] != nil {
                let reply = try await connection.request(.extended) { $0.string("limits@openssh.com") }
                var lr = try expect(.extendedReply, reply)
                limits = ServerLimits(maxPacketLength: try lr.u64(), maxReadLength: try lr.u64(),
                                      maxWriteLength: try lr.u64(), maxOpenHandles: try lr.u64())
            }
            return SFTPClient(connection: connection, version: version,
                              extensions: extensions, limits: limits)
        } catch {
            connection.fail(.connectionLost("handshake failed"))
            throw error
        }
    }

    /// Non-nil once the connection has died; every call then fails with it.
    public var failure: SFTPError? { connection.failure }

    public func disconnect() {
        connection.fail(.connectionLost("disconnected"))
    }

    public func supports(_ ext: String) -> Bool { serverExtensions[ext] != nil }

    // MARK: Paths and metadata

    public func realpath(_ path: String) async throws -> String {
        let names = try await names(.realpath) { $0.string(path) }
        guard let first = names.first else { throw SFTPError.badMessage("empty REALPATH reply") }
        return first.filename
    }

    public func stat(_ path: String) async throws -> FileAttributes {
        try await attrs(.stat) { $0.string(path) }
    }

    public func lstat(_ path: String) async throws -> FileAttributes {
        try await attrs(.lstat) { $0.string(path) }
    }

    public func fstat(_ handle: Handle) async throws -> FileAttributes {
        try await attrs(.fstat) { $0.string(handle.bytes) }
    }

    public func setstat(_ path: String, _ attributes: FileAttributes) async throws {
        try await status(.setstat) { $0.string(path); $0.attributes(attributes) }
    }

    /// Like `setstat`, but on a symlink itself rather than what it points
    /// to (`lsetstat@openssh.com`).
    public func lsetstat(_ path: String, _ attributes: FileAttributes) async throws {
        guard supports("lsetstat@openssh.com") else {
            throw SFTPError.status(code: StatusCode.operationUnsupported.rawValue, message: "lsetstat")
        }
        try await status(.extended) {
            $0.string("lsetstat@openssh.com"); $0.string(path); $0.attributes(attributes)
        }
    }

    public func fsetstat(_ handle: Handle, _ attributes: FileAttributes) async throws {
        try await status(.fsetstat) { $0.string(handle.bytes); $0.attributes(attributes) }
    }

    public func readlink(_ path: String) async throws -> String {
        let names = try await names(.readlink) { $0.string(path) }
        guard let first = names.first else { throw SFTPError.badMessage("empty READLINK reply") }
        return first.filename
    }

    /// Creates a symlink at `linkPath` pointing to `target`.
    public func symlink(target: String, linkPath: String) async throws {
        // OpenSSH's sftp-server takes the arguments in the opposite order from
        // the draft spec (target first). Every server that matters is OpenSSH
        // or copies its behaviour, so we follow OpenSSH.
        try await status(.symlink) { $0.string(target); $0.string(linkPath) }
    }

    public func hardlink(existing: String, newPath: String) async throws {
        guard supports("hardlink@openssh.com") else {
            throw SFTPError.status(code: StatusCode.operationUnsupported.rawValue, message: "hardlink")
        }
        try await status(.extended) {
            $0.string("hardlink@openssh.com"); $0.string(existing); $0.string(newPath)
        }
    }

    public func mkdir(_ path: String, attributes: FileAttributes = .init()) async throws {
        try await status(.mkdir) { $0.string(path); $0.attributes(attributes) }
    }

    public func rmdir(_ path: String) async throws {
        try await status(.rmdir) { $0.string(path) }
    }

    public func remove(_ path: String) async throws {
        try await status(.remove) { $0.string(path) }
    }

    /// Renames, atomically replacing `newPath` if it exists, when the server
    /// supports `posix-rename@openssh.com`. Plain SFTP v3 RENAME fails if the
    /// target exists.
    public func rename(_ oldPath: String, to newPath: String) async throws {
        if supports("posix-rename@openssh.com") {
            try await status(.extended) {
                $0.string("posix-rename@openssh.com"); $0.string(oldPath); $0.string(newPath)
            }
        } else {
            try await status(.rename) { $0.string(oldPath); $0.string(newPath) }
        }
    }

    public func statvfs(_ path: String) async throws -> FileSystemStatistics {
        guard supports("statvfs@openssh.com") else {
            throw SFTPError.status(code: StatusCode.operationUnsupported.rawValue, message: "statvfs")
        }
        let reply = try await connection.request(.extended) {
            $0.string("statvfs@openssh.com"); $0.string(path)
        }
        var r = try Self.expect(.extendedReply, reply)
        return FileSystemStatistics(
            blockSize: try r.u64(), fragmentSize: try r.u64(), blocks: try r.u64(),
            freeBlocks: try r.u64(), availableBlocks: try r.u64(), files: try r.u64(),
            freeFiles: try r.u64(), availableFiles: try r.u64(), fsid: try r.u64(),
            flags: try r.u64(), maxNameLength: try r.u64())
    }

    // MARK: Directories

    public func opendir(_ path: String) async throws -> Handle {
        try await handle(.opendir) { $0.string(path) }
    }

    /// One READDIR batch, or nil at end of directory.
    public func readdir(_ handle: Handle) async throws -> [DirectoryEntry]? {
        do {
            return try await names(.readdir) { $0.string(handle.bytes) }
        } catch let e as SFTPError where e.statusCode == .eof {
            return nil
        }
    }

    /// Lists a whole directory, excluding `.` and `..`.
    public func listDirectory(_ path: String) async throws -> [DirectoryEntry] {
        let h = try await opendir(path)
        var all: [DirectoryEntry] = []
        do {
            while let batch = try await readdir(h) {
                all += batch.filter { $0.filenameBytes != [0x2E] && $0.filenameBytes != [0x2E, 0x2E] }
            }
        } catch {
            try? await close(h)
            throw error
        }
        try await close(h)
        return all
    }

    // MARK: Files

    public func open(_ path: String, flags: OpenFlags,
                     attributes: FileAttributes = .init()) async throws -> Handle {
        try await handle(.open) { $0.string(path); $0.u32(flags.rawValue); $0.attributes(attributes) }
    }

    public func close(_ handle: Handle) async throws {
        try await status(.close) { $0.string(handle.bytes) }
    }

    /// A single READ request. Returns nil at EOF. May return fewer bytes than
    /// asked for, even before EOF.
    public func readChunk(_ handle: Handle, offset: UInt64, length: UInt32) async throws -> [UInt8]? {
        let reply = try await connection.request(.read) {
            $0.string(handle.bytes); $0.u64(offset); $0.u32(length)
        }
        if reply.type == .status {
            var r = reply.reader
            let code = try r.u32()
            if code == StatusCode.eof.rawValue { return nil }
            throw SFTPError.status(code: code, message: (try? r.string()) ?? "")
        }
        var r = try Self.expect(.data, reply)
        return try r.bytesString()
    }

    /// Reads up to `length` bytes, issuing pipelined requests no larger than
    /// the server's read limit. Returns fewer bytes only at EOF.
    public func read(_ handle: Handle, offset: UInt64, length: Int) async throws -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(length)
        var position = offset
        var remaining = length
        let chunk = Int(min(limits.maxReadLength, 256 * 1024))

        while remaining > 0 {
            // Issue a window of concurrent requests.
            let window = min((remaining + chunk - 1) / chunk, 16)
            let parts = try await withThrowingTaskGroup(of: (Int, [UInt8]?).self) { group in
                for i in 0..<window {
                    let off = position + UInt64(i * chunk)
                    let len = UInt32(min(chunk, remaining - i * chunk))
                    group.addTask { (i, try await self.readChunk(handle, offset: off, length: len)) }
                }
                var parts = [[UInt8]?](repeating: nil, count: window)
                for try await (i, data) in group { parts[i] = data }
                return parts
            }
            // Consume in order; stop at the first short or EOF chunk and
            // resume from there (a short chunk mid-file is legal).
            var progressed = 0
            for (i, part) in parts.enumerated() {
                let asked = min(chunk, remaining - i * chunk)
                guard let part else { return result } // EOF
                result += part
                progressed += part.count
                if part.count < asked { break }
            }
            if progressed == 0 { break }
            position += UInt64(progressed)
            remaining -= progressed
        }
        return result
    }

    /// Writes all of `data` at `offset`, split into pipelined requests.
    public func write<D: Collection & Sendable>(_ handle: Handle, offset: UInt64, data: D) async throws
    where D.Element == UInt8, D.Index == Int {
        let chunk = Int(min(limits.maxWriteLength, 256 * 1024))
        let bytes = Array(data)
        guard !bytes.isEmpty else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var start = 0
            var inFlight = 0
            while start < bytes.count {
                let end = min(start + chunk, bytes.count)
                let slice = bytes[start..<end]
                let off = offset + UInt64(start)
                if inFlight >= 16 { try await group.next(); inFlight -= 1 }
                group.addTask {
                    try await self.status(.write) { $0.string(handle.bytes); $0.u64(off); $0.string(slice) }
                }
                inFlight += 1
                start = end
            }
            try await group.waitForAll()
        }
    }

    /// Flushes a file to stable storage on the server, if supported.
    public func fsync(_ handle: Handle) async throws {
        guard supports("fsync@openssh.com") else { return }
        try await status(.extended) { $0.string("fsync@openssh.com"); $0.string(handle.bytes) }
    }

    // MARK: Response helpers

    private static func expect(_ type: PacketType, _ reply: Response) throws -> WireReader {
        var r = reply.reader
        if reply.type == type { return r }
        if reply.type == .status {
            let code = try r.u32()
            let message = (try? r.string()) ?? ""
            throw SFTPError.status(code: code, message: message)
        }
        throw SFTPError.badMessage("expected \(type), got \(reply.type)")
    }

    private func status(_ type: PacketType, _ body: (inout WireWriter) -> Void) async throws {
        let reply = try await connection.request(type, body)
        var r = try Self.expect(.status, reply)
        let code = try r.u32()
        guard code == StatusCode.ok.rawValue else {
            throw SFTPError.status(code: code, message: (try? r.string()) ?? "")
        }
    }

    private func handle(_ type: PacketType, _ body: (inout WireWriter) -> Void) async throws -> Handle {
        let reply = try await connection.request(type, body)
        var r = try Self.expect(.handle, reply)
        return Handle(bytes: try r.bytesString())
    }

    private func attrs(_ type: PacketType, _ body: (inout WireWriter) -> Void) async throws -> FileAttributes {
        let reply = try await connection.request(type, body)
        var r = try Self.expect(.attrs, reply)
        return try r.attributes()
    }

    private func names(_ type: PacketType, _ body: (inout WireWriter) -> Void) async throws -> [DirectoryEntry] {
        let reply = try await connection.request(type, body)
        var r = try Self.expect(.name, reply)
        let count = try r.u32()
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            entries.append(DirectoryEntry(filenameBytes: try r.bytesString(),
                                          longname: try r.string(),
                                          attributes: try r.attributes()))
        }
        return entries
    }
}
