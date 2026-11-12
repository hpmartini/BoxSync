import BoxSyncCore
import FileProvider

private func anchorData(_ n: Int64) -> NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(Data(String(n).utf8)) }
private func anchorValue(_ a: NSFileProviderSyncAnchor) -> Int64? { Int64(String(decoding: a.rawValue, as: UTF8.self)) }

/// Contents of one folder: listed live from the Box, then reconciled with the index.
final class FolderEnumerator: NSObject, NSFileProviderEnumerator {
    private let drive: Drive
    private let folder: String
    private let ext: FileProviderExtension
    private var task: Task<Void, Never>?

    init(drive: Drive, folder: String, ext: FileProviderExtension) { self.drive = drive; self.folder = folder; self.ext = ext }

    func invalidate() { task?.cancel() }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        task = Task {
            do {
                let changed = try await drive.refresh(folder: folder)
                observer.didEnumerate(drive.index.children(of: folder).compactMap { drive.item($0.id) })
                observer.finishEnumerating(upTo: nil)
                if !changed.isEmpty { drive.signalChanges() }   // deletions in here reach the system as changes
            } catch {
                observer.finishEnumeratingWithError(ext.report(error, path: drive.index.path(of: folder)?.raw))
            }
        }
    }

    // Replicated extensions report changes through the working set; folders only hand out its anchor.
    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchorData(drive.index.anchor()), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchorData(drive.index.anchor()))
    }
}

/// Items moved to the trash through Finder (they already sit in `_trash` on the Box).
final class TrashEnumerator: NSObject, NSFileProviderEnumerator {
    private let drive: Drive
    init(drive: Drive) { self.drive = drive }
    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.didEnumerate(drive.index.children(of: ItemIndex.trashID).map { BoxItem($0, inTrash: true) })
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchorData(drive.index.anchor()), moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchorData(drive.index.anchor()))
    }
}

/// Changes made on the Box by others: every folder macOS has seen is listed again and the differences are
/// reported from the index's change log.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let drive: Drive
    private let ext: FileProviderExtension
    private var task: Task<Void, Never>?

    init(drive: Drive, ext: FileProviderExtension) { self.drive = drive; self.ext = ext }

    func invalidate() { task?.cancel() }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        observer.finishEnumerating(upTo: nil)   // folders are enumerated on demand; changes come below
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        task = Task {
            guard let since = anchorValue(anchor) else {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired)); return
            }
            do {
                try await drive.refreshAll()
            } catch {
                observer.finishEnumeratingWithError(ext.report(error, path: nil)); return
            }
            do {
                let (ids, next) = try drive.index.changes(since: since)
                var updated: [NSFileProviderItem] = []
                var deleted: [NSFileProviderItemIdentifier] = []
                for id in ids {
                    if let it = drive.item(id) { updated.append(it) } else { deleted.append(BoxItem.fp(id)) }
                }
                if !updated.isEmpty { observer.didUpdate(updated) }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                observer.finishEnumeratingChanges(upTo: anchorData(next), moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(anchorData(drive.index.anchor()))
    }
}
