import Foundation

/// `-o` option lists, shared by the `sshfs` command and the extension.
enum MountOptions {
    /// Options the kernel (mount(8)) handles itself.
    static let kernel: Set<String> = [
        "rdonly", "ro", "rw", "nobrowse", "browse", "noowners", "owners", "nosuid", "suid",
        "nodev", "dev", "noexec", "exec", "noatime", "atime", "sync", "async", "union", "force",
    ]

    /// Splits `a=1,b,Ciphers=x,y` into options. Several ssh options take
    /// comma-separated lists (Ciphers, MACs, HostKeyAlgorithms, ...), so a
    /// piece without `=` that follows an ssh option (`Key=Value`, uppercase
    /// key) belongs to its value unless it is a kernel option.
    static func split(_ list: some StringProtocol) -> [String] {
        let list = String(list)
        var out: [String] = []
        for part in list.split(separator: ",", omittingEmptySubsequences: true).map(String.init) {
            if let last = out.last, isSSHOption(last), !part.contains("="), !kernel.contains(part) {
                out[out.count - 1] = last + "," + part
            } else {
                out.append(part)
            }
        }
        return out
    }

    private static func isSSHOption(_ s: String) -> Bool {
        guard s.contains("="), let first = s.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
    }
}
