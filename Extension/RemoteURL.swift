import Foundation
import FSKit

/// Where to connect, parsed from the mount resource URL.
///
///     ssh://[user@]host[:port]/absolute/path
///     ssh://[user@]host[:port]/~/path/relative/to/home
///     ssh://[user@]host[:port]            (home directory)
///
/// Path components must be percent-encoded (`Pink%20Floyd`).
struct RemoteURL: CustomStringConvertible {
    var user: String?
    var host: String
    var port: Int?
    /// Path to hand to the server's REALPATH: absolute, or relative to the
    /// login directory.
    var path: String
    /// Options from the URL query (see SSHFSOptions).
    var options = SSHFSOptions()

    init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "ssh", let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw fs_errorForPOSIXError(EINVAL)
        }
        self.host = host
        self.user = url.user(percentEncoded: false)
        self.port = url.port
        let p = url.path(percentEncoded: false)
        if p.isEmpty || p == "/~" || p == "/~/" {
            path = "."
        } else if p.hasPrefix("/~/") {
            path = String(p.dropFirst(3))
        } else {
            path = p
        }
        let unknown = options.apply(SSHFSOptions.pairs(from: url))
        if !unknown.isEmpty { log.notice("ignoring unknown URL options: \(unknown, privacy: .public)") }
    }

    /// The server as the user named it, without the directory.
    var target: String {
        "\(user.map { $0 + "@" } ?? "")\(host)\(port.map { ":\($0)" } ?? "")"
    }

    var description: String {
        "\(user.map { $0 + "@" } ?? "")\(host)\(port.map { ":\($0)" } ?? ""):\(path)"
    }
}
