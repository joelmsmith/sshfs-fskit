import Foundation
import FSKit
import os
import SFTP

let log = Logger(subsystem: "com.joelmsmith.sshfs", category: "fsmodule")

/// The FSKit entry point. FSKit hands us one resource (an `ssh://` URL), we
/// start `ssh -s sftp` for it and present the remote directory as one volume.
@objc
final class SSHFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    func probeResource(
        resource: FSResource,
        replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void
    ) {
        guard let url = (resource as? FSGenericURLResource)?.url, let remote = try? RemoteURL(url) else {
            replyHandler(.notRecognized, nil)
            return
        }
        replyHandler(.usable(name: remote.host, containerID: FSContainerIdentifier(uuid: Self.uuid(for: url))), nil)
    }

    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping (FSVolume?, (any Error)?) -> Void
    ) {
        guard let url = (resource as? FSGenericURLResource)?.url else {
            replyHandler(nil, fs_errorForPOSIXError(EINVAL))
            return
        }
        log.info("load \(url.absoluteString, privacy: .public) options=\(options.taskOptions, privacy: .public)")
        Task {
            do {
                let remote = try RemoteURL(url)
                // The user is waiting on `mount`: ssh may ask them things.
                let client = try await Self.connect(remote, interactive: true)
                let root = try await client.realpath(remote.path)
                let attrs = try await client.stat(root)
                guard attrs.type == .directory else { throw fs_errorForPOSIXError(ENOTDIR) }
                log.info("connected to \(remote.description, privacy: .public), root \(root, privacy: .public), limits read=\(client.limits.maxReadLength) write=\(client.limits.maxWriteLength)")
                let name = remote.host + ":" + ((root as NSString).lastPathComponent)
                let remoteRef = remote
                let reconnecting = Remote(initial: client) { try await Self.connect(remoteRef, interactive: $0) }
                let volume = SSHVolume(remote: reconnecting, rootPath: root, name: name, options: remote.options,
                                       volumeID: FSVolume.Identifier(uuid: Self.uuid(for: url)))
                self.containerStatus = .ready
                replyHandler(volume, nil)
            } catch {
                log.error("load failed: \(String(describing: error), privacy: .public)")
                replyHandler(nil, error.posix)
            }
        }
    }

    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler: @escaping ((any Error)?) -> Void
    ) {
        log.info("unload")
        replyHandler(nil)
    }

    func didFinishLoading() {
        log.info("extension loaded")
    }

    /// Starts ssh (in the helper) and does the SFTP handshake.
    ///
    /// ssh asks its questions -- password, passphrase, unknown host key --
    /// through the app's askpass mode (App/Askpass.swift). `interactive`
    /// says whether that may show a dialog; if not, it answers from the
    /// keychain or the connect fails with `needsPrompt`.
    static func connect(_ remote: RemoteURL, interactive: Bool) async throws -> SFTPClient {
        let stderr = StderrLog()
        let agent = remote.options.agentSocket.flatMap { $0.isEmpty || $0 == "none" ? nil : $0 }
        let arguments = SFTPTransport.sshArguments(
            destination: remote.host, port: remote.port, user: remote.user,
            // ssh keeps the first value given for an option, so the user's
            // options go first and can override our defaults.
            options: remote.options.sshOptions + [
                "ServerAliveInterval=5",    // notice dead connections within ~15 s
                "ServerAliveCountMax=3",
                "ConnectTimeout=15",        // doesn't run while ssh waits for an answer
            ])
        // ssh runs in the helper, outside our sandbox, with the helper's
        // environment (launchd's, including its SSH_AUTH_SOCK).
        var environment = [
            askpassModeVariable: interactive ? "interactive" : "silent",
            "SSHFS_ASKPASS_TARGET": remote.target,
        ]
        if let agent { environment["SSH_AUTH_SOCK"] = agent }
        if let program = remote.options.askpassProgram { environment["SSHFS_ASKPASS_PROGRAM"] = program }
        let transport: SFTPTransport
        do {
            transport = try await HelperClient.spawnSSH(
                arguments: arguments,
                environment: environment,
                stderrHandler: { line in
                    log.notice("ssh: \(line, privacy: .public)")
                    stderr.append(line)
                })
        } catch {
            log.error("\(String(describing: error), privacy: .public)")
            throw ConnectError(errno: ENOTCONN)
        }
        do {
            return try await SFTPClient.connect(transport: transport)
        } catch {
            // ssh has exited; its stderr says why. Give the kernel (and so the
            // user's `mount` command) the closest errno.
            try? await Task.sleep(for: .milliseconds(100))  // let stderr drain
            throw stderr.failure()
        }
    }

    /// Stable UUID per URL so remounts look like the same volume.
    static func uuid(for url: URL) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        var h: UInt64 = 0xcbf29ce484222325
        for b in url.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: h >> (8 * i)) }
        h = h &* 0x9E3779B97F4A7C15
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: h >> (8 * i)) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return NSUUID(uuidBytes: bytes) as UUID
    }
}

/// Why a connect failed.
struct ConnectError: Error {
    /// The closest errno, for the kernel.
    var errno: Int32
    /// ssh needed an answer from the user and this connect couldn't ask.
    var needsPrompt = false
    /// The user was asked (and the connect failed all the same: they said
    /// no, or the answer was wrong).
    var asked = false
}

/// Collects ssh's stderr during connect and says what went wrong.
final class StderrLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if lines.count < 50 || line.hasPrefix(askpassMarker) { lines.append(line) }
    }

    func failure() -> ConnectError {
        lock.lock(); defer { lock.unlock() }
        let needsPrompt = lines.contains(askpassMarker + askpassNeedsPrompt)
        let asked = lines.contains(askpassMarker + askpassAsked)
        func error(_ errno: Int32) -> ConnectError { ConnectError(errno: errno, needsPrompt: needsPrompt, asked: asked) }
        let text = lines.joined(separator: "\n")
        // Network trouble first: a jump host can fail after a prompt was answered.
        if text.contains("Could not resolve hostname") { return error(EHOSTUNREACH) }
        if text.contains("Connection refused") { return error(ECONNREFUSED) }
        if text.contains("No route to host") || text.contains("Network is unreachable") { return error(EHOSTUNREACH) }
        if lines.contains(askpassMarker + askpassCancelled) { return error(ECANCELED) }
        if needsPrompt { return error(EAUTH) }
        if text.contains("Permission denied") || text.contains("Too many authentication failures") { return error(EAUTH) }
        if text.contains("Host key verification failed") || text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return error(EAUTH) }
        if text.contains("timed out") { return error(ETIMEDOUT) }
        if text.contains("subsystem request failed") { return error(EPROTONOSUPPORT) }
        return error(EHOSTUNREACH)
    }
}
