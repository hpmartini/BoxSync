import BoxSyncCore
import FileProvider

/// Index, Box connection and the refresh logic shared by the extension and its enumerators.
final class Drive {
    let domain: NSFileProviderDomain
    let index: ItemIndex
    let session: BoxSession
    private let lock = NSLock()
    private var lastFullRefresh = Date.distantPast
    /// Writes through the extension in progress, and a counter bumped at the start and end of each. A listing is
    /// only applied when no write overlapped it: a listing taken before a rename or during a save would otherwise
    /// delete the item macOS just changed.
    private var writesInFlight = 0
    private var writeGeneration = 0
    /// A full refresh lists every folder macOS has seen; more often than this is wasted work.
    static let minRefreshInterval: TimeInterval = 20

    init(domain: NSFileProviderDomain, index: ItemIndex, session: BoxSession) {
        self.domain = domain; self.index = index; self.session = session
    }

    var manager: NSFileProviderManager? { NSFileProviderManager(for: domain) }

    func item(_ id: String) -> BoxItem? { index.item(id).map { BoxItem($0, inTrash: index.isInTrash(id)) } }

    func signalChanges() { manager?.signalEnumerator(for: .workingSet) { _ in } }

    /// Runs a Box write and its index update; refreshes overlapping it are not applied.
    func write<T>(_ body: () async throws -> T) async rethrows -> T {
        bumpWrites(+1)
        defer { bumpWrites(-1) }
        return try await body()
    }

    private func bumpWrites(_ d: Int) {
        lock.lock(); defer { lock.unlock() }
        writesInFlight += d; writeGeneration += 1
    }

    /// nil while a write is in flight.
    private func quietGeneration() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return writesInFlight == 0 ? writeGeneration : nil
    }

    /// Lists `folder` on the Box and brings the index in line. Returns the identifiers that changed; empty when every
    /// attempt overlapped a write (the next refresh catches up).
    @discardableResult
    func refresh(folder id: String) async throws -> [String] {
        guard let path = index.path(of: id), index.item(id)?.isDirectory == true else { throw NSFileProviderError(.noSuchItem) }
        let inRoot = id == ItemIndex.rootID
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 500_000_000) }
            guard let gen = quietGeneration() else { continue }
            let listing = try await session.run(idempotent: true) { try await $0.list(path) }
            guard quietGeneration() == gen else { continue }
            let entries = listing.map { (name: $0.key.name, meta: $0.value) }.filter { !Exclusions.isHidden($0.name, inRoot: inRoot) }
            let (kept, dropped) = NameRules.dedupe(entries.map(\.name), known: index.children(of: id).map(\.name))
            let keep = Set(kept.map { Data($0.utf8) })
            for d in dropped {
                Self.reportOnce(path: path.appending(d).raw,
                                "Gleicher Name in zweiter Schreibweise (Groß-/Kleinschreibung oder Unicode) auf der Box: nicht im Laufwerk. Auf der Box umbenennen, um ihn zu sehen.")
            }
            let changed = index.reconcile(folder: id, listing: entries.filter { keep.contains(Data($0.name.utf8)) })
            index.markListed(id)
            return changed
        }
        return []
    }

    /// Compares every folder macOS has seen with the Box (parents first, so a vanished folder takes its subtree
    /// along before its children are listed). Skipped when the last full refresh is recent, unless `force`.
    func refreshAll(force: Bool = false) async throws {
        guard claimRefresh(force: force) else { return }
        let folders = index.listedFolders()
            .compactMap { id in index.path(of: id).map { (id, $0.raw.split(separator: "/").count) } }
            .sorted { $0.1 < $1.1 }
        for (id, _) in folders where index.item(id) != nil && !index.isInTrash(id) {
            do { try await refresh(folder: id) }
            catch where BoxErrors.kind(error) == .notFound || (error as NSError).code == NSFileProviderError.noSuchItem.rawValue { continue }
        }
        SharedStatus.update { $0.lastRefresh = Date(); $0.currentError = nil }
    }

    private func claimRefresh(force: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard force || Date().timeIntervalSince(lastFullRefresh) >= Self.minRefreshInterval else { return false }
        lastFullRefresh = Date()
        return true
    }

    /// Records an error for the menu bar, once per message and path among the recent ones.
    static func reportOnce(path: String?, _ message: String) {
        SharedStatus.update { s in
            guard !s.errors.contains(where: { $0.message == message && $0.path == path }) else { return }
            s.add(ProviderIssue(path: path, message: message))
        }
    }
}
