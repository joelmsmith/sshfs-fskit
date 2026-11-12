import Foundation
import FSKit
import notify
import CoreServices
import ServiceManagement

// Host app for the FSKit module, and the `sshfs` command.
//
// Launching the app registers the embedded extension. The same binary is a CLI:
//
//   SSHFS                      opens System Settings > File System Extensions
//   SSHFS list                 lists installed FSKit modules
//   SSHFS check                asks mounted volumes to re-check their connection
//                              (and to ask for a password again, if they gave up)
//   SSHFS status               shows whether the module and the helper are set up
//   SSHFS register|unregister  adds / removes the helper's launchd agent
//   SSHFS helper               the helper itself (run by launchd; see Helper.swift)
//   sshfs [user@]host:[dir] mountpoint [-o opt,...] [-p port]
//                              (when invoked via a symlink named `sshfs`, or as `SSHFS sshfs ...`)

let extensionBundleID = "com.joelmsmith.sshfs.fsmodule"

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("sshfs: \(message)\n".utf8))
    exit(code)
}

let usage = """
    usage: sshfs [user@]host:[dir] mountpoint [-o option[,option...]]... [-p port]

      dir         remote directory; relative paths are relative to your home
                  directory, empty means home

    options (-o):
      cache_timeout=N   seconds to cache attributes and listings (default 20)
      dir_poll=N        seconds between checks for remote changes in recently
                        used directories (default 5, 0 = off)
      agent=PATH        ssh-agent socket (default: $SSH_AUTH_SOCK; agent=none to disable)
      askpass=PROGRAM   ask this program for passwords instead of showing a
                        dialog (called like ssh's SSH_ASKPASS programs)
      Key=Value         any ssh option, e.g. IdentityFile=~/.ssh/id_work
      rdonly, nobrowse, ...  passed to mount(8)

    Passwords, key passphrases and unknown host keys are asked for in a dialog
    (-o BatchMode=yes: never ask). If a mount later stops because it couldn't
    ask again, `SSHFS check` makes it retry.
    Unmount with: umount mountpoint
    """

/// Splits `[user@]host:[dir]`, allowing `[v6::addr]:dir`.
func parseRemote(_ spec: String) -> (user: String?, host: String, path: String)? {
    var rest = Substring(spec)
    var user: String?
    if let at = rest.lastIndex(of: "@") {
        user = String(rest[..<at])
        rest = rest[rest.index(after: at)...]
    }
    let host: Substring
    if rest.hasPrefix("[") {
        guard let close = rest.firstIndex(of: "]") else { return nil }
        host = rest[rest.index(after: rest.startIndex)..<close]
        rest = rest[rest.index(after: close)...]
        guard rest.hasPrefix(":") else { return nil }
    } else {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        host = rest[..<colon]
        rest = rest[colon...]
    }
    guard !host.isEmpty else { return nil }
    return (user, String(host), String(rest.dropFirst()))
}

/// What the sshfs mount at `path` is a mount of, if there is one. Asks the
/// mount table rather than the mount, which may be slow or failing to answer.
/// `path` in the result is absolute: umount(8) only finds a mount that
/// doesn't answer by its full path ("not currently mounted" otherwise).
func sshfsMount(at path: String) -> (source: String, path: String)? {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
    defer { free(parent) }
    let resolved = URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(url.lastPathComponent).path
    var mounts: UnsafeMutablePointer<statfs>?
    let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
    defer { free(mounts) }
    func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
    for i in 0..<Int(max(count, 0)) {
        let m = mounts![i]
        guard string(m.f_fstypename) == "sshfs", string(m.f_mntonname) == resolved else { continue }
        let from = string(m.f_mntfromname)
        return (String(from.prefix { $0 != "?" }), resolved)
    }
    return nil
}

/// The helper's launchd agent (Contents/Library/LaunchAgents in the app).
let helperService = SMAppService.agent(plistName: helperPlistName)

func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "not registered"
    case .enabled: "enabled"
    case .requiresApproval: "needs approval in System Settings > General > Login Items & Extensions"
    case .notFound: "not found (is SSHFS.app intact?)"
    @unknown default: "unknown (\(status.rawValue))"
    }
}

/// True if the helper answers within `timeout` seconds (launchd starts it on demand).
func helperAnswers(timeout: Double) -> Bool {
    let connection = NSXPCConnection(machServiceName: helperMachService, options: [])
    connection.remoteObjectInterface = NSXPCInterface(with: SSHFSHelperProtocol.self)
    connection.resume()
    defer { connection.invalidate() }
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var answered = false
    let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! SSHFSHelperProtocol
    proxy.ping { _ in answered = true; done.signal() }
    return done.wait(timeout: .now() + timeout) == .success && answered
}

