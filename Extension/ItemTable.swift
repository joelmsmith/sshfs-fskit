import Foundation
import FSKit
import SFTP
import Synchronization

/// An SFTP handle being opened (or open), tied to the connection generation
/// that owns it; after a reconnect it is stale and gets reopened.
struct OpenHandle: Sendable {
    let generation: UInt64
    let task: Task<Handle, any Error>
}

extension OpenHandle {
    /// A handle that is already open.
    init(generation: UInt64, handle: Handle) {
        self.init(generation: generation, task: Task { handle })
    }
}

/// A file or directory on the remote side, as FSKit sees it.
///
/// SFTP v3 has no inode numbers, so identity is by path: the table hands out
/// a stable ID per path and keeps it across lookups until the path goes away.
final class SFTPItem: FSItem, @unchecked Sendable {
    let id: UInt64
    private let state: Mutex<State>

    struct State {
        var path: String
        var type: FileAttributes.FileType
        var lastAttributes: FileAttributes?
        /// Directory listing snapshot for paged enumeration.
        var listing: (verifier: UInt64, entries: [DirectoryEntry])?
        /// Open SFTP handles, shared by concurrent readers/writers. While the
        /// kernel has a regular file open for writing there is a write handle
        /// (from the create or the open; it reads too): like a descriptor, it
        /// keeps working whatever happens to the file's mode meanwhile.
        var readHandle: OpenHandle?
        var writeHandle: OpenHandle?
        /// The file's mode while it has owner-write added to get a write
        /// handle back (SSHVolume.openForWriting); nil once it's restored.
        var modeToRestore: UInt32?
        var openModes: FSVolume.OpenModes = []
        /// What the kernel was last allowed to cache for this item.
        var cacheMode: FSVolume.DataCacheMode = .none
        var granted: FSVolume.KernelCacheCoherencyType = .noCache
        /// (mtime, size) the directory poller last saw on the server. Kept
        /// apart from lastAttributes, which may be refreshed from cache.
        var polled: (UInt32?, UInt64?)?
        /// Reads and writes running now, and handles a close took away
        /// while they ran (closed when the count drops to zero).
        var ioInFlight = 0
        var retired: [OpenHandle] = []
        /// Reads and writes the kernel sent us since the item was last
        /// fully closed (logged at close: shows what its cache absorbed).
        var io = IOCounts()
        /// First error from a buffered (write-back) write that the app may
        /// never have seen; reported by the next synchronize.
        var deferredWriteError: Int32?
    }

    init(id: UInt64, path: String, type: FileAttributes.FileType) {
        self.id = id
        self.state = Mutex(State(path: path, type: type))
        super.init()
    }

    var path: String { state.withLock { $0.path } }
    var type: FileAttributes.FileType { state.withLock { $0.type } }

    func withState<R>(_ body: (inout State) throws -> R) rethrows -> R {
        try state.withLock { try body(&$0) }
    }
}

struct IOCounts {
    var reads = 0, readBytes = 0, largestRead = 0
    var writes = 0, writtenBytes = 0, largestWrite = 0
    var isEmpty: Bool { reads == 0 && writes == 0 }
}

/// Path <-> ID bookkeeping plus a short-lived attribute cache.
final class ItemTable: Sendable {
    private struct State {
        var ids: [String: UInt64] = [:]
        var items: [UInt64: SFTPItem] = [:]
        var nextID: UInt64 = FSItem.Identifier.rootDirectory.rawValue + 1
        var attributes: [String: (FileAttributes, ContinuousClock.Instant)] = [:]
        /// Names in recently listed directories, for answering negative
        /// lookups (e.g. the kernel probing for AppleDouble `._name` files)
        /// without a round trip.
        var listings: [String: (Set<String>, ContinuousClock.Instant)] = [:]
        /// Extended attributes, kept in memory for the life of the mount
        /// (SFTP can't store them, and we don't want ._ files on the server).
        var xattrs: [String: [String: Data]] = [:]
    }

    private let state = Mutex(State())
    let rootPath: String
    let root: SFTPItem
    /// How long attributes from STAT/READDIR are trusted (sshfs defaults to 20 s).
    var attributeTTL: Duration { ttl.load(ordering: .relaxed).duration }
    private let ttl: Atomic<Int64>
    func setAttributeTTL(_ d: Duration) { ttl.store(d.milliseconds, ordering: .relaxed) }

    init(rootPath: String, attributeTTL: Duration = .seconds(20)) {
        self.rootPath = rootPath
        self.ttl = Atomic(attributeTTL.milliseconds)
        root = SFTPItem(id: FSItem.Identifier.rootDirectory.rawValue, path: rootPath, type: .directory)
        state.withLock {
            $0.ids[rootPath] = root.id
            $0.items[root.id] = root
        }
    }

    static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    /// The stable ID for a path, allocating one if needed.
    func id(for path: String) -> UInt64 {
        state.withLock { s in
            if let id = s.ids[path] { return id }
            let id = s.nextID
            s.nextID += 1
            s.ids[path] = id
            return id
        }
    }

