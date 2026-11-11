import Foundation

/// Mach service of the helper (a per-user launchd agent: the app binary
/// running as `SSHFS helper`, outside the sandbox).
let helperMachService = "com.joelmsmith.sshfs.helper"
/// Name of the agent's launchd plist in `Contents/Library/LaunchAgents`.
let helperPlistName = "com.joelmsmith.sshfs.helper.plist"

/// What the sandboxed extension asks of the helper.
///
/// One XPC connection per ssh process: the helper kills the ssh it started
/// for a connection when that connection goes away, so the extension ends an
/// ssh (even a wedged one) by invalidating its connection.
@objc protocol SSHFSHelperProtocol {
    /// Runs `/usr/bin/ssh arguments` as the user's own unsandboxed process and
    /// hands back its stdin (to write), stdout and stderr (to read). The
    /// helper's environment is used, with `environment` applied on top.
    func spawnSSH(arguments: [String], environment: [String: String],
                  reply: @escaping (_ stdin: FileHandle?, _ stdout: FileHandle?, _ stderr: FileHandle?,
                                    _ pid: Int32, _ error: String?) -> Void)

    /// Answers with the helper's pid: proof that launchd can start it.
    func ping(reply: @escaping (Int32) -> Void)
}

/// Environment variable that puts the app binary in askpass mode
/// (App/Askpass.swift): `interactive` or `silent`.
let askpassModeVariable = "SSHFS_ASKPASS_MODE"
/// Prefix of the lines askpass writes to ssh's stderr for the extension.
let askpassMarker = "sshfs-askpass: "
/// Askpass put a question to the user (or to the `askpass=` program).
let askpassAsked = "asked"
/// The answer was no / Cancel.
let askpassCancelled = "cancelled"
/// ssh needs an answer that only the user has, and this connect wasn't
/// allowed to ask (a background reconnect).
let askpassNeedsPrompt = "prompt needed"