/// Makes sure the helper agent is registered and actually starts. Returns nil
/// on success, or what's wrong.
///
/// A registration records how the app was signed, and launchd refuses to
/// start a helper that doesn't match (spawn fails with EX_CONFIG, clients
/// wait forever). That happens after switching between dev-signed and
/// Developer ID builds -- and for a while after such a switch even a fresh
/// registration gets the previous build's kind (ARCHITECTURE.md). So: ping,
/// and re-register until the helper answers.
func ensureHelper(reregister: Bool = false) async -> String? {
    var problem: String?
    if helperService.status != .enabled {
        do { try helperService.register() } catch { problem = error.localizedDescription }
        if helperService.status == .requiresApproval { return "ssh helper: \(describe(.requiresApproval))" }
    }
    if !reregister, helperAnswers(timeout: 3) { return nil }
    for _ in 0..<4 {
        try? await helperService.unregister()
        try? await Task.sleep(for: .milliseconds(500))  // the status lags behind unregister
        do { try helperService.register(); problem = nil } catch { problem = error.localizedDescription }
        if helperAnswers(timeout: 5) { return nil }
    }
    return "the ssh helper doesn't start (status: \(describe(helperService.status))\(problem.map { "; " + $0 } ?? "")). "
        + "See: log show --last 2m --predicate 'process == \"launchd\" AND eventMessage CONTAINS \"sshfs.helper\"'"
}

/// The app bundle this binary is in. (`Bundle.main` is wrong when the binary
/// is run through a symlink such as ~/bin/sshfs.)
let appBundleURL: URL = {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buffer = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buffer, &size)
    let binary = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    return binary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}()

/// Checks that fskitd knows the module and that it's switched on. Returns
/// nil if so, or what to do about it. (Without this, mount(8) only says
/// "Unable to invoke task".)
func moduleProblem() async -> String? {
    func module() async -> FSModuleIdentity? {
        (try? await FSClient.shared.installedExtensions)?.first { $0.bundleIdentifier == extensionBundleID }
    }
    var found = await module()
    if found == nil {
        // A freshly unpacked app that was never opened: register it.
        LSRegisterURL(appBundleURL as CFURL, true)
        for _ in 0..<10 where found == nil {
            try? await Task.sleep(for: .milliseconds(300))
            found = await module()
        }
    }
    guard let found else {
        return "macOS doesn't know the SSHFS file system module yet. Open \(appBundleURL.path) once "
            + "(double-click it, or `open` it), then try again."
    }
    if !found.isEnabled {
        return """
            the SSHFS file system module is switched off. Turn it on in System Settings > General > \
            Login Items & Extensions > File System Extensions (`\(appBundleURL.path)/Contents/MacOS/SSHFS` \
            with no arguments opens that pane), then try again.
            """
    }
    if found.url.resolvingSymlinksInPath().path.hasPrefix(appBundleURL.path + "/") { return nil }
    // Another copy of the app is the registered one; mounting would run its
    // (possibly older) extension. Say so, but go on.
    FileHandle.standardError.write(Data("sshfs: note: macOS uses the module in \(found.url.path), not the one in this app\n".utf8))
    return nil
}

