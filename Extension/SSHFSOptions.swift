import Foundation

/// Options for one mount, gathered from the resource URL's query
/// (`ssh://host/path?cache_timeout=5&IdentityFile=~/.ssh/k`) and from
/// `mount -o` (which FSKit delivers at activate, after we've connected).
///
/// - Keys starting with an uppercase letter are ssh options (`ssh -o Key=Value`).
///   They're needed before connecting, so they only work in the URL; the
///   `sshfs` command puts them there.
/// - Lowercase keys are ours (below); unknown ones are ignored with a log line
///   (the kernel handles its own, like `rdonly` or `nobrowse`).
struct SSHFSOptions {
    /// Seconds to trust attributes/listings fetched from the server.
    var cacheTimeout: Duration = .seconds(20)
    /// Seconds between remote-change polls of recently used directories; 0 disables.
    var dirPoll: Duration = .seconds(5)
    /// Path of an ssh-agent socket to hand to ssh as SSH_AUTH_SOCK.
    var agentSocket: String?
    /// Program to ask for passwords instead of showing a dialog.
    var askpassProgram: String?
    /// Extra `ssh -o` options, in order.
    var sshOptions: [String] = []

    static let kernelOptions = MountOptions.kernel

    /// Applies `key[=value]` pairs. Returns keys it didn't recognise.
    @discardableResult
    mutating func apply(_ pairs: [(String, String?)]) -> [String] {
        var unknown: [String] = []
        for (key, value) in pairs {
            if let first = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                sshOptions.append(value.map { "\(key)=\($0)" } ?? key)
                continue
            }
            switch key {
            case "cache_timeout":
                if let v = value.flatMap(Double.init), v >= 0 { cacheTimeout = .milliseconds(Int(v * 1000)) }
                else { unknown.append(key) }
            case "dir_poll":
                if let v = value.flatMap(Double.init), v >= 0 { dirPoll = .milliseconds(Int(v * 1000)) }
                else { unknown.append(key) }
            case "agent":
                agentSocket = value
            case "askpass":
                askpassProgram = value
            default:
                if !Self.kernelOptions.contains(key) { unknown.append(key) }
            }
        }
        return unknown
    }

    /// Pairs from a URL query.
    static func pairs(from url: URL) -> [(String, String?)] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { ($0.name, $0.value) } ?? []
    }

    /// Pairs from FSKit task options: ["-o", "a=1,b", "-o", "c"].
    static func pairs(fromTaskOptions args: [String]) -> [(String, String?)] {
        var out: [(String, String?)] = []
        var i = 0
        while i < args.count {
            if args[i] == "-o", i + 1 < args.count {
                for part in MountOptions.split(args[i + 1]) {
                    let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                    out.append((kv[0], kv.count > 1 ? kv[1] : nil))
                }
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }
}
