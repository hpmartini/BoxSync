import BoxSyncCore
import FileProvider
import UniformTypeIdentifiers

/// The BoxSync drive: placeholders for everything on the Box, contents downloaded when a file is opened,
/// local changes written straight to the Box. Nothing is deleted for good: deleted and replaced items go to
/// `_trash/<day>/` on the Box.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let drive: Drive?
    private let setupError: Error?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        var drive: Drive?, setupError: Error?
        do {
            guard let c = SharedSettings.load(), c.isComplete, let url = AppGroup.indexURL(identity: c.identity) else {
                throw NotConfigured("BoxSync ist noch nicht eingerichtet (Einstellungen).")
            }
            drive = Drive(domain: domain, index: try ItemIndex(url: url), session: BoxSession.shared())
        } catch { setupError = error }
        self.drive = drive
        self.setupError = setupError
        super.init()
    }

    func invalidate() {
        guard let s = drive?.session else { return }
        Task { await s.close() }
    }

    // MARK: Errors

    /// Maps an error for the system and records the ones the user should see in the menu bar.
    func report(_ error: Error, path: String?) -> Error {
        let ns = error as NSError
        if ns.domain == NSFileProviderErrorDomain { return error }
        if error is CancellationError { return CocoaError(.userCancelled) }
        let kind = BoxErrors.kind(error)
        if kind != .notFound { Drive.reportOnce(path: path, BoxErrors.message(error)) }
        switch kind {
        case .notFound: return NSFileProviderError(.noSuchItem)
        case .notAuthenticated: return NSFileProviderError(.notAuthenticated)
        case .unreachable: return NSFileProviderError(.serverUnreachable)
        case .failed: return NSFileProviderError(.cannotSynchronize)
        }
    }

    /// Runs `body` with the drive; errors go through `report` to `fail`. Cancelling the progress cancels the work.
    /// `writes`: the body changes the Box, refreshes overlapping it are not applied (see `Drive.write`).
    private func perform(_ progress: Progress, writes: Bool = false, path: @escaping () -> String?,
                         _ body: @escaping (Drive) async throws -> Void, fail: @escaping (Error) -> Void) -> Progress {
        let task = Task {
            do {
                guard let d = drive else { throw setupError ?? NotConfigured("BoxSync ist noch nicht eingerichtet.") }
                if writes { try await d.write { try await body(d) } } else { try await body(d) }
            } catch {
                fail(report(error, path: path()))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    private static func ratio(_ done: UInt64, _ total: UInt64, into p: Progress) {
        p.completedUnitCount = total == 0 ? 100 : Int64(min(100, Double(done) / Double(total) * 100))
    }

    private static func parentID(_ fp: NSFileProviderItemIdentifier) -> String { BoxItem.id(fp) }

    // MARK: Lookup

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        if let it = drive?.item(BoxItem.id(identifier)) { completionHandler(it, nil) }
        else { completionHandler(nil, NSFileProviderError(.noSuchItem)) }
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard let d = drive else { throw report(setupError ?? NotConfigured("BoxSync ist noch nicht eingerichtet."), path: nil) }
        switch containerItemIdentifier {
        case .workingSet: return WorkingSetEnumerator(drive: d, ext: self)
        case .trashContainer: return TrashEnumerator(drive: d)
        default:
            let id = BoxItem.id(containerItemIdentifier)
            guard d.index.item(id)?.isDirectory == true else { throw NSFileProviderError(.noSuchItem) }
            return FolderEnumerator(drive: d, folder: id, ext: self)
        }
    }

    // MARK: Download

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let id = BoxItem.id(itemIdentifier)
        let progress = Progress(totalUnitCount: 100)
        return perform(progress, path: { [weak self] in self?.drive?.index.path(of: id)?.raw }, { [domain] d in
            guard let row = d.index.item(id), !row.isDirectory, let path = d.index.path(of: id) else { throw NSFileProviderError(.noSuchItem) }
            guard let manager = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
            let tmp = try manager.temporaryDirectoryURL()
            // Resumes what a cancelled request for this item left. A cancelled request still running ends after its
            // current block; the next one waits for it instead of writing the same partial file.
            let (dst, meta) = try await d.downloads.locked(id) {
                try await d.session.run(idempotent: true) { r in
                    try await BoxOperations.download(r, path, key: id, into: tmp) { Self.ratio($0, $1, into: progress) }
                }
            }
            if meta.size != row.size || meta.mtimeSeconds != row.mtime { d.index.update(id, meta: meta) }
            completionHandler(dst, d.item(id), nil)
        }, fail: { completionHandler(nil, nil, $0) })
    }

    // MARK: Create

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let parent = Self.parentID(itemTemplate.parentItemIdentifier)
        let name = itemTemplate.filename
        let type = itemTemplate.contentType ?? .data
        let mtime = itemTemplate.contentModificationDate ?? nil
        let progress = Progress(totalUnitCount: 100)
        return perform(progress, writes: true, path: { [weak self] in self?.drive?.index.path(of: parent)?.appending(name).raw }, { d in
            if Exclusions.isHidden(name, inRoot: parent == ItemIndex.rootID) || type.conforms(to: .symbolicLink) {
                throw NSFileProviderError(.excludedFromSync)
            }
            guard !d.index.isInTrash(parent), let parentPath = d.index.path(of: parent) else { throw NSFileProviderError(.noSuchItem) }
            let now = Date()

            if type.conforms(to: .folder) || type.conforms(to: .directory) {
                let (finalName, meta) = try await d.session.run { r -> (String, FileMeta) in
                    var n = name
                    if let m = try await r.stat(parentPath.appending(n)) {
                        if m.isDirectory { return (n, m) }   // a Box folder of that name: the new folder merges into it
                        let siblings = Set(try await r.list(parentPath).keys.map(\.name))
                        n = NameRules.freeName(n) { siblings.contains($0) }
                    }
                    let path = parentPath.appending(n)
                    try await r.mkdir(path)
                    return (n, try await r.stat(path) ?? FileMeta(size: 0, mtime: now, isDirectory: true))
                }
                completionHandler(BoxItem(d.index.upsert(parent: parent, name: finalName, meta: meta)), [], false, nil)
                return
            }

            let src = try url ?? Self.emptyFile(domain: self.domain)
            let size = (try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.uint64Value ?? 0
            let (finalName, meta, conflict) = try await d.session.run { r -> (String, FileMeta, Bool) in
                var n = name
                if let existing = try await r.stat(parentPath.appending(n)) {
                    if options.contains(.mayAlreadyExist), !existing.isDirectory, existing.size == size,
                       let mtime, existing.mtimeSeconds == Int64(mtime.timeIntervalSince1970.rounded(.down)) {
                        return (n, existing, false)   // the same file is already on the Box
                    }
                    let siblings = Set(try await r.list(parentPath).keys.map(\.name))
                    n = NameRules.conflictName(n, stamp: BoxOperations.minuteStamp(now)) { siblings.contains($0) }
                }
                let m = try await BoxOperations.upload(r, from: src, to: parentPath.appending(n), mtime: mtime ?? now, replacing: false,
                                                       now: now) { Self.ratio($0, size, into: progress) }
                return (n, m, n != name)
            }
            if conflict {
                SharedStatus.update { $0.add(ProviderConflict(original: parentPath.appending(name).raw, copy: parentPath.appending(finalName).raw)) }
            }
            completionHandler(BoxItem(d.index.upsert(parent: parent, name: finalName, meta: meta)), [], false, nil)
        }, fail: { completionHandler(nil, [], false, $0) })
    }

    private static func emptyFile(domain: NSFileProviderDomain) throws -> URL {
        guard let m = NSFileProviderManager(for: domain) else { throw NSFileProviderError(.providerNotFound) }
        let u = try m.temporaryDirectoryURL().appendingPathComponent(UUID().uuidString)
        try Data().write(to: u)
        return u
    }

    // MARK: Modify

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let id = BoxItem.id(item.itemIdentifier)
        let newParent = Self.parentID(item.parentItemIdentifier)
        let newName = item.filename
        let localDate = item.contentModificationDate ?? nil
        let progress = Progress(totalUnitCount: 100)
        return perform(progress, writes: true, path: { [weak self] in self?.drive?.index.path(of: id)?.raw }, { d in
            guard var row = d.index.item(id), let oldPath = d.index.path(of: id) else { throw NSFileProviderError(.noSuchItem) }
            let now = Date()
            var refetch = false

            // 1. Location: rename, move, trash or put back.
            if !changedFields.intersection([.filename, .parentItemIdentifier]).isEmpty {
                if newParent == ItemIndex.trashID {
                    if !d.index.isInTrash(id) {
                        let dest = try await d.session.run { try await BoxOperations.trash($0, oldPath, now: now) }
                        d.index.moveToTrash(id, name: newName, boxPath: dest)
                    }
                } else {
                    guard !d.index.isInTrash(newParent), let parentPath = d.index.path(of: newParent) else { throw NSFileProviderError(.noSuchItem) }
                    if Exclusions.isHidden(newName, inRoot: newParent == ItemIndex.rootID) { throw NSFileProviderError(.excludedFromSync) }
                    let dest = parentPath.appending(newName)
                    if dest != oldPath {
                        try await d.session.run { r in
                            if try await r.stat(dest) != nil { throw NSFileProviderError(.filenameCollision) }
                            try await r.mkdirAll(dest.parent)
                            try await r.rename(oldPath, to: dest)
                        }
                    }
                    d.index.move(id, toParent: newParent, name: newName)
                }
                guard let moved = d.index.item(id) else { throw NSFileProviderError(.noSuchItem) }
                row = moved
            }
            guard let path = d.index.path(of: id) else { throw NSFileProviderError(.noSuchItem) }

            // 2. Contents.
            if changedFields.contains(.contents), let src = newContents, !row.isDirectory {
                let size = (try FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.uint64Value ?? 0
                // The version macOS based this edit on; the index may already hold a newer Box state.
                let base = BoxItem.contentStamp(version) ?? (row.size, row.mtime)
                let (meta, copy, fetch) = try await d.session.run { r -> (FileMeta, RelativePath?, Bool) in
                    guard let remote = try await r.stat(path) else {
                        return (try await BoxOperations.upload(r, from: src, to: path, mtime: localDate ?? now, replacing: false, now: now) {
                            Self.ratio($0, size, into: progress) }, nil, false)
                    }
                    if remote.size == base.size && remote.mtimeSeconds == base.mtime {
                        return (try await BoxOperations.upload(r, from: src, to: path, mtime: localDate ?? now, replacing: true, now: now) {
                            Self.ratio($0, size, into: progress) }, nil, false)
                    }
                    // Changed on the Box since macOS last saw it: the newer version keeps the name, the other one
                    // becomes "Name (Konfliktkopie …)" next to it.
                    let copy = try await BoxOperations.conflictCopyPath(r, for: path, now: now)
                    if (localDate ?? now) >= remote.mtime {
                        try await r.rename(path, to: copy)
                        return (try await BoxOperations.upload(r, from: src, to: path, mtime: localDate ?? now, replacing: false, now: now) {
                            Self.ratio($0, size, into: progress) }, copy, false)
                    }
                    try await BoxOperations.upload(r, from: src, to: copy, mtime: localDate ?? now, replacing: false, now: now) {
                        Self.ratio($0, size, into: progress) }
                    return (remote, copy, true)
                }
                d.index.update(id, meta: meta)
                refetch = fetch
                if let copy {
                    if let copyMeta = try await d.session.run({ try await $0.stat(copy) }) {
                        d.index.recordRemote(d.index.upsert(parent: row.parent, name: copy.name, meta: copyMeta).id)
                        d.signalChanges()
                    }
                    SharedStatus.update { $0.add(ProviderConflict(original: path.raw, copy: copy.raw)) }
                }
            } else if changedFields.contains(.contentModificationDate), let localDate, !row.isDirectory {
                // 3. Only the date changed (touch).
                let meta = try await d.session.run { r -> FileMeta? in
                    try await r.setModificationDate(path, to: localDate)
                    return try await r.stat(path)
                }
                if let meta { d.index.update(id, meta: meta) }
            }
            guard let out = d.item(id) else { throw NSFileProviderError(.noSuchItem) }
            completionHandler(out, [], refetch, nil)
        }, fail: { completionHandler(nil, [], false, $0) })
    }

    // MARK: Delete

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let id = BoxItem.id(identifier)
        return perform(Progress(totalUnitCount: 1), writes: true, path: { [weak self] in self?.drive?.index.path(of: id)?.raw }, { d in
            guard let row = d.index.item(id) else { completionHandler(nil); return }
            // Emptying the Mac trash: the item stays in `_trash` on the Box, it only leaves the drive.
            if d.index.isInTrash(id) { d.index.removeSubtree(id); completionHandler(nil); return }
            guard let path = d.index.path(of: id) else { throw NSFileProviderError(.noSuchItem) }
            let base = BoxItem.contentStamp(version) ?? (row.size, row.mtime)
            try await d.session.run { r in
                guard let remote = try await r.stat(path) else { return }
                if !row.isDirectory && (remote.size != base.size || remote.mtimeSeconds != base.mtime) {
                    throw NSFileProviderError(.deletionRejected)   // changed on the Box since: the change wins
                }
                if row.isDirectory && !options.contains(.recursive) {
                    // Entries the drive never shows (.DS_Store …) do not count; they go to the trash with the folder.
                    let visible = try await r.list(path).keys.contains { !Exclusions.isHidden($0.name, inRoot: false) }
                    if visible { throw NSFileProviderError(.directoryNotEmpty) }
                }
                try await BoxOperations.trash(r, path)
            }
            d.index.removeSubtree(id)
            completionHandler(nil)
        }, fail: { completionHandler($0) })
    }
}
