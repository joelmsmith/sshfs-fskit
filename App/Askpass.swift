import CoreFoundation
import Darwin
import Foundation
import Security

// Askpass mode: ssh has no terminal, so it runs this binary (SSH_ASKPASS, set
// by the helper) whenever it needs a password, a key passphrase, a one-time
// code or a decision about an unknown host key. ssh passes the prompt as the
// only argument and reads the answer from our stdout; a non-zero exit means
// "no answer".
//
// The extension chooses how we answer, through the environment:
//
//   SSHFS_ASKPASS_MODE     interactive: ask the user (first connect, and once
//                          per outage); silent: never show anything
//                          (background reconnects)
//   SSHFS_ASKPASS_TARGET   what is being mounted, for the dialog and as part
//                          of the keychain key
//   SSHFS_ASKPASS_PROGRAM  optional program to ask instead of showing a
//                          dialog (`-o askpass=`): same convention as ssh's
//                          own askpass. Also how e2e answers prompts.
//   SSHFS_ASKPASS_REMEMBER set: remember the program's answer in the keychain
//                          as if the dialog's checkbox had been ticked (for
//                          tests; the extension never sets it)
//
// Lines we write to stderr come out of ssh's stderr, which the extension
// reads: `askpassMarker…` lines tell it what happened (Extension/SSHFileSystem.swift).

/// Remembers what happened earlier in the same ssh process: ssh starts a new
/// askpass for every prompt and repeats a prompt whose answer was wrong.
private struct AskpassState: Codable {
    /// The user said no (or nobody could be asked): every later prompt of
    /// this ssh fails at once. Otherwise ssh would walk through its other
    /// authentication methods with up to eight more prompts.
    var cancelled = false
    /// Prompts already answered once (so a repeat means "that was wrong").
    var answered: [String] = []

    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("com.joelmsmith.sshfs.askpass", isDirectory: true)
    }

    /// One file per ssh process: pid plus start time, so a recycled pid
    /// doesn't inherit an old state.
    static var file: URL {
        let parent = getppid()
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let started = proc_pidinfo(parent, PROC_PIDTBSDINFO, 0, &info, size) == size ? info.pbi_start_tvsec : 0
        return directory.appendingPathComponent("\(parent)-\(started).json")
    }

    static func load() -> AskpassState {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Sweep states of ssh processes long gone.
        let old = Date(timeIntervalSinceNow: -86400)
        for f in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < old {
                try? fm.removeItem(at: f)
            }
        }
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(AskpassState.self, from: data) else {
            return AskpassState()
        }
        return s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}

