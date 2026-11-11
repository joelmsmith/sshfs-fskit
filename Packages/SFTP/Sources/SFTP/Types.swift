import Foundation

/// SFTP v3 file attributes. Every field is optional because the server only
/// sends what it has, and a SETSTAT only changes what is present.
public struct FileAttributes: Sendable, Equatable {
    enum Flag {
        static let size: UInt32 = 0x0000_0001
        static let uidgid: UInt32 = 0x0000_0002
        static let permissions: UInt32 = 0x0000_0004
        static let acmodtime: UInt32 = 0x0000_0008
        static let extended: UInt32 = 0x8000_0000
    }

    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    /// Full `st_mode`, including the file type bits.
    public var permissions: UInt32?
    public var accessTime: UInt32?
    public var modifyTime: UInt32?
    public var extended: [(String, String)] = []

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil,
                permissions: UInt32? = nil, accessTime: UInt32? = nil, modifyTime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.accessTime = accessTime
        self.modifyTime = modifyTime
    }

    public enum FileType: Sendable, Equatable {
        case regular, directory, symlink, fifo, socket, characterDevice, blockDevice, unknown
    }

    public var type: FileType {
        guard let p = permissions else { return .unknown }
        switch p & UInt32(S_IFMT) {
        case UInt32(S_IFREG): return .regular
        case UInt32(S_IFDIR): return .directory
        case UInt32(S_IFLNK): return .symlink
        case UInt32(S_IFIFO): return .fifo
        case UInt32(S_IFSOCK): return .socket
        case UInt32(S_IFCHR): return .characterDevice
        case UInt32(S_IFBLK): return .blockDevice
        default: return .unknown
        }
    }

    public static func == (l: FileAttributes, r: FileAttributes) -> Bool {
        l.size == r.size && l.uid == r.uid && l.gid == r.gid && l.permissions == r.permissions
            && l.accessTime == r.accessTime && l.modifyTime == r.modifyTime
            && l.extended.elementsEqual(r.extended, by: { $0 == $1 })
    }
}

/// One entry from READDIR or REALPATH.
public struct DirectoryEntry: Sendable, Equatable {
    /// Raw filename bytes. SFTP v3 does not specify an encoding; OpenSSH sends
    /// whatever bytes are on disk, which is almost always UTF-8.
    public var filenameBytes: [UInt8]
    public var longname: String
    public var attributes: FileAttributes

    public var filename: String { String(decoding: filenameBytes, as: UTF8.self) }
}

/// An opaque server-side handle for an open file or directory.
public struct Handle: Sendable, Hashable {
    let bytes: [UInt8]
}

/// Flags for OPEN.
public struct OpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let read = OpenFlags(rawValue: 0x01)
    public static let write = OpenFlags(rawValue: 0x02)
    public static let append = OpenFlags(rawValue: 0x04)
    public static let create = OpenFlags(rawValue: 0x08)
    public static let truncate = OpenFlags(rawValue: 0x10)
    public static let exclusive = OpenFlags(rawValue: 0x20)
}

/// Result of the `statvfs@openssh.com` extension.
public struct FileSystemStatistics: Sendable, Equatable {
    public var blockSize: UInt64
    public var fragmentSize: UInt64
    public var blocks: UInt64
    public var freeBlocks: UInt64
    public var availableBlocks: UInt64
    public var files: UInt64
    public var freeFiles: UInt64
    public var availableFiles: UInt64
    public var fsid: UInt64
    public var flags: UInt64
    public var maxNameLength: UInt64
}

/// Result of the `limits@openssh.com` extension.
public struct ServerLimits: Sendable, Equatable {
    public var maxPacketLength: UInt64
    public var maxReadLength: UInt64
    public var maxWriteLength: UInt64
    public var maxOpenHandles: UInt64

    /// Conservative values for servers without the extension. 32 KiB reads
    /// and writes are what every SFTP server must accept.
    public static let fallback = ServerLimits(maxPacketLength: 34_000, maxReadLength: 32_768,
                                              maxWriteLength: 32_768, maxOpenHandles: 0)
}
