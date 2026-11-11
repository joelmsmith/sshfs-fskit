import Foundation

/// SFTP v3 packet types (draft-ietf-secsh-filexfer-02).
enum PacketType: UInt8 {
    case initialize = 1
    case version = 2
    case open = 3
    case close = 4
    case read = 5
    case write = 6
    case lstat = 7
    case fstat = 8
    case setstat = 9
    case fsetstat = 10
    case opendir = 11
    case readdir = 12
    case remove = 13
    case mkdir = 14
    case rmdir = 15
    case realpath = 16
    case stat = 17
    case rename = 18
    case readlink = 19
    case symlink = 20
    case status = 101
    case handle = 102
    case data = 103
    case name = 104
    case attrs = 105
    case extended = 200
    case extendedReply = 201
}

/// Big-endian encoder for SFTP payloads.
struct WireWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 64) { bytes.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { bytes.append(v) }

    mutating func u32(_ v: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 24))
        bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    mutating func u64(_ v: UInt64) {
        u32(UInt32(truncatingIfNeeded: v >> 32))
        u32(UInt32(truncatingIfNeeded: v))
    }

    mutating func string<C: Collection>(_ v: C) where C.Element == UInt8 {
        u32(UInt32(v.count))
        bytes.append(contentsOf: v)
    }

    mutating func string(_ v: String) { string(Array(v.utf8)) }

    mutating func attributes(_ a: FileAttributes) {
        var flags: UInt32 = 0
        if a.size != nil { flags |= FileAttributes.Flag.size }
        if a.uid != nil && a.gid != nil { flags |= FileAttributes.Flag.uidgid }
        if a.permissions != nil { flags |= FileAttributes.Flag.permissions }
        if a.accessTime != nil && a.modifyTime != nil { flags |= FileAttributes.Flag.acmodtime }
        if !a.extended.isEmpty { flags |= FileAttributes.Flag.extended }
        u32(flags)
        if let size = a.size { u64(size) }
        if let uid = a.uid, let gid = a.gid { u32(uid); u32(gid) }
        if let p = a.permissions { u32(p) }
        if let at = a.accessTime, let mt = a.modifyTime { u32(at); u32(mt) }
        if !a.extended.isEmpty {
            u32(UInt32(a.extended.count))
            for (k, v) in a.extended { string(k); string(v) }
        }
    }
}

/// Big-endian decoder for SFTP payloads.
struct WireReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }

    private mutating func take(_ n: Int) throws(SFTPError) -> ArraySlice<UInt8> {
        guard n >= 0, remaining >= n else { throw .badMessage("truncated packet") }
        defer { offset += n }
        return bytes[offset..<offset + n]
    }

    mutating func u8() throws(SFTPError) -> UInt8 { try take(1).first! }

    mutating func u32() throws(SFTPError) -> UInt32 {
        let s = try take(4)
        return s.reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws(SFTPError) -> UInt64 {
        let s = try take(8)
        return s.reduce(0) { $0 << 8 | UInt64($1) }
    }

    mutating func bytesString() throws(SFTPError) -> [UInt8] {
        let n = Int(try u32())
        return Array(try take(n))
    }

    mutating func string() throws(SFTPError) -> String {
        String(decoding: try bytesString(), as: UTF8.self)
    }

    mutating func attributes() throws(SFTPError) -> FileAttributes {
        let flags = try u32()
        var a = FileAttributes()
        if flags & FileAttributes.Flag.size != 0 { a.size = try u64() }
        if flags & FileAttributes.Flag.uidgid != 0 { a.uid = try u32(); a.gid = try u32() }
        if flags & FileAttributes.Flag.permissions != 0 { a.permissions = try u32() }
        if flags & FileAttributes.Flag.acmodtime != 0 { a.accessTime = try u32(); a.modifyTime = try u32() }
        if flags & FileAttributes.Flag.extended != 0 {
            let count = try u32()
            for _ in 0..<count { a.extended.append((try string(), try string())) }
        }
        return a
    }
}