func sshfs(_ args: [String]) async -> Never {
    var positional: [String] = []
    var opts: [String] = []
    var port: Int?
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-h", "--help": print(usage); exit(0)
        case "-o":
            guard i + 1 < args.count else { fail("-o needs an argument") }
            opts += MountOptions.split(args[i + 1]); i += 1
        case "-p":
            guard i + 1 < args.count, let p = Int(args[i + 1]) else { fail("-p needs a port number") }
            port = p; i += 1
        default:
            if a.hasPrefix("-o"), a.count > 2 { opts += MountOptions.split(a.dropFirst(2)) }
            else if a.hasPrefix("-") { fail("unknown flag \(a)\n\(usage)") }
            else { positional.append(a) }
        }
        i += 1
    }
    guard positional.count == 2, let remote = parseRemote(positional[0]) else { fail(usage, code: 64) }

    // Kernel options go to mount(8); ours and ssh's travel in the URL so the
    // extension has them before it connects.
    let kernel = MountOptions.kernel
    var mountOpts: [String] = []
    var query: [URLQueryItem] = []
    for o in opts {
        let kv = o.split(separator: "=", maxSplits: 1).map(String.init)
        if kernel.contains(kv[0]) { mountOpts.append(o) }
        else {
            var value = kv.count > 1 ? kv[1] : nil
            // Expand ~ in paths here: the extension's HOME is its sandbox container.
            // ssh's parser wants paths with spaces quoted: "~/Library/Application Support/...".
            if let v = value, v.hasPrefix("~/") { value = NSHomeDirectory() + v.dropFirst(1) }
            else if let v = value, let q = v.first, q == "\"" || q == "'", v.dropFirst().hasPrefix("~/") {
                value = String(q) + NSHomeDirectory() + v.dropFirst(2)
            }
            // Nor does the helper share our working directory.
            if kv[0] == "askpass", let v = value { value = URL(fileURLWithPath: v).path }
            query.append(URLQueryItem(name: kv[0], value: value))
        }
    }

    // Pass the invoking shell's ssh-agent along unless told otherwise
    // (`-o agent=none`): ssh runs in the helper, whose environment is
    // launchd's, not this shell's.
    if !query.contains(where: { $0.name == "agent" }),
       let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], !sock.isEmpty {
        query.append(URLQueryItem(name: "agent", value: (sock as NSString).resolvingSymlinksInPath))
    }

    var c = URLComponents()
    c.scheme = "ssh"
    c.user = remote.user
    c.host = remote.host
    c.port = port
    let dir = remote.path.hasPrefix("~/") ? String(remote.path.dropFirst(2)) : remote.path
    if dir.isEmpty || dir == "~" { c.path = "" }
    else if dir.hasPrefix("/") { c.path = dir }
    else { c.path = "/~/" + dir }
    if !query.isEmpty { c.queryItems = query }
    guard let url = c.url else { fail("can't build a URL from \(positional[0])") }

    let mountpoint = positional[1]
    // Mounting where sshfs is already mounted replaces that mount. It has to
    // for a mount whose server went away: every call on it, stat included,
    // fails with ENOTCONN, so the mount point neither "exists" nor can be
    // created or removed. (Its cached attributes can still answer for a
    // while, so there's no telling such a mount from a healthy one here.)
    // Not forced: a mount in use, or with data it couldn't save, stays.
    if let (old, fullPath) = sshfsMount(at: mountpoint) {
        if unmount(mountpoint, 0) != 0 {
            fail("""
                \(mountpoint) is already an sshfs mount of \(old), and it won't unmount \
                (\(String(cString: strerror(errno)))). If it lost its server, `SSHFS check` makes it try again; \
                `umount -f \(fullPath)` removes it, discarding anything it hadn't saved.
                """)
        }
        FileHandle.standardError.write(Data("sshfs: replacing the mount of \(old)\n".utf8))
    }
    var isDir: ObjCBool = false
    var created = false
    if !FileManager.default.fileExists(atPath: mountpoint, isDirectory: &isDir) {
        do { try FileManager.default.createDirectory(atPath: mountpoint, withIntermediateDirectories: true); created = true }
        catch { fail("can't create mount point \(mountpoint): \(error.localizedDescription)") }
    } else if !isDir.boolValue {
        fail("\(mountpoint) is not a directory")
    }

    if let problem = await moduleProblem() { if created { rmdir(mountpoint) }; fail(problem) }
    if let problem = await ensureHelper() { fail(problem) }

    var mountArgs = ["-F", "-t", "sshfs"]
    if !mountOpts.isEmpty { mountArgs += ["-o", mountOpts.joined(separator: ",")] }
    mountArgs += [url.absoluteString, mountpoint]
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/mount")
    p.arguments = mountArgs
    do { try p.run() } catch { fail("can't run mount: \(error.localizedDescription)") }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        if created { rmdir(mountpoint) }
        // mount(8) already printed the reason (e.g. "Authentication error").
        // "Unable to invoke task" alone means fskitd couldn't run the module.
        fail("""
            mount failed. If the line above names a connection or authentication problem, check that \
            `ssh \(remote.user.map { $0 + "@" } ?? "")\(remote.host) true` works. Otherwise see `SSHFS status` and: \
            log show --last 2m --info --predicate 'subsystem == "com.joelmsmith.sshfs" OR process == "fskitd"'
            "No route to host" for a host on your own network that plain ssh reaches: macOS wants your \
            permission first. Answer its "find devices on local networks" question for SSHFS with Allow (or \
            switch SSHFS on in System Settings > Privacy & Security > Local Network), then mount again.
            """, code: p.terminationStatus)
    }
    exit(0)
}

let argv = CommandLine.arguments
let invokedAs = (argv[0] as NSString).lastPathComponent
let args = Array(argv.dropFirst())

// Run by ssh to ask the user something (the helper sets this; Askpass.swift).
if let mode = ProcessInfo.processInfo.environment[askpassModeVariable] {
    runAskpass(prompt: args.first ?? "", mode: mode)
}

if invokedAs == "sshfs" { await sshfs(args) }

switch args.first {
case nil:
    if !FSClient.shared.openFileSystemExtensionsSettings() {
        fail("could not open File System Extensions settings")
    }
case "sshfs":
    await sshfs(Array(args.dropFirst()))
case "list":
    let modules = try await FSClient.shared.installedExtensions
    for m in modules {
        print("\(m.isEnabled ? "enabled " : "disabled") \(m.bundleIdentifier)  \(m.url.path)")
    }
case "check":
    notify_post("com.joelmsmith.sshfs.check")
case "helper":
    await runHelper()
case "status":
    let modules = try await FSClient.shared.installedExtensions
    let module = modules.first { $0.bundleIdentifier == extensionBundleID }
    print("file system module: \(module.map { $0.isEnabled ? "enabled" : "disabled (enable it in System Settings > General > Login Items & Extensions > File System Extensions)" } ?? "not installed")")
    let status = helperService.status
    print("ssh helper:         \(describe(status))\(status == .enabled && !helperAnswers(timeout: 3) ? ", but it doesn't start: run `SSHFS register`" : "")")
case "register":
    if let problem = await ensureHelper(reregister: true) { fail(problem) }
    print("ssh helper: \(describe(helperService.status))")
case "unregister":
    try await helperService.unregister()
    print("ssh helper: \(describe(helperService.status))")
default:
    fail("unknown command \(args[0])\n\(usage)")
}
