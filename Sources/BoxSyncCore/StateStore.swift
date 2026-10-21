import Foundation

/// Per-file record of the last common state. One row per path.
public protocol StateStore: Sendable {
    func snapshot() async throws -> StateSnapshot
    func upsert(_ record: StateRecord) async throws
    func remove(_ path: RelativePath) async throws
    /// Persists pending changes (the engine calls it at the end of every run, also after an abort).
    func flush() async throws
}

/// JSON file (default: Application Support). Rewritten atomically on flush, or every 100 changes.
/// shortcut: whole-file rewrite, fine for ~10^5 records; switch to SQLite beyond that.
public actor JSONStateStore: StateStore {
    private let url: URL
    private var records: [RelativePath: StateRecord]
    private var dirty = 0

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoxSync/state.json")
    }

    public static func url(for config: Config) -> URL {
        defaultURL.deletingLastPathComponent().appendingPathComponent("state-\(config.stateID).json")
    }

    public init(url: URL = JSONStateStore.defaultURL) throws {
        self.url = url
        if let data = try? Data(contentsOf: url) {
            records = Dictionary(uniqueKeysWithValues: try JSONDecoder().decode([StateRecord].self, from: data).map { ($0.path, $0) })
        } else {
            records = [:]
        }
    }

    public func snapshot() -> StateSnapshot { StateSnapshot(records: records) }

    public func upsert(_ record: StateRecord) throws { records[record.path] = record; try touch() }
    public func remove(_ path: RelativePath) throws { records[path] = nil; try touch() }

    public func flush() throws {
        guard dirty > 0 else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(records.values)).write(to: url, options: .atomic)
        dirty = 0
    }

    private func touch() throws { dirty += 1; if dirty >= 100 { try flush() } }
}
