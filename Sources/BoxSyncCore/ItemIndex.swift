import Foundation
import SQLite3

/// One file or folder of the drive as last seen on the Box (or written there by the extension).
public struct IndexedItem: Equatable, Sendable {
    public var id: String
    public var parent: String
    /// Name in the Box's own spelling (NFC/NFD kept). For an item in the trash: the name it had before.
    public var name: String
    public var isDirectory: Bool
    public var size: UInt64
    /// Whole seconds (SFTP v3).
    public var mtime: Int64
    /// Set only on the top item of something moved to the trash: its full path on the Box.
    public var trashPath: String?

    public var meta: FileMeta { FileMeta(size: size, mtime: Date(timeIntervalSince1970: TimeInterval(mtime)), isDirectory: isDirectory) }
}

public struct SyncAnchorExpired: Error {}

/// Persistent map between stable item identifiers (what macOS knows) and Box paths, plus a change log for remote
/// changes. Identifiers stay the same across renames, which a path-as-identifier scheme cannot offer.
///
/// The change log only records what was learned from the Box (`reconcile`, `recordRemote`); changes the system made
/// itself through the extension are not logged, the system already knows them.
/// Thread-safe: File Provider calls arrive concurrently, every call holds one lock around its SQLite work.
public final class ItemIndex: @unchecked Sendable {
    public static let rootID = "NSFileProviderRootContainerItemIdentifier"
    public static let trashID = "NSFileProviderTrashContainerItemIdentifier"
    /// Change log entries kept; an anchor older than that forces the system to re-enumerate.
    private let keepChanges: Int64

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL, keepChanges: Int64 = 50_000) throws {
        self.keepChanges = keepChanges
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw IndexError(message: "Index nicht zu öffnen: \(url.path)")
        }
        try exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS items(
                id TEXT PRIMARY KEY, parent TEXT NOT NULL, name TEXT NOT NULL, isDir INTEGER NOT NULL,
                size INTEGER NOT NULL, mtime INTEGER NOT NULL, listed INTEGER NOT NULL DEFAULT 0, trashPath TEXT);
            CREATE INDEX IF NOT EXISTS items_parent ON items(parent);
            CREATE TABLE IF NOT EXISTS changes(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
            INSERT OR IGNORE INTO items(id, parent, name, isDir, size, mtime) VALUES('\(Self.rootID)', '', '', 1, 0, 0);
            UPDATE items SET listed=1 WHERE id='\(Self.rootID)';
            INSERT OR IGNORE INTO meta(key, value) VALUES('prunedUpTo', 0);
            """)
    }

    deinit { sqlite3_close(db) }

    // MARK: Reads

    public func item(_ id: String) -> IndexedItem? {
        locked { rows("SELECT \(Self.cols) FROM items WHERE id=?", [.text(id)]).first }
    }

    public func children(of parent: String) -> [IndexedItem] {
        locked { rows("SELECT \(Self.cols) FROM items WHERE parent=? ORDER BY name", [.text(parent)]) }
    }

    public func child(of parent: String, named name: String) -> IndexedItem? {
        locked { childLocked(parent, name) }
    }

    /// Box path of an item; "" for the root. nil for unknown items.
    public func path(of id: String) -> RelativePath? {
        locked { pathLocked(id) }
    }

    /// True for items in the trash or below a trashed folder.
    public func isInTrash(_ id: String) -> Bool {
        locked {
            var cur = id
            while let it = itemLocked(cur) {
                if it.parent == Self.trashID { return true }
                if it.id == Self.rootID { return false }
                cur = it.parent
            }
            return false
        }
    }

    /// Folders whose contents the system has seen; these are compared with the Box on every refresh.
    public func listedFolders() -> [String] {
        locked { rows("SELECT \(Self.cols) FROM items WHERE listed=1 AND isDir=1", []).map(\.id) }
    }

    public func markListed(_ id: String) {
        locked { run("UPDATE items SET listed=1 WHERE id=?", [.text(id)]) }
    }

    // MARK: Writes made through the extension (not logged)

    /// Inserts or, when the name is already known in that folder, updates. Returns the stored item.
    @discardableResult
    public func upsert(parent: String, name: String, meta: FileMeta) -> IndexedItem {
        locked { upsertLocked(parent, name, meta) }
    }

    public func update(_ id: String, meta: FileMeta) {
        locked { run("UPDATE items SET size=?, mtime=?, isDir=? WHERE id=?", [.int(Int64(meta.size)), .int(meta.mtimeSeconds), .int(meta.isDirectory ? 1 : 0), .text(id)]) }
    }

    public func move(_ id: String, toParent parent: String, name: String) {
        locked { run("UPDATE items SET parent=?, name=?, trashPath=NULL WHERE id=?", [.text(parent), .text(name), .text(id)]) }
    }

    public func moveToTrash(_ id: String, name: String, boxPath: RelativePath) {
        locked { run("UPDATE items SET parent=?, name=?, trashPath=?, listed=0 WHERE id=?", [.text(Self.trashID), .text(name), .text(boxPath.raw), .text(id)]) }
    }

    /// Removes an item and everything below it; returns the removed identifiers.
    @discardableResult
    public func removeSubtree(_ id: String) -> [String] {
        locked { removeSubtreeLocked(id) }
    }

    // MARK: Remote changes (logged)

    /// Brings the children of `folder` in line with a fresh Box listing and logs every difference. An array, not a
    /// Dictionary: Swift String keys would merge the NFC and NFD spelling of one name.
    /// A name whose type changed (file <-> folder) is a new item. Folder mtimes are stored but not reported.
    /// Returns the identifiers that changed (updated or deleted).
    @discardableResult
    public func reconcile(folder: String, listing: [(name: String, meta: FileMeta)]) -> [String] {
        locked {
            var changed: [String] = []
            let known = rows("SELECT \(Self.cols) FROM items WHERE parent=?", [.text(folder)])
            var byName: [Data: IndexedItem] = [:]
            for k in known { byName[Data(k.name.utf8)] = k }
            var seen = Set<Data>()
            run("BEGIN")
            for (name, m) in listing {
                let key = Data(name.utf8)
                seen.insert(key)
                if let k = byName[key] {
                    if k.isDirectory != m.isDirectory {
                        changed += removeSubtreeLocked(k.id)
                        changed.append(upsertLocked(folder, name, m).id)
                    } else if k.isDirectory {
                        if k.mtime != m.mtimeSeconds { run("UPDATE items SET mtime=? WHERE id=?", [.int(m.mtimeSeconds), .text(k.id)]) }
                    } else if k.size != m.size || k.mtime != m.mtimeSeconds {
                        run("UPDATE items SET size=?, mtime=? WHERE id=?", [.int(Int64(m.size)), .int(m.mtimeSeconds), .text(k.id)])
                        changed.append(k.id)
                    }
                } else {
                    changed.append(upsertLocked(folder, name, m).id)
                }
            }
            for k in known where !seen.contains(Data(k.name.utf8)) { changed += removeSubtreeLocked(k.id) }
            for id in changed { run("INSERT INTO changes(id) VALUES(?)", [.text(id)]) }
            run("COMMIT")
            return changed
        }
    }

    /// Logs one item as changed on the Box (for example a conflict copy the extension wrote next to the original).
    public func recordRemote(_ id: String) {
        locked { run("INSERT INTO changes(id) VALUES(?)", [.text(id)]) }
    }

    public func anchor() -> Int64 {
        locked { scalar("SELECT COALESCE(MAX(seq), 0) FROM changes") }
    }

    /// Identifiers changed after `anchor` (each once) and the new anchor. Throws `SyncAnchorExpired` when the log no
    /// longer reaches back that far.
    public func changes(since anchor: Int64) throws -> (ids: [String], anchor: Int64) {
        try locked {
            if anchor < scalar("SELECT value FROM meta WHERE key='prunedUpTo'") { throw SyncAnchorExpired() }
            var ids: [String] = []
            var seen = Set<String>()
            var newAnchor = anchor
            query("SELECT seq, id FROM changes WHERE seq>? ORDER BY seq", [.int(anchor)]) { st in
                newAnchor = sqlite3_column_int64(st, 0)
                let id = String(cString: sqlite3_column_text(st, 1))
                if seen.insert(id).inserted { ids.append(id) }
            }
            let maxSeq = scalar("SELECT COALESCE(MAX(seq), 0) FROM changes")
            if maxSeq > keepChanges {
                let cut = maxSeq - keepChanges
                run("DELETE FROM changes WHERE seq<=?", [.int(cut)])
                run("UPDATE meta SET value=? WHERE key='prunedUpTo' AND value<?", [.int(cut), .int(cut)])
            }
            return (ids, newAnchor)
        }
    }

    // MARK: Internals (lock held)

    private static let cols = "id, parent, name, isDir, size, mtime, trashPath"

    private func locked<T>(_ f: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try f() }

    private func itemLocked(_ id: String) -> IndexedItem? {
        rows("SELECT \(Self.cols) FROM items WHERE id=?", [.text(id)]).first
    }

    private func childLocked(_ parent: String, _ name: String) -> IndexedItem? {
        rows("SELECT \(Self.cols) FROM items WHERE parent=?", [.text(parent)]).first { $0.name.utf8.elementsEqual(name.utf8) }
    }

    private func pathLocked(_ id: String) -> RelativePath? {
        var parts: [String] = []
        var cur = id
        while cur != Self.rootID {
            guard let it = itemLocked(cur) else { return nil }
            if let t = it.trashPath { parts.append(t); break }
            if it.parent == Self.trashID { return nil }
            parts.append(it.name)
            cur = it.parent
        }
        return RelativePath(parts.reversed().joined(separator: "/"))
    }

    private func upsertLocked(_ parent: String, _ name: String, _ m: FileMeta) -> IndexedItem {
        if var k = childLocked(parent, name) {
            run("UPDATE items SET size=?, mtime=?, isDir=? WHERE id=?", [.int(Int64(m.size)), .int(m.mtimeSeconds), .int(m.isDirectory ? 1 : 0), .text(k.id)])
            k.size = m.size; k.mtime = m.mtimeSeconds; k.isDirectory = m.isDirectory
            return k
        }
        let it = IndexedItem(id: UUID().uuidString, parent: parent, name: name, isDirectory: m.isDirectory,
                             size: m.size, mtime: m.mtimeSeconds, trashPath: nil)
        run("INSERT INTO items(id, parent, name, isDir, size, mtime) VALUES(?,?,?,?,?,?)",
            [.text(it.id), .text(parent), .text(name), .int(m.isDirectory ? 1 : 0), .int(Int64(m.size)), .int(m.mtimeSeconds)])
        return it
    }

    private func removeSubtreeLocked(_ id: String) -> [String] {
        guard id != Self.rootID else { return [] }
        var removed: [String] = []
        var stack = [id]
        while let cur = stack.popLast() {
            removed.append(cur)
            query("SELECT id FROM items WHERE parent=?", [.text(cur)]) { st in stack.append(String(cString: sqlite3_column_text(st, 0))) }
        }
        for r in removed { run("DELETE FROM items WHERE id=?", [.text(r)]) }
        return removed
    }

    private enum Value { case text(String), int(Int64) }

    private func prepare(_ sql: String, _ args: [Value]) -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            switch a {
            case .text(let s): sqlite3_bind_text(st, Int32(i + 1), s, -1, transient)
            case .int(let n): sqlite3_bind_int64(st, Int32(i + 1), n)
            }
        }
        return st
    }

    private func run(_ sql: String, _ args: [Value] = []) {
        guard let st = prepare(sql, args) else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_step(st)
    }

    private func query(_ sql: String, _ args: [Value], _ row: (OpaquePointer) -> Void) {
        guard let st = prepare(sql, args) else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }

    private func scalar(_ sql: String) -> Int64 {
        var v: Int64 = 0
        query(sql, []) { v = sqlite3_column_int64($0, 0) }
        return v
    }

    private func rows(_ sql: String, _ args: [Value]) -> [IndexedItem] {
        var out: [IndexedItem] = []
        query(sql, args) { st in
            out.append(IndexedItem(
                id: String(cString: sqlite3_column_text(st, 0)),
                parent: String(cString: sqlite3_column_text(st, 1)),
                name: String(cString: sqlite3_column_text(st, 2)),
                isDirectory: sqlite3_column_int64(st, 3) != 0,
                size: UInt64(max(0, sqlite3_column_int64(st, 4))),
                mtime: sqlite3_column_int64(st, 5),
                trashPath: sqlite3_column_type(st, 6) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(st, 6))))
        }
        return out
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw IndexError(message: "Index: \(msg)")
        }
    }
}

public struct IndexError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public var errorDescription: String? { message }
}