/// Secrets the user asked us to remember, in their login keychain.
private enum AskpassKeychain {
    static let service = "SSHFS"

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func find(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func store(_ account: String, secret: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData] = Data(secret.utf8)
        q[kSecAttrLabel] = "SSHFS (\(account))"
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { note("couldn't save to the keychain (\(status))") }
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

private func note(_ message: String) {
    FileHandle.standardError.write(Data("\(askpassMarker)\(message)\n".utf8))
}

private enum Answer {
    case text(String, remember: Bool)
    case cancelled
}

/// Shows a system alert (CFUserNotification: drawn by the system on top of
/// everything, so it works from a process that isn't an app) and waits.
/// - Parameters:
///   - field: title of a secure text field, or nil for a yes/no question.
///   - remember: title of a checkbox, or nil.
///   - accept: title of the button that says yes.
private func askWithDialog(header: String, message: String, field: String?, remember: String?,
                           accept: String, cancel: String? = "Cancel") -> Answer {
    var dict: [CFString: Any] = [
        kCFUserNotificationAlertHeaderKey: header,
        kCFUserNotificationAlertMessageKey: message,
        kCFUserNotificationAlertTopMostKey: true,
    ]
    var flags = kCFUserNotificationPlainAlertLevel
    // With a field, Return should submit it. Without one the question is
    // "trust this host?", and Return should be the safe answer.
    let acceptIsDefault = field != nil || cancel == nil
    if acceptIsDefault {
        dict[kCFUserNotificationDefaultButtonTitleKey] = accept
        if let cancel { dict[kCFUserNotificationAlternateButtonTitleKey] = cancel }
    } else {
        dict[kCFUserNotificationDefaultButtonTitleKey] = cancel
        dict[kCFUserNotificationAlternateButtonTitleKey] = accept
    }
    if let field {
        dict[kCFUserNotificationTextFieldTitlesKey] = field
        flags |= CFUserNotificationSecureTextField(0)
    }
    if let remember { dict[kCFUserNotificationCheckBoxTitlesKey] = remember }

    var error: Int32 = 0
    guard let notification = CFUserNotificationCreate(nil, 0, flags, &error, dict as CFDictionary) else {
        note("can't show a dialog (error \(error))")
        return .cancelled
    }
    // If ssh goes away (the server stops waiting after its LoginGraceTime,
    // or the mount was abandoned), take the dialog down with it.
    let parent = DispatchSource.makeProcessSource(identifier: getppid(), eventMask: .exit, queue: .global())
    parent.setEventHandler {
        CFUserNotificationCancel(notification)
        exit(1)
    }
    parent.resume()
    // ssh ends a notice by sending SIGTERM.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    term.setEventHandler {
        CFUserNotificationCancel(notification)
        exit(0)
    }
    term.resume()

    var response: CFOptionFlags = 0
    guard CFUserNotificationReceiveResponse(notification, 0, &response) == 0 else { return .cancelled }
    let button = response & 0x3
    let accepted = acceptIsDefault ? button == CFOptionFlags(kCFUserNotificationDefaultResponse)
                                   : button == CFOptionFlags(kCFUserNotificationAlternateResponse)
    guard accepted else { return .cancelled }
    var text = ""
    if field != nil, let value = CFUserNotificationGetResponseValue(notification, kCFUserNotificationTextFieldValuesKey, 0) {
        text = value as String
    }
    return .text(text, remember: remember != nil && response & CFUserNotificationCheckBoxChecked(0) != 0)
}

/// Asks `program` the way ssh would ask an askpass program.
private func askProgram(_ program: String, prompt: String) -> Answer {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: program)
    p.arguments = [prompt]
    let out = Pipe()
    p.standardOutput = out
    do { try p.run() } catch {
        note("can't run \(program): \(error.localizedDescription)")
        return .cancelled
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0, var text = String(data: data, encoding: .utf8) else { return .cancelled }
    if text.hasSuffix("\n") { text.removeLast() }
    return .text(text, remember: ProcessInfo.processInfo.environment["SSHFS_ASKPASS_REMEMBER"] != nil)
}

func runAskpass(prompt rawPrompt: String, mode: String) -> Never {
    let env = ProcessInfo.processInfo.environment
    let interactive = mode == "interactive"
    let target = env["SSHFS_ASKPASS_TARGET"] ?? "the server"
    let program = env["SSHFS_ASKPASS_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 }
    let hint = env["SSH_ASKPASS_PROMPT"]
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let header = "SSHFS: connecting to \(target)"

    func reply(_ text: String) -> Never {
        print(text)
        exit(0)
    }

    // A notice (e.g. "touch your security key"): ssh kills us when it's over.
    if hint == "none" {
        if interactive && program == nil {
            _ = askWithDialog(header: header, message: prompt, field: nil, remember: nil, accept: "OK", cancel: nil)
        }
        exit(0)
    }

    // A background reconnect shows nothing, including the system's own
    // "SSHFS wants to use your keychain" (seen after the app's signature
    // changes): the read fails, and the user is asked in the open instead.
    if !interactive { SecKeychainSetUserInteractionAllowed(false) }

    var state = AskpassState.load()
    func giveUp(_ why: String) -> Never {
        if !state.cancelled { note(why) }
        state.cancelled = true
        state.save()
        exit(1)
    }
    if state.cancelled { exit(1) }
    let repeated = state.answered.contains(prompt)
    state.answered.append(prompt)
    state.save()

    // A yes/no question: an unknown host key (ssh wants the word typed), or
    // a confirmation (ssh looks at the exit status only).
    let lower = prompt.lowercased()
    if hint == "confirm" || lower.contains("(yes/no") || lower.contains("'yes', 'no'") {
        guard interactive else { giveUp(askpassNeedsPrompt) }
        note(askpassAsked)
        let answer: Answer
        if let program {
            answer = askProgram(program, prompt: rawPrompt)
        } else {
            // Drop ssh's "type yes" line; the buttons say it.
            var lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.count > 1, lines.last?.lowercased().contains("yes/no") == true { lines.removeLast() }
            let message = lines.joined(separator: "\n")
                + "\n\nIf you connect, the key is saved in known_hosts and you won't be asked again."
            answer = askWithDialog(header: header, message: message, field: nil, remember: nil, accept: "Connect")
            if case .text = answer { reply("yes") }
        }
        guard case .text(let text, _) = answer else { giveUp(askpassCancelled) }
        reply(text)
    }

    // A secret. The key for remembering it: where we're going plus what was
    // asked (prompts name the account or key file; a jump host asks its own).
    let account = "\(target) \(prompt.hasSuffix(":") ? String(prompt.dropLast()) : prompt)"
    if repeated {
        // Whatever we answered last time was wrong; don't keep it.
        AskpassKeychain.delete(account)
    } else if let saved = AskpassKeychain.find(account) {
        reply(saved)
    }
    guard interactive else { giveUp(askpassNeedsPrompt) }
    note(askpassAsked)
    let answer: Answer
    if let program {
        answer = askProgram(program, prompt: rawPrompt)
    } else {
        // Offer to remember passwords and passphrases, not one-time codes.
        let kind = lower.contains("passphrase") ? "passphrase" : lower.contains("password") ? "password" : nil
        answer = askWithDialog(
            header: header,
            message: (repeated ? "That wasn't accepted. Try again.\n\n" : "") + prompt,
            field: kind.map { $0.capitalized + ":" } ?? "",
            remember: kind.map { "Remember this \($0) in my keychain" },
            accept: "OK")
    }
    guard case .text(let secret, let remember) = answer else { giveUp(askpassCancelled) }
    if remember { AskpassKeychain.store(account, secret: secret) }
    reply(secret)
}
