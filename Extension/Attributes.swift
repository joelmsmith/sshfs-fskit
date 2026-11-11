import Foundation
import FSKit
import SFTP

extension FileAttributes.FileType {
    var fsType: FSItem.ItemType {
        switch self {
        case .regular: .file
        case .directory: .directory
        case .symlink: .symlink
        case .fifo: .fifo
        case .socket: .socket
        case .characterDevice: .charDevice
        case .blockDevice: .blockDevice
        case .unknown: .unknown
        }
    }
}

extension FileAttributes {
    /// Converts SFTP attributes to FSKit's. Ownership is presented as the
    /// local user (like sshfs's `idmap=user`): remote uids mean nothing here.
    func fsAttributes(id: UInt64, parentID: UInt64) -> FSItem.Attributes {
        let a = FSItem.Attributes()
        a.type = type.fsType
        a.mode = (permissions ?? 0) & 0o7777
        a.linkCount = type == .directory ? 2 : 1
        a.uid = getuid()
        a.gid = getgid()
        a.size = size ?? 0
        a.allocSize = ((size ?? 0) + 4095) / 4096 * 4096
        a.fileID = FSItem.Identifier(id)
        a.parentID = FSItem.Identifier(parentID)
        a.flags = 0
        let mtime = timespec(tv_sec: Int(modifyTime ?? 0), tv_nsec: 0)
        a.modifyTime = mtime
        a.changeTime = mtime  // SFTP v3 has no ctime or birth time
        a.birthTime = mtime
        a.accessTime = timespec(tv_sec: Int(accessTime ?? modifyTime ?? 0), tv_nsec: 0)
        return a
    }
}

extension Error {
    /// Converts SFTP errors into the POSIX errors FSKit hands to the kernel.
    var posix: any Error {
        if let e = self as? SFTPError { return fs_errorForPOSIXError(e.errno) }
        if let e = self as? ConnectError { return fs_errorForPOSIXError(e.errno) }
        return self
    }
}

/// FSKit's result initialisers are failable; they only fail on programmer
/// error, so surface that as EIO rather than crashing the extension.
func require<T>(_ value: T?) throws -> T {
    guard let value else { throw fs_errorForPOSIXError(EIO) }
    return value
}

/// Awaits `task` for at most `limit`; nil if it didn't finish in time. (The
/// task keeps running either way.)
func boundedWait<T: Sendable>(_ task: Task<T, Never>, limit: Duration) async -> T? {
    let once = ClaimOnce()
    return await withCheckedContinuation { cont in
        Task { let v = await task.value; if once.claim() { cont.resume(returning: v) } }
        Task { try? await Task.sleep(for: limit); if once.claim() { cont.resume(returning: nil) } }
    }
}

/// A flag that can be claimed exactly once, from any thread.
final class ClaimOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