    /// The live item for a path, creating it if FSKit doesn't hold one yet.
    func item(for path: String, type: FileAttributes.FileType) -> SFTPItem {
        state.withLock { s in
            let id: UInt64
            if let existing = s.ids[path] { id = existing } else {
                id = s.nextID
                s.nextID += 1
                s.ids[path] = id
            }
            if let item = s.items[id] { return item }
            let item = SFTPItem(id: id, path: path, type: type)
            s.items[id] = item
            return item
        }
    }

    func parentID(of path: String) -> UInt64 {
        if path == rootPath { return FSItem.Identifier.parentOfRoot.rawValue }
        let parent = (path as NSString).deletingLastPathComponent
        return id(for: parent.isEmpty ? "/" : parent)
    }

    /// Items FSKit currently holds.
    func liveItems() -> [SFTPItem] {
        state.withLock { Array($0.items.values) }
    }

    /// FSKit is done with this item.
    func reclaim(_ item: SFTPItem) {
        guard item.id != root.id else { return }
        state.withLock { _ = $0.items.removeValue(forKey: item.id) }
    }

    /// The path no longer exists (removed, or renamed away).
    func forget(_ path: String) {
        state.withLock { s in
            s.ids.removeValue(forKey: path)
            s.attributes.removeValue(forKey: path)
            s.listings.removeValue(forKey: path)
            s.listings.removeValue(forKey: (path as NSString).deletingLastPathComponent)
            s.xattrs.removeValue(forKey: path)
        }
    }

    /// Moves `from` (and everything under it) to `to`, keeping IDs.
    func rename(_ from: String, to: String) {
        state.withLock { s in
            // rename(x, x) succeeds and changes nothing.
            if from == to {
                s.attributes.removeValue(forKey: from)
                return
            }
            // Whatever was at the destination is gone.
            s.ids.removeValue(forKey: to)
            s.xattrs.removeValue(forKey: to)
            let prefix = from + "/"
            for (path, x) in s.xattrs where path == from || path.hasPrefix(prefix) {
                s.xattrs.removeValue(forKey: path)
                s.xattrs[to + path.dropFirst(from.count)] = x
            }
            for (path, id) in s.ids where path == from || path.hasPrefix(prefix) {
                let newPath = to + path.dropFirst(from.count)
                s.ids.removeValue(forKey: path)
                s.ids[newPath] = id
                s.items[id]?.withState { $0.path = newPath }
            }
            s.attributes = s.attributes.filter { !($0.key == from || $0.key.hasPrefix(prefix) || $0.key == to) }
            s.listings = s.listings.filter { !($0.key == from || $0.key.hasPrefix(prefix)) }
            s.listings.removeValue(forKey: (from as NSString).deletingLastPathComponent)
            s.listings.removeValue(forKey: (to as NSString).deletingLastPathComponent)
        }
    }

    // MARK: Attribute cache

    func cachedAttributes(_ path: String) -> FileAttributes? {
        state.withLock { s in
            guard let (attrs, time) = s.attributes[path] else { return nil }
            if ContinuousClock.now - time > attributeTTL {
                s.attributes.removeValue(forKey: path)
                return nil
            }
            return attrs
        }
    }

    func cache(_ attrs: FileAttributes, for path: String) {
        state.withLock { $0.attributes[path] = (attrs, .now) }
    }

    /// Drops cached attributes for `path` and, if it's a directory, its
    /// cached listing (call after changing its entries).
    func invalidate(_ path: String) {
        state.withLock {
            $0.attributes.removeValue(forKey: path)
            $0.listings.removeValue(forKey: path)
        }
    }

    /// Drops cached attributes of every direct entry of `dir` (it changed on
    /// the server, so any of them may be gone or different).
    func invalidateEntries(of dir: String) {
        let prefix = dir == "/" ? "/" : dir + "/"
        state.withLock { s in
            s.attributes = s.attributes.filter { key, _ in
                !(key.hasPrefix(prefix) && !key.dropFirst(prefix.count).contains("/"))
            }
        }
    }

    // MARK: Extended attributes (session-only)

    func xattrs(_ path: String) -> [String: Data] {
        state.withLock { $0.xattrs[path] ?? [:] }
    }

    func setXattrs(_ x: [String: Data], for path: String) {
        state.withLock { $0.xattrs[path] = x.isEmpty ? nil : x }
    }

    // MARK: Negative lookups

    func cacheListing(_ names: Set<String>, for dir: String) {
        state.withLock { $0.listings[dir] = (names, .now) }
    }

    /// True if `name` is known not to exist in `dir` (a fresh listing lacks it).
    func knownAbsent(_ name: String, in dir: String) -> Bool {
        state.withLock { s in
            guard let (names, time) = s.listings[dir] else { return false }
            if ContinuousClock.now - time > attributeTTL {
                s.listings.removeValue(forKey: dir)
                return false
            }
            return !names.contains(name)
        }
    }
}

extension Duration {
    var milliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}
extension Int64 {
    var duration: Duration { .milliseconds(self) }
}
