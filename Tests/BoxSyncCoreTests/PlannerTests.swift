import Foundation
import Testing
@testable import BoxSyncCore

private func P(_ s: String) -> RelativePath { RelativePath(s) }
private func meta(_ size: UInt64 = 10, _ t: TimeInterval = 1000, hash: String? = nil) -> FileMeta {
    FileMeta(size: size, mtime: Date(timeIntervalSince1970: t), hash: hash)
}
// KeyValuePairs, not Dictionary: Swift String treats NFC and NFD as equal, a literal would trap on "duplicate keys".
private func snap(_ e: KeyValuePairs<String, FileMeta>) -> Snapshot { Snapshot(entries: Dictionary(uniqueKeysWithValues: e.map { (P($0.key), $0.value) })) }
private func base(_ rs: KeyValuePairs<String, (FileMeta, FileMeta)>) -> StateSnapshot {
    StateSnapshot(records: Dictionary(uniqueKeysWithValues: rs.map { (P($0.key), StateRecord(path: P($0.key), local: $0.value.0, remote: $0.value.1)) }))
}
private func plan(_ l: KeyValuePairs<String, FileMeta> = [:], _ r: KeyValuePairs<String, FileMeta> = [:],
                  _ b: KeyValuePairs<String, (FileMeta, FileMeta)> = [:]) -> [SyncAction] {
    SyncPlanner.plan(local: snap(l), remote: snap(r), base: base(b), now: Date(timeIntervalSince1970: 1_800_000_000)).actions
}

@Test func nfcAndNfdStayDistinct() {
    let nfc = RelativePath("\u{00E4}.txt")
    let nfd = RelativePath("a\u{0308}.txt")
    #expect(nfc != nfd)
    #expect(nfc.logical == nfd.logical)
}

