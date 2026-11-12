import Foundation
import Testing
@testable import BoxSyncCore

private func file(_ size: UInt64, _ mtime: TimeInterval) -> FileMeta { FileMeta(size: size, mtime: Date(timeIntervalSince1970: mtime)) }
private func dir(_ mtime: TimeInterval = 1) -> FileMeta { FileMeta(size: 0, mtime: Date(timeIntervalSince1970: mtime), isDirectory: true) }

private extension ItemIndex {
    /// Literal listings for tests; KeyValuePairs keeps NFC and NFD spellings apart like the real array does.
    @discardableResult
    func reconcile(folder: String, listing: KeyValuePairs<String, FileMeta>) -> [String] {
        reconcile(folder: folder, listing: listing.map { (name: $0.key, meta: $0.value) })
    }
}

struct ItemIndexTests {
    let tmp: TempDir
    let index: ItemIndex
    init() throws {
        tmp = try TempDir()
        index = try ItemIndex(url: tmp.url.appendingPathComponent("index.sqlite"), keepChanges: 5)
    }

    private func id(_ parent: String, _ name: String) throws -> String { try #require(index.child(of: parent, named: name)).id }

    @Test func reconcileLogsAddsChangesAndRemovalsOnly() throws {
        defer { tmp.cleanup() }
        let root = ItemIndex.rootID
        let start = index.anchor()
        index.reconcile(folder: root, listing: ["a.txt": file(1, 100), "Docs": dir()])
        let a = try id(root, "a.txt"), docs = try id(root, "Docs")
        index.reconcile(folder: docs, listing: ["n.md": file(3, 100)])
        let n = try id(docs, "n.md")
        let first = try index.changes(since: start)
        #expect(Set(first.ids) == [a, docs, n])

        // Same listing again: nothing new. A folder mtime change alone is not reported.
        index.reconcile(folder: root, listing: ["a.txt": file(1, 100), "Docs": dir(99)])
        #expect(try index.changes(since: first.anchor).ids.isEmpty)

        // Content change keeps the identifier; a vanished folder takes its whole subtree with it.
        index.reconcile(folder: root, listing: ["a.txt": file(2, 200)])
        let second = try index.changes(since: first.anchor)
        #expect(Set(second.ids) == [a, docs, n])
        #expect(index.item(a)?.size == 2)
        #expect(index.item(docs) == nil && index.item(n) == nil)
    }

    @Test func typeChangeIsANewItem() throws {
        defer { tmp.cleanup() }
        index.reconcile(folder: ItemIndex.rootID, listing: ["x": file(1, 1)])
        let old = try id(ItemIndex.rootID, "x")
        index.reconcile(folder: ItemIndex.rootID, listing: ["x": dir()])
        let new = try id(ItemIndex.rootID, "x")
        #expect(old != new)
        #expect(index.item(new)?.isDirectory == true)
    }

    @Test func nfcAndNfdSpellingsAreDistinctItems() throws {
        defer { tmp.cleanup() }
        let nfc = "M\u{00FC}nchen.txt", nfd = "Mu\u{0308}nchen.txt"
        index.reconcile(folder: ItemIndex.rootID, listing: [nfc: file(1, 1), nfd: file(2, 1)])
        #expect(index.children(of: ItemIndex.rootID).count == 2)
        #expect(try id(ItemIndex.rootID, nfd) != (try id(ItemIndex.rootID, nfc)))
        #expect(index.path(of: try id(ItemIndex.rootID, nfd))?.raw.utf8.elementsEqual(nfd.utf8) == true)
    }

    @Test func renameKeepsIdentifierAndMovesChildPaths() throws {
        defer { tmp.cleanup() }
        let root = ItemIndex.rootID
        index.reconcile(folder: root, listing: ["A": dir(), "B": dir()])
        let a = try id(root, "A"), b = try id(root, "B")
        index.reconcile(folder: a, listing: ["f.txt": file(1, 1)])
        let f = try id(a, "f.txt")
        index.move(a, toParent: b, name: "A2")
        #expect(index.path(of: f)?.raw == "B/A2/f.txt")
        #expect(index.item(a)?.id == a)
    }

    @Test func trashedFolderResolvesToItsBoxTrashPath() throws {
        defer { tmp.cleanup() }
        let root = ItemIndex.rootID
        index.reconcile(folder: root, listing: ["A": dir()])
        let a = try id(root, "A")
        index.reconcile(folder: a, listing: ["f.txt": file(1, 1)])
        let f = try id(a, "f.txt")
        index.moveToTrash(a, name: "A", boxPath: RelativePath("_trash/2026-11-12/A"))
        #expect(index.path(of: f)?.raw == "_trash/2026-11-12/A/f.txt")
        #expect(index.isInTrash(f) && index.isInTrash(a))
        #expect(!index.listedFolders().contains(a))
        #expect(index.children(of: root).isEmpty)
    }

    @Test func oldAnchorExpiresOnceTheLogIsPruned() throws {
        defer { tmp.cleanup() }
        let start = index.anchor()
        for i in 0..<8 { index.reconcile(folder: ItemIndex.rootID, listing: ["f\(i)": file(1, 1)]) }
        let fresh = try index.changes(since: index.anchor() - 2)   // prunes everything beyond the last 5
        #expect(fresh.ids.count == 2)
        #expect(throws: SyncAnchorExpired.self) { try index.changes(since: start) }
        #expect(try index.changes(since: fresh.anchor).ids.isEmpty)
    }
}

struct NameRulesTests {
    @Test func conflictNameKeepsExtensionAndCountsUp() {
        let taken: Set<String> = ["Plan (Konfliktkopie 2026-11-12 1405).md"]
        #expect(NameRules.conflictName("Plan.md", stamp: "2026-11-12 1405") { taken.contains($0) } == "Plan (Konfliktkopie 2026-11-12 1405 2).md")
        #expect(NameRules.conflictName(".env", stamp: "S") { _ in false } == ".env (Konfliktkopie S)")
    }

    @Test func dedupeKeepsTheKnownSpellingElseTheBytewiseFirst() {
        let r = NameRules.dedupe(["report.md", "Report.md", "x"], known: ["report.md"])
        #expect(Set(r.kept) == ["report.md", "x"] && r.dropped == ["Report.md"])
        let fresh = NameRules.dedupe(["b.md", "B.md"], known: [])
        #expect(fresh.kept == ["B.md"] && fresh.dropped == ["b.md"])
        let nfc = "M\u{00FC}nchen", nfd = "Mu\u{0308}nchen"
        #expect(NameRules.dedupe([nfc, nfd], known: []).dropped.count == 1)
    }

    @Test func hiddenNames() {
        #expect(Exclusions.isHidden("_trash", inRoot: true) && !Exclusions.isHidden("_trash", inRoot: false))
        #expect(Exclusions.isHidden(".DS_Store", inRoot: false) && Exclusions.isHidden("._x.pdf", inRoot: false))
        #expect(Exclusions.isHidden(".boxsync-1234.part", inRoot: false) && !Exclusions.isHidden(".obsidian", inRoot: false))
    }
}
