import Foundation
import SFTP

/// Talks to the helper (App/Helper.swift), which runs ssh outside our sandbox.
enum HelperClient {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// The helper only has to spawn a process; it answers in milliseconds.
    static let replyTimeout = 10.0

    /// Asks the helper to start `ssh arguments` and wraps the pipes it hands
    /// back. Closing the transport drops the XPC connection, which makes the
    /// helper kill that ssh.
    static func spawnSSH(arguments: [String], environment: [String: String],
                         stderrHandler: @escaping @Sendable (String) -> Void) async throws -> SFTPTransport {
        let connection = NSXPCConnection(machServiceName: helperMachService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: SSHFSHelperProtocol.self)
        connection.resume()
        do {
            return try await withCheckedThrowingContinuation { continuation in
                // Resumed once: by the reply, by NSXPC's error handler, or by
                // the timeout (launchd keeps a client waiting for as long as
                // it can't start the helper, e.g. a stale registration).
                let once = Once(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    once.resume(throwing: Failure(description: "helper unreachable: \(error.localizedDescription)"))
                } as! SSHFSHelperProtocol
                DispatchQueue.global().asyncAfter(deadline: .now() + replyTimeout) {
                    once.resume(throwing: Failure(description:
                        "helper didn't answer in \(replyTimeout) s; try `SSHFS register` and see `SSHFS status`"))
                }
                proxy.spawnSSH(arguments: arguments, environment: environment) { stdin, stdout, stderr, pid, error in
                    guard let stdin, let stdout, let stderr else {
                        once.resume(throwing: Failure(description: "helper: \(error ?? "no descriptors")"))
                        return
                    }
                    // The handles own their descriptors; keep our own copies.
                    let w = dup(stdin.fileDescriptor), r = dup(stdout.fileDescriptor), e = dup(stderr.fileDescriptor)
                    guard w >= 0, r >= 0, e >= 0 else {
                        for fd in [w, r, e] where fd >= 0 { close(fd) }
                        once.resume(throwing: Failure(description: "dup failed: errno \(errno)"))
                        return
                    }
                    log.info("helper started ssh[\(pid)]")
                    let transport = SFTPTransport(
                        readFD: r, writeFD: w, stderrFD: e, stderrHandler: stderrHandler,
                        onClose: { connection.invalidate() })
                    // Too late (timed out): closing it makes the helper kill the ssh.
                    if !once.resume(returning: transport) { transport.close() }
                }
            }
        } catch {
            connection.invalidate()
            throw error
        }
    }
}

/// Resumes a continuation at most once.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    private func take() -> CheckedContinuation<T, any Error>? {
        lock.lock(); defer { lock.unlock() }
        defer { continuation = nil }
        return continuation
    }

    @discardableResult
    func resume(returning value: T) -> Bool {
        guard let c = take() else { return false }
        c.resume(returning: value)
        return true
    }

    func resume(throwing error: any Error) { take()?.resume(throwing: error) }
}
