import Foundation
import FSKit
import SFTP
import Synchronization

/// An FSKit volume backed by one SFTP session.
final class SSHVolume: FSVolume, FSVolume.Handler, FSVolume.DataCacheHandler,
                       FSVolume.ReadWriteHandler, FSVolume.XattrHandler, @unchecked Sendable {
    let remote: Remote
    let table: ItemTable
    private let stats = Mutex<(FSStatFSResult, ContinuousClock.Instant)?>(nil)
    private let verifierCounter = Atomic<UInt64>(1)
    /// Directories the kernel used recently; polled for remote changes so the
    /// kernel's name cache (including negative entries) can be invalidated.
    private let hotDirectories = Mutex<[UInt64: (item: SFTPItem, lastUsed: ContinuousClock.Instant)]>([:])
    private let poller = Mutex<Task<Void, Never>?>(nil)
    private lazy var liveness = Liveness(remote: remote)
    private let pollIntervalMs: Atomic<Int64>
    private var pollInterval: Duration { pollIntervalMs.load(ordering: .relaxed).duration }
    static let hotWindow: Duration = .seconds(120)
    static let maxPolledDirectories = 64

    init(remote: Remote, rootPath: String, name: String, options: SSHFSOptions, volumeID: FSVolume.Identifier) {
        self.remote = remote
        self.table = ItemTable(rootPath: rootPath, attributeTTL: options.cacheTimeout)
        self.pollIntervalMs = Atomic(options.dirPoll.milliseconds)
        super.init(volumeID: volumeID, volumeName: FSFileName(string: name))
    }

    // MARK: - PathConf

    var maximumLinkCount: Int { 32_767 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
    var maximumFileSize: UInt64 { UInt64(Int64.max) }

    // MARK: - Capabilities and statistics

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsSymbolicLinks = true
        caps.supportsHardLinks = remote.supports("hardlink@openssh.com")
        caps.supports64BitObjectIDs = true
        caps.supportsHiddenFiles = true
        caps.supports2TBFiles = true
        caps.supportsSparseFiles = true
        caps.caseFormat = .sensitive
        return caps
    }

    /// statfs must answer synchronously, so serve a cached statvfs result and
    /// refresh it in the background.
    var volumeStatistics: FSStatFSResult {
        let cached = stats.withLock { $0 }
        if cached == nil || ContinuousClock.now - cached!.1 > .seconds(30) {
            Task { await refreshStatistics() }
        }
        return cached?.0 ?? Self.emptyStatistics()
    }

    private static func emptyStatistics() -> FSStatFSResult {
        let r = FSStatFSResult(fileSystemTypeName: "sshfs")
        r.blockSize = 4096
        r.ioSize = 1 << 20
        return r
    }

    func refreshStatistics() async {
        let root = table.rootPath
        guard let s = try? await remote.run({ try await $0.client.statvfs(root) }) else { return }
        let r = Self.emptyStatistics()
        let frag = max(s.fragmentSize, 1)
        r.blockSize = Int(frag)
        r.totalBlocks = s.blocks
        r.freeBlocks = s.freeBlocks
        r.availableBlocks = s.availableBlocks
        r.usedBlocks = s.blocks - s.freeBlocks
        r.totalBytes = s.blocks * frag
        r.freeBytes = s.freeBlocks * frag
        r.availableBytes = s.availableBlocks * frag
        r.usedBytes = r.totalBytes - r.freeBytes
        r.totalFiles = s.files
        r.freeFiles = s.freeFiles
        stats.withLock { $0 = (r, .now) }
    }

    // MARK: - Lifecycle

    func activateVolume(options: FSTaskOptions) async throws -> FSActivateResult {
        log.info("activate root=\(self.table.rootPath, privacy: .public) options=\(options.taskOptions, privacy: .public)")
        // `mount -o` options arrive here (after we've connected): our tunables
        // apply now; ssh options would have been needed earlier.
        var opts = SSHFSOptions()
        opts.cacheTimeout = table.attributeTTL
        opts.dirPoll = pollInterval
        let unknown = opts.apply(SSHFSOptions.pairs(fromTaskOptions: options.taskOptions))
        if !unknown.isEmpty { log.notice("ignoring unknown mount options: \(unknown, privacy: .public)") }
        if !opts.sshOptions.isEmpty {
            log.error("ssh options must be given in the URL (the sshfs command does this); ignoring \(opts.sshOptions, privacy: .public)")
        }
        table.setAttributeTTL(opts.cacheTimeout)
        pollIntervalMs.store(opts.dirPoll.milliseconds, ordering: .relaxed)
        log.info("cache_timeout=\(String(describing: opts.cacheTimeout), privacy: .public) dir_poll=\(String(describing: opts.dirPoll), privacy: .public)")
        await refreshStatistics()
        // Baseline for change detection on the root directory.
        let root = table.rootPath
        if let a = try? await remote.run({ try await $0.client.lstat(root) }) {
            table.root.withState { $0.lastAttributes = a }
        }
        startDirectoryPoller()
        liveness.start()
        return try require(FSActivateResult(rootItem: table.root))
    }

    func deactivateVolume(options: FSDeactivateOptions) async throws {
        log.info("deactivate")
        poller.withLock { $0?.cancel(); $0 = nil }
        liveness.stop()
        remote.disconnect()
    }

    func mount(options: FSTaskOptions) async throws {
        log.info("mount options=\(options.taskOptions, privacy: .public)")
    }

    func unmount() async {
        log.info("unmount")
    }

    /// sync(2)/fsync(2): the kernel has pushed dirty pages to us via write();
    /// make the server commit them (fsync@openssh.com) and report any write
    /// error that happened while data was buffered.
    func synchronize(flags: FSSyncFlags) async throws {
        log.info("synchronize flags=\(flags.rawValue)")
        guard let session = try? await remote.current() else { throw fs_errorForPOSIXError(ENOTCONN) }
        var firstError: Int32?
        for item in table.liveItems() {
            let (h, deferred) = item.withState { s -> (OpenHandle?, Int32?) in
                defer { s.deferredWriteError = nil }
                return (s.writeHandle, s.deferredWriteError)
            }
            if let deferred, firstError == nil { firstError = deferred }
            guard let h, h.generation == session.generation, let handle = try? await h.task.value else { continue }
            do {
                try await session.client.fsync(handle)
            } catch {
                log.error("fsync \(item.path, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                if firstError == nil { firstError = (error as? SFTPError)?.errno ?? EIO }
            }
        }
        if let firstError { throw fs_errorForPOSIXError(firstError) }
    }

    func reclaimItem(_ item: FSItem) async throws {
        guard let item = item as? SFTPItem else { return }
        await closeHandles(item, keeping: [])
        table.reclaim(item)
    }

    // MARK: - Directory change polling

    private func touch(_ dir: SFTPItem) {
        hotDirectories.withLock { $0[dir.id] = (dir, .now) }
    }

    private func startDirectoryPoller() {
        poller.withLock { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                while !Task.isCancelled {
                    let interval = self?.pollInterval ?? .seconds(5)
                    if interval == .zero { return }   // dir_poll=0: disabled
                    try? await Task.sleep(for: interval)
                    await self?.pollDirectories()
                }
            }
        }
    }

    /// Re-stats recently used directories (in parallel: ~one round trip) and
    /// invalidates any that changed on the server. Directory invalidation
    /// purges the kernel's name cache for its entries, negative ones included.
    private func pollDirectories() async {
        let dirs: [SFTPItem] = hotDirectories.withLock { hot in
            let now = ContinuousClock.now
            hot = hot.filter { now - $0.value.lastUsed < Self.hotWindow }
            return hot.values.sorted { $0.lastUsed > $1.lastUsed }
                .prefix(Self.maxPolledDirectories).map(\.item)
        }
        guard !dirs.isEmpty, (try? await remote.current()) != nil else { return }
        await withTaskGroup(of: Void.self) { group in
            for dir in dirs {
                group.addTask { [self] in
                    let path = dir.path
                    guard let a = try? await remote.run({ try await $0.client.lstat(path) }) else { return }
                    let now = (a.modifyTime, a.size)
                    let changed = dir.withState { s -> Bool in
                        // First poll: baseline from what we last told the kernel.
                        let before = s.polled ?? s.lastAttributes.map { ($0.modifyTime, $0.size) }
                        s.polled = now
                        s.lastAttributes = a
                        guard let before else { return false }
                        return before.0 != now.0 || before.1 != now.1
                    }
                    table.cache(a, for: path)
                    if changed {
                        table.invalidate(path)          // our listing + negative cache
                        table.invalidateEntries(of: path)
                        table.cache(a, for: path)
                        await invalidateKernelCache(dir).value
                    }
                }
            }
        }
    }

    // MARK: - Metadata helpers

    /// lstat with a short-lived cache (directory listings fill it too).
    private func attributes(of path: String, fresh: Bool = false) async throws -> FileAttributes {
        if !fresh, let a = table.cachedAttributes(path) { return a }
        let a = try await remote.run { try await $0.client.lstat(path) }
        table.cache(a, for: path)
        return a
    }

    private func fsAttributes(_ attrs: FileAttributes, path: String) -> FSItem.Attributes {
        attrs.fsAttributes(id: table.id(for: path), parentID: table.parentID(of: path))
    }

    private func currentAttributes(of item: SFTPItem, fresh: Bool = false) async throws -> FSItem.Attributes {
        let path = item.path
        let a = try await attributes(of: path, fresh: fresh)
        observe(a, for: item)
        return fsAttributes(a, path: path)
    }

    /// Records fresh attributes for an item. If the item changed on the server
    /// since we last looked (and not because we're writing to it), the kernel's
    /// cached pages -- and for a directory, its cached names, including negative
    /// lookups -- are stale, so tell the kernel to drop them.
    @discardableResult
    private func observe(_ a: FileAttributes, for item: SFTPItem, invalidate: Bool = true) -> Bool {
        let changed = item.withState { s -> Bool in
            defer { s.lastAttributes = a; s.type = a.type }
            guard let old = s.lastAttributes, s.writeHandle == nil else { return false }
            return old.modifyTime != a.modifyTime || old.size != a.size
        }
        if changed && invalidate { invalidateKernelCache(item) }
        return changed
    }

    @discardableResult
    private func invalidateKernelCache(_ item: SFTPItem) -> Task<Bool, Never> {
        let path = item.path
        // An invalidate must be a downgrade, so drop to no caching; the next
        // open (or the kernel's upgrade request) re-grants caching.
        let mode = item.withState { s -> FSVolume.DataCacheMode in
            let m = s.cacheMode
            s.cacheMode = .none; s.granted = .noCache
            return m
        }
        // setCacheState is synchronous and may call back into us, so it runs
        // on its own task rather than inline in a callback.
        // macOS 27.2 refuses to invalidate the volume's root directory
        // (kIOReturnBadArgument for every mode/action tried), so negative
        // name-cache entries at the top level of a mount can't be purged.
        if item.id == table.root.id {
            log.debug("skipping invalidation of volume root (unsupported)")
            return Task { false }
        }
        // For directories the kernel never opens through us, cacheMode is
        // .none; (.none, .noCache, .invalidate) is what it accepts.
        return Task.detached { [self] in
            if let error = self.setCacheState(for: item, cacheMode: mode, coherencyType: .noCache, action: .invalidate) {
                log.error("invalidate \(path, privacy: .public) failed: \(error, privacy: .public)")
                return false
            }
            log.info("invalidated kernel cache for \(path, privacy: .public)")
            return true
        }
    }

    private func path(of directory: FSItem, _ name: FSFileName) throws -> String {
        guard let dir = directory as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
        guard let s = name.string, !s.isEmpty, !s.contains("/") else { throw fs_errorForPOSIXError(EINVAL) }
        return ItemTable.join(dir.path, s)
    }

    /// Path for a new entry: like `path(of:_:)`, but refuses macOS metadata
    /// files (Finder's .DS_Store, AppleDouble ._name) so they never land on
    /// the server. Finder treats the EACCES as "can't store view settings".
    private func newEntryPath(in directory: FSItem, _ name: FSFileName) throws -> String {
        if let s = name.string, s == ".DS_Store" || s.hasPrefix("._") {
            log.debug("refusing to create \(s, privacy: .public)")
            throw fs_errorForPOSIXError(EACCES)
        }
        return try path(of: directory, name)
    }

    // MARK: - Lookup and attributes

    func lookupItem(named name: FSFileName, in directory: FSItem, context: FSContext) async throws -> FSLookupItemResult {
        do {
            let path = try path(of: directory, name)
            if let dir = directory as? SFTPItem { touch(dir) }
            if let dir = directory as? SFTPItem, let n = name.string, table.knownAbsent(n, in: dir.path) {
                throw fs_errorForPOSIXError(ENOENT)
            }
            let a = try await attributes(of: path)
            let item = table.item(for: path, type: a.type)
            observe(a, for: item)
            return try require(FSLookupItemResult(foundItem: item, itemName: name,
                                                  itemAttributes: fsAttributes(a, path: path)))
        } catch { throw error.posix }
    }

    func attributes(_ desired: FSItem.GetAttributesRequest, of item: FSItem,
                    context: FSContext) async throws -> FSGetAttributesResult {
        do {
            guard let item = item as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            return try require(FSGetAttributesResult(attributes: try await currentAttributes(of: item)))
        } catch { throw error.posix }
    }

    func setAttributes(_ request: FSItem.SetAttributesRequest, on item: FSItem,
                       context: FSContext) async throws -> FSSetAttributesResult {
        do {
            guard let item = item as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let path = item.path
            var change = FileAttributes()
            var consumed: FSItem.Attribute = []
            if request.isValid(.size) { change.size = request.size; consumed.insert(.size) }
            if request.isValid(.mode) { change.permissions = request.mode & 0o7777; consumed.insert(.mode) }
            if request.isValid(.accessTime) || request.isValid(.modifyTime) {
                // SFTP v3 sets both times together.
                let current = try await attributes(of: path, fresh: true)
                change.accessTime = request.isValid(.accessTime) ? UInt32(clamping: request.accessTime.tv_sec) : current.accessTime
                change.modifyTime = request.isValid(.modifyTime) ? UInt32(clamping: request.modifyTime.tv_sec) : current.modifyTime
                if request.isValid(.accessTime) { consumed.insert(.accessTime) }
                if request.isValid(.modifyTime) { consumed.insert(.modifyTime) }
            }
            // Ownership is presented as the local user; accept and ignore changes
            // so tools like `cp -p` don't fail.
            if request.isValid(.uid) { consumed.insert(.uid) }
            if request.isValid(.gid) { consumed.insert(.gid) }
            if request.isValid(.flags) { consumed.insert(.flags) }

            if change != FileAttributes() {
                let c = change
                try await remote.run { try await $0.client.setstat(path, c) }
            }
            request.consumedAttributes = consumed
            table.invalidate(path)
            return try require(FSSetAttributesResult(attributes: try await currentAttributes(of: item, fresh: true),
                                                     freeSpace: nil))
        } catch { throw error.posix }
    }

    // MARK: - Directories

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier, attributes desired: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker, context: FSContext) async throws -> FSEnumerateDirectoryResult {
        do {
            guard let dir = directory as? SFTPItem else { throw fs_errorForPOSIXError(ENOTDIR) }
            let dirPath = dir.path
            touch(dir)

            // Reuse the snapshot for continuation calls; refetch at cookie 0
            // or when the caller's verifier is stale.
            var snapshot = dir.withState { $0.listing }
            if cookie.rawValue == 0 || snapshot == nil || snapshot!.verifier != verifier.rawValue {
                let entries = try await remote.run { try await $0.client.listDirectory(dirPath) }
                for e in entries {
                    table.cache(e.attributes, for: ItemTable.join(dirPath, e.filename))
                }
                table.cacheListing(Set(entries.map(\.filename)), for: dirPath)
                snapshot = (verifierCounter.add(1, ordering: .relaxed).newValue, entries)
                let s = snapshot
                dir.withState { $0.listing = s }
            }
            let (currentVerifier, entries) = snapshot!

            // Without an attributes request this is getdirentries(), which
            // wants "." and ".."; with one it's getattrlistbulk(), which doesn't.
            var rows: [(name: String, type: FSItem.ItemType, id: UInt64, attrs: FileAttributes?)] = []
            if desired == nil {
                rows.append((".", .directory, dir.id, nil))
                rows.append(("..", .directory, table.parentID(of: dirPath), nil))
            }
            for e in entries {
                let p = ItemTable.join(dirPath, e.filename)
                rows.append((e.filename, e.attributes.type.fsType, table.id(for: p), e.attributes))
            }

            var index = Int(cookie.rawValue)
            while index < rows.count {
                let row = rows[index]
                let attrs = desired == nil ? nil : row.attrs.map {
                    $0.fsAttributes(id: row.id, parentID: dir.id)
                }
                guard packer.packEntry(name: FSFileName(string: row.name), itemType: row.type,
                                       itemID: FSItem.Identifier(row.id),
                                       nextCookie: FSDirectoryCookie(rawValue: UInt64(index + 1)),
                                       attributes: attrs) else { break }
                index += 1
            }
            if index >= rows.count {
                dir.withState { $0.listing = nil }
            }
            return try require(FSEnumerateDirectoryResult(verifier: currentVerifier))
        } catch { throw error.posix }
    }

    // MARK: - Create, link, remove, rename

    func createItem(named name: FSFileName, type: FSItem.ItemType, in directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    context: FSContext) async throws -> FSCreateItemResult {
        do {
            guard let dir = directory as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let path = try newEntryPath(in: directory, name)
            let mode = newAttributes.isValid(.mode) ? newAttributes.mode & 0o7777 : nil
            switch type {
            case .file:
                try await remote.run(idempotent: false) {
                    let h = try await $0.client.open(path, flags: [.write, .create, .exclusive],
                                                     attributes: FileAttributes(permissions: mode ?? 0o644))
                    try await $0.client.close(h)
                }
            case .directory:
                try await remote.run(idempotent: false) {
                    try await $0.client.mkdir(path, attributes: FileAttributes(permissions: mode ?? 0o755))
                }
            default:
                throw fs_errorForPOSIXError(ENOTSUP)
            }
            table.invalidate(dir.path)
            let a = try await attributes(of: path, fresh: true)
            let item = table.item(for: path, type: a.type)
            return try require(FSCreateItemResult(newItem: item, newItemName: name,
                                                  newItemAttributes: fsAttributes(a, path: path),
                                                  directoryAttributes: try await currentAttributes(of: dir, fresh: true),
                                                  freeSpace: nil))
        } catch { throw error.posix }
    }

    func createSymbolicLink(named name: FSFileName, in directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            context: FSContext) async throws -> FSCreateSymlinkResult {
        do {
            guard let dir = directory as? SFTPItem, let target = contents.string else { throw fs_errorForPOSIXError(EINVAL) }
            let path = try newEntryPath(in: directory, name)
            try await remote.run(idempotent: false) { try await $0.client.symlink(target: target, linkPath: path) }
            table.invalidate(dir.path)
            let a = try await attributes(of: path, fresh: true)
            let item = table.item(for: path, type: .symlink)
            return try require(FSCreateSymlinkResult(newItem: item, newItemName: name,
                                                     newItemAttributes: fsAttributes(a, path: path),
                                                     directoryAttributes: try await currentAttributes(of: dir, fresh: true),
                                                     freeSpace: nil))
        } catch { throw error.posix }
    }

    func createLink(to item: FSItem, named name: FSFileName, in directory: FSItem,
                    context: FSContext) async throws -> FSCreateLinkResult {
        do {
            guard let item = item as? SFTPItem, let dir = directory as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let path = try newEntryPath(in: directory, name)
            let existing = item.path
            try await remote.run(idempotent: false) { try await $0.client.hardlink(existing: existing, newPath: path) }
            table.invalidate(existing)
            table.invalidate(dir.path)
            return try require(FSCreateLinkResult(linkName: name,
                                                  linkAttributes: try await currentAttributes(of: item, fresh: true),
                                                  directoryAttributes: try await currentAttributes(of: dir, fresh: true),
                                                  freeSpace: nil))
        } catch { throw error.posix }
    }

    func readSymbolicLink(_ item: FSItem, context: FSContext) async throws -> FSReadSymlinkResult {
        do {
            guard let item = item as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let linkPath = item.path
            let target = try await remote.run { try await $0.client.readlink(linkPath) }
            return try require(FSReadSymlinkResult(contents: FSFileName(string: target),
                                                   symlinkAttributes: try await currentAttributes(of: item)))
        } catch { throw error.posix }
    }

    func removeItem(_ item: FSItem, named name: FSFileName, from directory: FSItem,
                    context: FSContext) async throws -> FSRemoveItemResult {
        do {
            guard let item = item as? SFTPItem, let dir = directory as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let path = item.path
            let before = try await currentAttributes(of: item)
            if item.type == .directory {
                do {
                    try await remote.run(idempotent: false) { try await $0.client.rmdir(path) }
                } catch let e as SFTPError where e.statusCode == .failure {
                    // SFTP v3 reports a non-empty directory as a generic failure.
                    throw fs_errorForPOSIXError(ENOTEMPTY)
                }
            } else {
                try await remote.run(idempotent: false) { try await $0.client.remove(path) }
            }
            table.forget(path)
            table.invalidate(dir.path)
            return try require(FSRemoveItemResult(itemAttributes: before,
                                                  directoryAttributes: try await currentAttributes(of: dir, fresh: true),
                                                  freeSpace: nil))
        } catch { throw error.posix }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName,
                    to destinationName: FSFileName, inDirectory destinationDirectory: FSItem,
                    overItem: FSItem?, context: FSContext) async throws -> FSRenameItemResult {
        do {
            guard let item = item as? SFTPItem, let src = sourceDirectory as? SFTPItem,
                  let dst = destinationDirectory as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let from = item.path
            let to = try newEntryPath(in: destinationDirectory, destinationName)
            let overAttrs: FSItem.Attributes? = if let over = overItem as? SFTPItem {
                try? await currentAttributes(of: over)
            } else { nil }
            try await remote.run(idempotent: false) { try await $0.client.rename(from, to: to) }
            table.rename(from, to: to)
            table.invalidate(src.path)
            table.invalidate(dst.path)
            return try require(FSRenameItemResult(newName: destinationName,
                                                  renamedItemAttributes: try await currentAttributes(of: item, fresh: true),
                                                  sourceDirectoryAttributes: try await currentAttributes(of: src, fresh: true),
                                                  destinationDirectoryAttributes: try await currentAttributes(of: dst, fresh: true),
                                                  overItemAttributes: overAttrs,
                                                  freeSpace: nil))
        } catch { throw error.posix }
    }

    // MARK: - Extended attributes (session-only, in memory)

    func xattr(named name: FSFileName, of item: FSItem, context: FSContext) async throws -> FSGetXattrResult {
        guard let item = item as? SFTPItem, let key = name.string else { throw fs_errorForPOSIXError(EINVAL) }
        guard let value = table.xattrs(item.path)[key] else { throw fs_errorForPOSIXError(ENOATTR) }
        return try require(FSGetXattrResult(xattrValue: value))
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy,
                  context: FSContext) async throws -> FSSetXattrResult {
        guard let item = item as? SFTPItem, let key = name.string else { throw fs_errorForPOSIXError(EINVAL) }
        let path = item.path
        var x = table.xattrs(path)
        let exists = x[key] != nil
        switch policy {
        case .mustCreate where exists: throw fs_errorForPOSIXError(EEXIST)
        case .mustReplace where !exists, .delete where !exists: throw fs_errorForPOSIXError(ENOATTR)
        case .delete: x.removeValue(forKey: key)
        default: x[key] = value ?? Data()
        }
        table.setXattrs(x, for: path)
        return try require(FSSetXattrResult(freeSpace: nil))
    }

    func xattrs(of item: FSItem, context: FSContext) async throws -> FSListXattrsResult {
        guard let item = item as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
        let names = table.xattrs(item.path).keys.sorted().map { FSFileName(string: $0) }
        return try require(FSListXattrsResult(xattrNames: names))
    }

    // MARK: - Open / close

    /// Close-to-open consistency (like NFS): every open revalidates with the
    /// server, and drops the kernel's cached pages if the file changed.
    func open(_ item: FSItem, modes: FSVolume.OpenModes, cacheMode: FSVolume.DataCacheMode,
              context: FSContext) async throws -> FSOpenItemResult {
        do {
            guard let item = item as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            if item.type != .directory {
                let a = try await attributes(of: item.path, fresh: true)
                if observe(a, for: item, invalidate: false) {
                    // Drop stale pages before the kernel reads through this
                    // open. Bounded in case the kernel waits on this very open.
                    let done = await boundedWait(invalidateKernelCache(item), limit: .seconds(1))
                    if done == nil { log.error("invalidate during open timed out: \(item.path, privacy: .public)") }
                }
            }
            let granted = grant(for: cacheMode)
            item.withState {
                $0.openModes.formUnion(modes)
                $0.cacheMode = cacheMode
                $0.granted = granted
            }
            return FSOpenItemResult(grantedCoherency: granted)
        } catch { throw error.posix }
    }

    func upgrade(_ item: FSItem, cacheMode: FSVolume.DataCacheMode,
                 context: FSContext) async throws -> FSUpgradeItemResult {
        let granted = grant(for: cacheMode)
        (item as? SFTPItem)?.withState { $0.cacheMode = cacheMode; $0.granted = granted }
        return FSUpgradeItemResult(grantedCoherency: granted)
    }

    func close(_ item: FSItem, context: FSContext) async {
        guard let item = item as? SFTPItem else { return }
        await closeHandles(item, keeping: [])
    }

    /// Reads are cached between revalidations; writes are buffered by the
    /// kernel (write-back) and pushed to us in large chunks, which is what
    /// makes small writes fast. fsync(2) still reaches the server's disk.
    private func grant(for mode: FSVolume.DataCacheMode) -> FSVolume.KernelCacheCoherencyType {
        switch mode {
        case .none: .noCache
        case .readWithCache: .readCache
        case .readWriteWithCache: .writeBack
        @unknown default: .noCache
        }
    }

    /// Lazily opens (and shares) the SFTP handle for reading or writing on
    /// the given session. Handles from an older connection are reopened.
    private func openHandle(for item: SFTPItem, write: Bool, session: Session) async throws -> Handle {
        let path = item.path
        let handle = item.withState { s -> OpenHandle in
            let gen = session.generation
            if write, let h = s.writeHandle, h.generation == gen { return h }
            if !write, let h = s.readHandle ?? s.writeHandle, h.generation == gen { return h }
            let client = session.client
            let h = OpenHandle(generation: gen, task: Task {
                try await client.open(path, flags: write ? [.read, .write] : .read)
            })
            if write { s.writeHandle = h } else { s.readHandle = h }
            return h
        }
        do {
            return try await handle.task.value
        } catch {
            // Don't cache a failed open.
            item.withState { s in
                if s.readHandle?.generation == handle.generation, !write { s.readHandle = nil }
                if s.writeHandle?.generation == handle.generation, write { s.writeHandle = nil }
            }
            throw error
        }
    }

    /// Closes the SFTP handles the remaining open modes don't need.
    private func closeHandles(_ item: SFTPItem, keeping modes: FSVolume.OpenModes) async {
        let io = item.withState { s -> IOCounts? in
            guard modes.isEmpty, !s.io.isEmpty else { return nil }
            defer { s.io = IOCounts() }
            return s.io
        }
        if let io {
            log.info("closed \(item.path, privacy: .public): \(io.reads) reads, \(io.readBytes) bytes, largest \(io.largestRead); \(io.writes) writes, \(io.writtenBytes) bytes, largest \(io.largestWrite)")
        }
        let toClose: [OpenHandle] = item.withState { s in
            s.openModes = modes
            if !modes.contains(.write), let h = s.writeHandle { s.retired.append(h); s.writeHandle = nil }
            if modes.isEmpty, let h = s.readHandle { s.retired.append(h); s.readHandle = nil }
            // A read or write still running may be using a retired handle:
            // the last one to finish closes them (see withIO).
            guard s.ioInFlight == 0 else { return [] }
            defer { s.retired = [] }
            return s.retired
        }
        await closeHandles(toClose)
    }

    private func closeHandles(_ handles: [OpenHandle]) async {
        guard !handles.isEmpty, let session = try? await remote.current() else { return }
        for h in handles where h.generation == session.generation {
            if let handle = try? await h.task.value { try? await session.client.close(handle) }
        }
    }

    /// Brackets one read or write so a concurrent close doesn't close its
    /// SFTP handle under it.
    private func withIO<R>(_ item: SFTPItem, _ body: () async throws -> R) async throws -> R {
        item.withState { $0.ioInFlight += 1 }
        defer {
            let retired = item.withState { s -> [OpenHandle] in
                s.ioInFlight -= 1
                guard s.ioInFlight == 0 else { return [] }
                defer { s.retired = [] }
                return s.retired
            }
            if !retired.isEmpty { Task { await self.closeHandles(retired) } }
        }
        return try await body()
    }

    // MARK: - Read / write

    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer) async throws -> FSReadFileResult {
        do {
            guard let item = item as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let want = min(length, buffer.length)
            let data = try await withIO(item) {
                try await remote.run { session in
                    let h = try await self.openHandle(for: item, write: false, session: session)
                    return try await session.client.read(h, offset: UInt64(offset), length: want)
                }
            }
            let n = buffer.withUnsafeMutableBytes { dst in
                data.withUnsafeBytes { src in
                    dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dst.count)))
                }
                return min(data.count, dst.count)
            }
            item.withState { $0.io.reads += 1; $0.io.readBytes += n; $0.io.largestRead = max($0.io.largestRead, length) }
            return try require(FSReadFileResult(bytesRead: n, itemAttributes: try await currentAttributes(of: item)))
        } catch { throw error.posix }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> FSWriteFileResult {
        do {
            guard let item = item as? SFTPItem else { throw fs_errorForPOSIXError(EINVAL) }
            let bytes = [UInt8](contents)
            // A write at an explicit offset is idempotent, so it's safe to retry
            // after a reconnect (this is what lets write-back flushes survive).
            do {
                try await withIO(item) {
                    try await remote.run { session in
                        let h = try await self.openHandle(for: item, write: true, session: session)
                        try await session.client.write(h, offset: UInt64(offset), data: bytes)
                    }
                }
            } catch {
                // With write-back caching this usually runs after the app's
                // write() returned, so remember it for the next fsync too.
                var code = (error as? SFTPError)?.errno ?? EIO
                // SFTP v3 reports a full disk as a generic failure; ask the
                // server for free space so the app gets ENOSPC, not EIO.
                if (error as? SFTPError)?.statusCode == .failure, remote.supports("statvfs@openssh.com") {
                    let path = item.path
                    if let st = try? await remote.run({ try await $0.client.statvfs(path) }),
                       st.availableBlocks * max(st.fragmentSize, 1) < UInt64(bytes.count) {
                        code = ENOSPC
                    }
                }
                log.error("write \(item.path, privacy: .public) @\(offset) +\(bytes.count) failed: \(String(describing: error), privacy: .public)")
                item.withState { if $0.deferredWriteError == nil { $0.deferredWriteError = code } }
                throw fs_errorForPOSIXError(code)
            }
            item.withState { $0.io.writes += 1; $0.io.writtenBytes += bytes.count; $0.io.largestWrite = max($0.io.largestWrite, bytes.count) }
            // Keep the cached size in step so the kernel doesn't see a stale EOF.
            let path = item.path
            if var a = table.cachedAttributes(path) ?? item.withState({ $0.lastAttributes }) {
                a.size = max(a.size ?? 0, UInt64(offset) + UInt64(contents.count))
                a.modifyTime = UInt32(clamping: Int(Date().timeIntervalSince1970))
                table.cache(a, for: path)
                item.withState { $0.lastAttributes = a }
            }
            return try require(FSWriteFileResult(bytesWritten: contents.count,
                                                 itemAttributes: try await currentAttributes(of: item),
                                                 freeSpace: nil))
        } catch { throw error.posix }
    }
}
