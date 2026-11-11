import Foundation
import os
import Security

// The helper: this binary run by launchd as `SSHFS helper` (see
// Config/com.joelmsmith.sshfs.helper.plist). It exists because the FSKit
// extension must be sandboxed and ssh would inherit that sandbox; here ssh
// runs exactly as it does in Terminal. The helper only starts ssh and hands
// its pipes to the extension -- no SFTP bytes pass through it.

private let hlog = Logger(subsystem: "com.joelmsmith.sshfs", category: "helper")

/// All helper state lives on this queue.
private let helperQueue = DispatchQueue(label: "com.joelmsmith.sshfs.helper")
private var liveChildren: [pid_t: DispatchSourceProcess] = [:]
private var liveConnections = 0
private var idleTimer: DispatchSourceTimer?
/// Exit after this long with no connections and no ssh processes; launchd
/// starts us again on demand.
private let idleExit: DispatchTimeInterval = .seconds(30)

private func rearmIdleTimer() {
    idleTimer?.cancel()
    idleTimer = nil
    guard liveChildren.isEmpty, liveConnections == 0 else { return }
    let t = DispatchSource.makeTimerSource(queue: helperQueue)
    t.schedule(deadline: .now() + idleExit)
    t.setEventHandler {
        hlog.info("idle; exiting")
        exit(0)
    }
    t.resume()
    idleTimer = t
}

/// One per XPC connection.
private final class HelperSession: NSObject, SSHFSHelperProtocol {
    private var pids: Set<pid_t> = []  // on helperQueue

    func spawnSSH(arguments: [String], environment: [String: String],
                  reply: @escaping (FileHandle?, FileHandle?, FileHandle?, Int32, String?) -> Void) {
        helperQueue.async {
            do {
                var env = ProcessInfo.processInfo.environment
                env.merge(environment) { _, new in new }
                // ssh has no terminal: questions go to this binary in
                // askpass mode (Askpass.swift).
                env["SSH_ASKPASS"] = Bundle.main.executablePath
                env["SSH_ASKPASS_REQUIRE"] = "force"
                if env[askpassModeVariable] == nil { env[askpassModeVariable] = "silent" }
                let child = try spawnDetached("/usr/bin/ssh", arguments: arguments, environment: env)
                hlog.info("ssh[\(child.pid)] started: \(arguments.joined(separator: " "), privacy: .public)")
                self.pids.insert(child.pid)
                let source = DispatchSource.makeProcessSource(identifier: child.pid, eventMask: .exit, queue: helperQueue)
                source.setEventHandler {
                    var status: Int32 = 0
                    waitpid(child.pid, &status, 0)
                    hlog.info("ssh[\(child.pid)] exited, wait status \(status)")
                    self.pids.remove(child.pid)
                    liveChildren[child.pid] = nil
                    source.cancel()
                    rearmIdleTimer()
                }
                liveChildren[child.pid] = source
                source.resume()
                rearmIdleTimer()
                // XPC dups the descriptors while sending; ours close when
                // these handles are released.
                reply(FileHandle(fileDescriptor: child.stdin, closeOnDealloc: true),
                      FileHandle(fileDescriptor: child.stdout, closeOnDealloc: true),
                      FileHandle(fileDescriptor: child.stderr, closeOnDealloc: true),
                      child.pid, nil)
            } catch {
                hlog.error("spawn failed: \(String(describing: error), privacy: .public)")
                reply(nil, nil, nil, 0, String(describing: error))
            }
        }
    }

    func ping(reply: @escaping (Int32) -> Void) { reply(getpid()) }

    /// The connection went away: its ssh processes have no reader any more.
    func connectionClosed() {
        helperQueue.async {
            // Not yet reaped, so the pids can't have been reused.
            for pid in self.pids { kill(pid, SIGKILL) }
            liveConnections -= 1
            rearmIdleTimer()
        }
    }
}

private struct SpawnError: Error, CustomStringConvertible {
    var description: String
}

/// Starts a process in its own session (so it outlives the helper: launchd
/// only cleans up the helper's own process group) with pipes on 0, 1, 2 and
/// no other descriptors.
private func spawnDetached(_ path: String, arguments: [String], environment: [String: String])
    throws -> (pid: pid_t, stdin: Int32, stdout: Int32, stderr: Int32) {
    var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
    guard pipe(&inPipe) == 0, pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
        let e = errno
        for fd in inPipe + outPipe + errPipe where fd >= 0 { close(fd) }
        throw SpawnError(description: "pipe: \(String(cString: strerror(e)))")
    }
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
    posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
    posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // Dispatch worker threads block signals and the child would inherit
    // that mask (an ssh that ignores SIGTERM): give it a clean slate.
    var noSignals = sigset_t(), allSignals = sigset_t()
    sigemptyset(&noSignals)
    sigfillset(&allSignals)
    posix_spawnattr_setsigmask(&attr, &noSignals)
    posix_spawnattr_setsigdefault(&attr, &allSignals)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                          | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

    var argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for p in argv + envp { free(p) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, path, &actions, &attr, &argv, &envp)
    close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
    guard rc == 0 else {
        close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
        throw SpawnError(description: "posix_spawn \(path): \(String(cString: strerror(rc)))")
    }
    return (pid, inPipe[1], outPipe[0], errPipe[0])
}

/// Team ID this binary is signed with; nil for ad-hoc builds.
private func ownTeamID() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

private final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    let team = ownTeamID()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Whoever reaches us can run ssh (and so any ProxyCommand) outside
        // its own sandbox: accept only code signed by our team. Ad-hoc builds
        // have no team to check.
        if let team {
            connection.setCodeSigningRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
        let session = HelperSession()
        connection.exportedInterface = NSXPCInterface(with: SSHFSHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.connectionClosed() }
        helperQueue.async {
            liveConnections += 1
            rearmIdleTimer()
        }
        connection.resume()
        return true
    }
}

func runHelper() async -> Never {
    let delegate = HelperDelegate()
    let listener = NSXPCListener(machServiceName: helperMachService)
    listener.delegate = delegate
    listener.resume()
    hlog.info("helper started, pid \(getpid()), team \(delegate.team ?? "none", privacy: .public), SSH_AUTH_SOCK=\(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "unset", privacy: .public)")
    helperQueue.async { rearmIdleTimer() }
    while true { try? await Task.sleep(for: .seconds(3600)) }
}