@Test func emptyInputsGiveEmptyPlan() { #expect(plan().isEmpty) }

@Test func newLocalUploads() { #expect(plan(["a.txt": meta()]) == [.upload(P("a.txt"))]) }
@Test func newRemoteDownloads() { #expect(plan([:], ["a.txt": meta()]) == [.download(P("a.txt"))]) }

@Test func newFolderUnderRootIsPickedUpWithoutKnownName() {
    #expect(plan(["Irgendein Neuer Ordner/x/y.pdf": meta()]) == [.upload(P("Irgendein Neuer Ordner/x/y.pdf"))])
}

@Test func unchangedFilesDoNothing() {
    let m = meta(hash: "h")
    #expect(plan(["a": m], ["a": m], ["a": (m, m)]).isEmpty)
}

@Test func changedLocalUploads() {
    let b = meta(hash: "h1")
    #expect(plan(["a": meta(11, 2000, hash: "h2")], ["a": b], ["a": (b, b)]) == [.upload(P("a"))])
}

@Test func changedRemoteDownloads() {
    let b = meta(hash: "h1")
    #expect(plan(["a": b], ["a": meta(12, 2000)], ["a": (b, b)]) == [.download(P("a"))])
}

@Test func touchedLocalWithSameContentOnlyAdopts() {
    let b = meta(hash: "h1")
    #expect(plan(["a": meta(10, 5000, hash: "h1")], ["a": b], ["a": (b, b)]) == [.adopt(P("a"))])
}

@Test func sameMtimeWithinSecondIsNotAChange() {
    let b = meta(10, 1000.0, hash: "h")
    let r = meta(10, 1000.7)   // SFTP v3 keeps whole seconds only
    #expect(plan(["a": b], ["a": r], ["a": (b, b)]).isEmpty)
}

@Test func bothChangedMakesConflictCopyNewerWins() {
    let b = meta(hash: "h0")
    let a = plan(["Ordner/Bericht.pdf": meta(11, 3000, hash: "hL")], ["Ordner/Bericht.pdf": meta(12, 2000)], ["Ordner/Bericht.pdf": (b, b)])
    guard case .conflictCopy(let o, let c, let keepLocal) = a.first, a.count == 1 else { Issue.record("\(a)"); return }
    #expect(o == P("Ordner/Bericht.pdf"))
    #expect(c.raw.hasPrefix("Ordner/Bericht (Konfliktkopie 20"))
    #expect(c.raw.hasSuffix(").pdf"))
    #expect(keepLocal)
    let a2 = plan(["x": meta(11, 1500, hash: "hL")], ["x": meta(12, 2000)], ["x": (b, b)])
    guard case .conflictCopy(_, let c2, let keep2) = a2.first else { Issue.record("\(a2)"); return }
    #expect(!keep2)
    #expect(c2.raw.hasPrefix("x (Konfliktkopie "))   // no extension: suffix goes at the end
}

@Test func conflictNameFormat() {
    let n = SyncPlanner.conflictName(P("a/.hidden"), stamp: "2026-10-19 1405", taken: [])
    #expect(n.raw == "a/.hidden (Konfliktkopie 2026-10-19 1405)")
    let n2 = SyncPlanner.conflictName(P("Name.tar.gz"), stamp: "2026-10-19 1405", taken: [P("Name.tar (Konfliktkopie 2026-10-19 1405).gz")])
    #expect(n2.raw == "Name.tar (Konfliktkopie 2026-10-19 1405 2).gz")
}

@Test func firstRunIdenticalFilesAreAdoptedDifferentOnesConflict() {
    #expect(plan(["a": meta(5, 100)], ["a": meta(5, 100)]) == [.adopt(P("a"))])
    let a = plan(["a": meta(5, 100)], ["a": meta(6, 100)])
    guard case .conflictCopy = a.first else { Issue.record("\(a)"); return }
}

@Test func deletedLocallyTrashesRemoteNotHardDelete() {
    let b = meta(hash: "h")
    #expect(plan([:], ["a": b], ["a": (b, b)]) == [.trashRemote(P("a"))])
}

@Test func deletedRemotelyTrashesLocal() {
    let b = meta(hash: "h")
    #expect(plan(["a": b], [:], ["a": (b, b)]) == [.trashLocal(P("a"))])
}

@Test func changeBeatsDeletion() {
    let b = meta(hash: "h")
    #expect(plan([:], ["a": meta(99, 9000)], ["a": (b, b)]) == [.download(P("a"))])
    #expect(plan(["a": meta(99, 9000, hash: "new")], [:], ["a": (b, b)]) == [.upload(P("a"))])
}

@Test func goneOnBothSidesForgetsRecord() {
    let b = meta(hash: "h")
    #expect(plan([:], [:], ["a": (b, b)]) == [.forget(P("a"))])
}

@Test func localRenameBecomesRemoteRenameWithoutUpload() {
    let b = meta(5_000_000, 1000, hash: "big")
    let a = plan(["neu/Name.bin": meta(5_000_000, 1000, hash: "big")], ["alt/Name.bin": b], ["alt/Name.bin": (b, b)])
    #expect(a == [.rename(from: P("alt/Name.bin"), to: P("neu/Name.bin"))])
}

@Test func remoteLookalikeIsDownloadPlusTrashNeverRename() {
    // Same size+mtime proves nothing about content: the new Box file must be downloaded, the old local one goes to the trash.
    let b = meta(5_000_000, 1000, hash: "big")
    let a = plan(["alt": b], ["neu": meta(5_000_000, 1000)], ["alt": (b, b)])
    #expect(Set(a) == [.download(P("neu")), .trashLocal(P("alt"))])
}

@Test func massDeletionIsBlocked() {
    let b = meta(hash: "h")
    let names = (0..<30).map { "f\($0)" }
    let recs = Dictionary(uniqueKeysWithValues: names.map { (P($0), StateRecord(path: P($0), local: b, remote: b)) })
    let p = SyncPlanner.plan(local: Snapshot(), remote: Snapshot(entries: Dictionary(uniqueKeysWithValues: names.map { (P($0), b) })),
                             base: StateSnapshot(records: recs))
    #expect(p.actions.count == 30)
    let g = SyncPlanner.guardMassTrash(p, recordCount: 30)
    #expect(g.blocked == 30 && g.plan.actions.isEmpty)
    #expect(SyncPlanner.guardMassTrash(SyncPlan(actions: Array(p.actions.prefix(5))), recordCount: 30).blocked == 0)
}

@Test func stateIsPerSyncPair() {
    let a = Config(syncFolder: URL(fileURLWithPath: "/tmp/a"))
    var c = a; c.user = "other"
    #expect(a.stateID != Config(syncFolder: URL(fileURLWithPath: "/tmp/b")).stateID)
    #expect(a.stateID != c.stateID)
    #expect(a.stateID == Config(syncFolder: URL(fileURLWithPath: "/tmp/a")).stateID)
}

@Test func renameWithChangedContentIsUploadPlusTrash() {
    let b = meta(10, 1000, hash: "h1")
    let a = plan(["neu": meta(10, 1000, hash: "h2")], ["alt": b], ["alt": (b, b)])
    #expect(Set(a) == [.upload(P("neu")), .trashRemote(P("alt"))])
}

@Test func emptyFilesAreNeverTreatedAsRenames() {
    let b = meta(0, 1000, hash: "e")
    let a = plan(["neu": meta(0, 1000, hash: "e")], ["alt": b], ["alt": (b, b)])
    #expect(Set(a) == [.upload(P("neu")), .trashRemote(P("alt"))])
}

@Test func umlautVariantsOnTheBoxAreMirroredOnceAndTheOtherStaysUntouched() {
    let nfc = P("M\u{00FC}ller/Brief.txt"), nfd = P("Mu\u{0308}ller/Brief.txt")
    let lr = SyncPlanner.logicalRemote(snap([nfd.raw: meta(), nfc.raw: meta(20)]))
    #expect(lr.snapshot.entries.count == 1)
    #expect(lr.rawName[nfc] == nfc)               // NFC spelling is mirrored
    #expect(lr.shadowed == [nfd])                 // the NFD file is only reported
    let a = SyncPlanner.plan(local: Snapshot(), remote: lr.snapshot, base: StateSnapshot()).actions
    #expect(a == [.download(nfc)])                // nothing is trashed or uploaded for the NFD twin
}

@Test func nfdOnlyOnBoxIsMirroredWithItsSpellingKept() {
    let nfd = P("Mu\u{0308}nchen/Plan.txt")
    let lr = SyncPlanner.logicalRemote(snap([nfd.raw: meta()]))
    #expect(lr.rawName[nfd.normalized] == nfd)
    #expect(lr.shadowed.isEmpty)
    // a new local file in that folder goes into the existing NFD folder, not into a second NFC folder
    #expect(lr.spelling(of: P("M\u{00FC}nchen/Neu.txt")) == P("Mu\u{0308}nchen/Neu.txt"))
    #expect(lr.spelling(of: P("Frisch/Neu.txt")) == P("Frisch/Neu.txt"))
}

@Test func localNfdNameAndRemoteNfcNamePairUp() {
    // Foundation reports local names decomposed; after normalizing both sides they are one file
    let nfd = "Mu\u{0308}ller.txt", nfc = "M\u{00FC}ller.txt"
    let b = meta(hash: "h")
    let lr = SyncPlanner.logicalRemote(snap([nfc: b]))
    let local = Snapshot(entries: [P(nfd).normalized: b])
    #expect(SyncPlanner.plan(local: local, remote: lr.snapshot, base: base([nfc: (b, b)])).actions.isEmpty)
}

@Test func reservedAndExcludedNamesAreNeverSyncContent() {
    let m = meta()
    #expect(plan([:], ["_trash/2026-10-19/a": m, ".ssh/authorized_keys": m, "_backup/x": m, ".boxsync-0011-5-7.part": m, "sub/.boxsync-ab-1-2.part": m]).isEmpty)
    #expect(plan(["_trash/x": m], [:]).isEmpty)
}

@Test func exclusionPatterns() {
    let pats = [".DS_Store", ".staging/**", "*.tmp"]
    #expect(Exclusions.matches(P("a/b/.DS_Store"), patterns: pats))
    #expect(Exclusions.matches(P(".staging/x/y"), patterns: pats))
    #expect(Exclusions.matches(P("d/foo.tmp"), patterns: pats))
    #expect(!Exclusions.matches(P("d/.staging/x"), patterns: pats))
    #expect(!Exclusions.matches(P("d/foo.txt"), patterns: pats))
}

// MARK: Names that differ only in letter case (collide on a case-insensitive volume)

@Test func caseVariantOnTheBoxIsMirroredOnceAndTheOtherOnlyReported() {
    let lr = SyncPlanner.logicalRemote(snap(["report.md": meta(), "Report.md": meta(20)]))
    #expect(lr.snapshot.entries.count == 1)
    #expect(lr.rawName[P("Report.md")] == P("Report.md"))   // byte-wise first wins without a known spelling
    #expect(lr.shadowed == [P("report.md")])
    let a = SyncPlanner.plan(local: Snapshot(), remote: lr.snapshot, base: StateSnapshot()).actions
    #expect(a == [.download(P("Report.md"))])                // one download, nothing for the twin
}

@Test func spellingTheUserAlreadyHasWinsAndIsNeverTrashed() {
    // report.md is tracked and local; the Box now also holds Report.md. Byte order alone would pick Report.md,
    // drop report.md from the mirror and make the planner trash the local file as "deleted on the Box".
    let m = meta(hash: "h")
    let remote = snap(["Report.md": meta(20), "report.md": m])
    let known: Set<RelativePath> = [P("report.md")]
    let lr = SyncPlanner.logicalRemote(remote, preferring: known)
    #expect(lr.rawName[P("report.md")] == P("report.md"))
    #expect(lr.shadowed == [P("Report.md")])
    let a = SyncPlanner.plan(local: snap(["report.md": m]), remote: lr.snapshot, base: base(["report.md": (m, m)])).actions
    #expect(a.isEmpty, "\(a)")
}

@Test func folderCaseVariantIsShadowedToo() {
    let lr = SyncPlanner.logicalRemote(snap(["Docs/a.txt": meta(), "docs/b.txt": meta(), "docs/sub/c.txt": meta()]))
    #expect(Set(lr.snapshot.entries.keys.map(\.raw)) == ["Docs/a.txt"])
    #expect(Set(lr.shadowed.map(\.raw)) == ["docs/b.txt", "docs/sub/c.txt"])
}

@Test func namesWithoutACaseTwinAreUntouched() {
    let lr = SyncPlanner.logicalRemote(snap(["a.txt": meta(), "b.txt": meta(), "Docs/a.txt": meta(), "Docs/b.txt": meta()]))
    #expect(lr.snapshot.entries.count == 4 && lr.shadowed.isEmpty)
}

@Test func bothSpellingsStayMirroredWhenTheUserAlreadyHasBoth() {
    // case-sensitive local volume: a.md and A.md are two real tracked files; neither may drop out of the mirror
    let m = meta(hash: "h")
    let remote = snap(["a.md": m, "A.md": m])
    let known: Set<RelativePath> = [P("a.md"), P("A.md")]
    let lr = SyncPlanner.logicalRemote(remote, preferring: known)
    #expect(lr.shadowed.isEmpty && lr.snapshot.entries.count == 2)
    let a = SyncPlanner.plan(local: snap(["a.md": m, "A.md": m]), remote: lr.snapshot, base: base(["a.md": (m, m), "A.md": (m, m)])).actions
    #expect(a.isEmpty, "\(a)")
}

@Test func aShadowedNameIsNeverATrackedFile() {
    // whatever the Box holds, every state record stays visible in the mirror when the Box has it, so no case twin can cause a trash
    let m = meta(hash: "h")
    let remote = snap(["Report.md": meta(20), "report.md": m, "REPORT.md": meta(30)])
    let lr = SyncPlanner.logicalRemote(remote, preferring: [P("report.md")])
    #expect(lr.rawName[P("report.md")] == P("report.md"))
    #expect(Set(lr.shadowed.map(\.raw)) == ["Report.md", "REPORT.md"])
    let a = SyncPlanner.plan(local: snap(["report.md": m]), remote: lr.snapshot, base: base(["report.md": (m, m)])).actions
    #expect(a.isEmpty, "\(a)")
}
