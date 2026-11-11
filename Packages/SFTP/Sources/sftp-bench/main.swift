import Foundation
import SFTP

// Usage: sftp-bench <ssh-destination> <remote-dir>
// Measures raw SFTP latency/throughput without FSKit in the way.
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: sftp-bench host dir"); exit(1) }
let client = try await SFTPClient.connect(transport: SFTPTransport.ssh(destination: args[1], options: ["BatchMode=yes"]))
let dir = try await client.realpath(args[2])

func time(_ label: String, _ n: Int, _ body: () async throws -> Void) async rethrows {
    let start = ContinuousClock.now
    try await body()
    let d = ContinuousClock.now - start
    let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    print(String(format: "%-34@ %8.1f ms total  %7.3f ms/op", label as NSString, ms, ms / Double(n)))
}

let names = try await client.listDirectory(dir).map(\.filename)
await time("readdir (\(names.count) entries)", 1) { _ = try? await client.listDirectory(dir) }
let sample = Array(names.prefix(500))
await time("sequential lstat x\(sample.count)", sample.count) {
    for n in sample { _ = try? await client.lstat(dir + "/" + n) }
}
await time("parallel lstat x\(sample.count)", sample.count) {
    await withTaskGroup(of: Void.self) { g in
        for n in sample { g.addTask { _ = try? await client.lstat(dir + "/" + n) } }
    }
}
client.disconnect()
