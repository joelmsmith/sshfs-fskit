import Foundation
import Testing
@testable import SFTP

/// By default, runs OpenSSH's sftp-server directly over pipes: a real server, no sshd.
///
/// Set `SFTP_TEST_SSH_HOST` (e.g. `sshfs-loopback`) to run the same suite over a
/// real `ssh` connection instead. The host must be this machine (loopback),
/// because the tests also inspect files locally.
struct Fixture {
    static let sshHost = ProcessInfo.processInfo.environment["SFTP_TEST_SSH_HOST"]

    let client: SFTPClient
    let transport: SFTPTransport
    let root: String

    init() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Resolve /var -> /private/var so paths match what the server reports.
        // (Foundation's resolvingSymlinksInPath strips /private, so use realpath(3).)
        guard let resolved = Darwin.realpath(dir.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(resolved) }
        root = String(cString: resolved)
        if let host = Self.sshHost, !host.isEmpty {
            transport = try SFTPTransport.ssh(destination: host, options: ["BatchMode=yes"])
        } else {
            transport = try SFTPTransport.spawn(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"))
        }
        client = try await SFTPClient.connect(transport: transport)
    }

    func path(_ name: String) -> String { root + "/" + name }

    func cleanup() {
        client.disconnect()
        try? FileManager.default.removeItem(atPath: root)
    }
}

@Suite struct SFTPClientTests {

    @Test func handshakeAdvertisesOpenSSHExtensions() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        #expect(f.client.serverVersion == 3)
        #expect(f.client.supports("posix-rename@openssh.com"))
        #expect(f.client.supports("statvfs@openssh.com"))
        #expect(f.client.limits.maxReadLength >= 32_768)
    }

    @Test func realpathResolvesDotDot() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try await f.client.mkdir(f.path("a"))
        #expect(try await f.client.realpath(f.path("a/..")) == f.root)
    }

    @Test func writeThenReadRoundTripsLargeFile() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        // Large enough to need many pipelined chunks, odd size to hit a short tail.
        let data = (0..<(3 * 1024 * 1024 + 123)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) }
        let h = try await f.client.open(f.path("big"), flags: [.write, .create, .truncate],
                                        attributes: FileAttributes(permissions: 0o644))
        try await f.client.write(h, offset: 0, data: data)
        try await f.client.close(h)

        #expect(try await f.client.stat(f.path("big")).size == UInt64(data.count))
        #expect(try Data(contentsOf: URL(fileURLWithPath: f.path("big"))) == Data(data))

        let r = try await f.client.open(f.path("big"), flags: .read)
        let back = try await f.client.read(r, offset: 0, length: data.count + 1000)
        try await f.client.close(r)
        #expect(back == data)
    }

    @Test func readAtOffsetAndPastEOF() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try Data("hello world".utf8).write(to: URL(fileURLWithPath: f.path("t")))
        let h = try await f.client.open(f.path("t"), flags: .read)
        #expect(try await f.client.read(h, offset: 6, length: 100) == Array("world".utf8))
        #expect(try await f.client.read(h, offset: 50, length: 10) == [])
        #expect(try await f.client.readChunk(h, offset: 50, length: 10) == nil)
        try await f.client.close(h)
    }

    @Test func listDirectoryReturnsEntriesWithAttributes() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try await f.client.mkdir(f.path("d"))
        try await f.client.mkdir(f.path("d/sub"))
        for i in 0..<250 {  // more than one READDIR batch
            try Data().write(to: URL(fileURLWithPath: f.path("d/file\(i)")))
        }
        let entries = try await f.client.listDirectory(f.path("d"))
        #expect(entries.count == 251)
        #expect(entries.first { $0.filename == "sub" }?.attributes.type == .directory)
        #expect(entries.first { $0.filename == "file7" }?.attributes.type == .regular)
    }

    @Test func renameReplacesExistingTarget() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try Data("new".utf8).write(to: URL(fileURLWithPath: f.path("a")))
        try Data("old".utf8).write(to: URL(fileURLWithPath: f.path("b")))
        try await f.client.rename(f.path("a"), to: f.path("b"))
        #expect(try String(contentsOfFile: f.path("b"), encoding: .utf8) == "new")
        #expect(!FileManager.default.fileExists(atPath: f.path("a")))
    }

    @Test func symlinkAndReadlink() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try await f.client.symlink(target: "some/target", linkPath: f.path("link"))
        #expect(try await f.client.readlink(f.path("link")) == "some/target")
        #expect(try await f.client.lstat(f.path("link")).type == .symlink)
    }

    @Test func setstatChangesModeAndTimes() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try Data().write(to: URL(fileURLWithPath: f.path("x")))
        try await f.client.setstat(f.path("x"), FileAttributes(permissions: 0o600))
        try await f.client.setstat(f.path("x"), FileAttributes(accessTime: 1_000_000, modifyTime: 2_000_000))
        let a = try await f.client.stat(f.path("x"))
        #expect(a.permissions.map { $0 & 0o777 } == 0o600)
        #expect(a.modifyTime == 2_000_000)
    }

    @Test func removeAndRmdir() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try await f.client.mkdir(f.path("d"))
        try Data().write(to: URL(fileURLWithPath: f.path("d/x")))
        await #expect(throws: SFTPError.self) { try await f.client.rmdir(f.path("d")) }
        try await f.client.remove(f.path("d/x"))
        try await f.client.rmdir(f.path("d"))
        #expect(!FileManager.default.fileExists(atPath: f.path("d")))
    }

    @Test func missingFileMapsToENOENT() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        do {
            _ = try await f.client.stat(f.path("nope"))
            Issue.record("expected an error")
        } catch let e as SFTPError {
            #expect(e.statusCode == .noSuchFile)
            #expect(e.errno == ENOENT)
        }
    }

    @Test func statvfsReportsSpace() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let s = try await f.client.statvfs(f.root)
        #expect(s.blocks > 0)
        #expect(s.maxNameLength >= 255)
    }

    @Test func manyConcurrentRequests() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<200 {
                g.addTask { try await f.client.mkdir(f.path("c\(i)")) }
            }
            try await g.waitForAll()
        }
        #expect(try await f.client.listDirectory(f.root).count == 200)
    }

    @Test func serverDeathFailsPendingAndFutureRequests() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        kill(f.transport.processIdentifier!, SIGKILL)
        await #expect(throws: SFTPError.self) { _ = try await f.client.stat(f.root) }
        // Give the reader thread a moment to observe EOF, then check sticky failure.
        for _ in 0..<100 where f.client.failure == nil { try await Task.sleep(for: .milliseconds(10)) }
        if case .connectionLost = f.client.failure {} else { Issue.record("expected connectionLost, got \(String(describing: f.client.failure))") }
        await #expect(throws: SFTPError.self) { _ = try await f.client.stat(f.root) }
    }
}
