import CryptoKit
import Foundation
import Security
import Testing
@testable import BoxSyncCore

// Integration tests against the Storage Box. They only ever touch `_boxsync_test/<UUID>/` (removed at the end)
// and temp folders under .testdata. Without BOXSYNC_TEST_HOST, _USER and _PASSWORD they are skipped.

private let password = TestBox.password
private let skipNote: Comment = "Box integration tests skipped: set BOXSYNC_TEST_HOST, BOXSYNC_TEST_USER and BOXSYNC_TEST_PASSWORD (they only touch _boxsync_test/ on that Box)."

private final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; defer { done = true }; return !done }
}
final class MemoryHostKeys: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var keys: [String: String] = [:]
    func pinnedKey(host: String, port: Int) -> String? { lock.lock(); defer { lock.unlock() }; return keys["\(host):\(port)"] }
    func pin(_ key: String, host: String, port: Int) -> Bool { lock.lock(); defer { lock.unlock() }; keys["\(host):\(port)"] = key; return true }
}
private final class EngineHolder: @unchecked Sendable { var engine: BoxSyncEngine? }

private func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
    return d
}
private func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

private final class BoxFixture: @unchecked Sendable {
    let id = UUID().uuidString
    let tmp: TempDir
    let localRoot: URL, localTrash: URL, remoteRoot: String
    let store: JSONStateStore

    init() throws {
        tmp = try TempDir()
        localRoot = tmp.url.appendingPathComponent("sync")
        localTrash = tmp.url.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        remoteRoot = "_boxsync_test/\(id)"
        store = try JSONStateStore(url: tmp.url.appendingPathComponent("state.json"))
    }

    let hostKeys = MemoryHostKeys()
    var config: Config { Config(syncFolder: localRoot, host: TestBox.host, user: TestBox.user, remoteRoot: remoteRoot, localTrashURL: localTrash) }

    func connect(password pw: String? = password) async throws -> SFTPRemoteFileSystem {
        try await SFTPRemoteFileSystem.connect(host: config.host, port: config.port, user: config.user, password: pw ?? "", hostKeys: hostKeys)
    }

    func engine(password pw: String? = password, onStatus: @escaping @Sendable (SyncStatus) -> Void = { _ in }) -> BoxSyncEngine {
        BoxSyncEngine.sftp(config: config, password: pw ?? "", store: store, hostKeys: hostKeys, onStatus: onStatus)
    }

    @discardableResult
    func sync() async -> SyncStatus {
        let e = engine(); await e.approveFirstSync(); return await e.status // tests start with filled pairs: approve like the user would
    }

    func writeLocal(_ rel: String, _ data: Data, mtime: TimeInterval = 1_700_000_000) throws {
        let f = localRoot.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: f)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: f.path)
    }
    func readLocal(_ rel: String) -> Data? { try? Data(contentsOf: localRoot.appendingPathComponent(rel)) }

    func putRemote(_ rel: String, _ data: Data, mtime: TimeInterval = 1_700_000_000) async throws {
        let r = try await connect(); defer { Task { await r.close() } }
        let full = RelativePath(remoteRoot + "/" + rel)
        try await r.mkdirAll(full.parent)
        let src = tmp.url.appendingPathComponent("put-\(UUID().uuidString)")
        try data.write(to: src)
        try await r.write(full, from: src, offset: 0) { _ in }
        try await r.setModificationDate(full, to: Date(timeIntervalSince1970: mtime))
    }

    func removeRemote(_ rel: String) async throws {
        let r = try await connect(); defer { Task { await r.close() } }
        try await r.remove(RelativePath(remoteRoot + "/" + rel))
    }

    func remoteData(_ rel: String) async throws -> Data? {
        let r = try await connect(); defer { Task { await r.close() } }
        let full = RelativePath(remoteRoot + "/" + rel)
        guard try await r.stat(full) != nil else { return nil }
        let dst = tmp.url.appendingPathComponent("get-\(UUID().uuidString)")
        try await r.read(full, offset: 0, to: dst) { _ in }
        return try Data(contentsOf: dst)
    }

    /// Whole remote test folder (files only, includes `_trash` and partial files). An array, not a Dictionary:
    /// Swift String keys would merge the NFC and NFD spelling of one name.
    struct Tree: Sequence {
        var items: [(key: String, value: FileMeta)] = []
        var keys: [String] { items.map(\.key) }
        var count: Int { items.count }
        subscript(path: String) -> FileMeta? { items.first { $0.key.utf8.elementsEqual(path.utf8) }?.value }
        func makeIterator() -> IndexingIterator<[(key: String, value: FileMeta)]> { items.makeIterator() }
    }
    func remoteTree() async throws -> Tree {
        let r = try await connect(); defer { Task { await r.close() } }
        return Tree(items: try await Self.walk(r, RelativePath(remoteRoot), prefix: remoteRoot.utf8.count + 1))
    }
    private static func walk(_ r: SFTPRemoteFileSystem, _ dir: RelativePath, prefix: Int) async throws -> [(key: String, value: FileMeta)] {
        var out: [(key: String, value: FileMeta)] = []
        for (p, m) in try await r.list(dir) {
            if m.isDirectory { out += try await walk(r, p, prefix: prefix) }
            else { out.append((String(decoding: p.raw.utf8.dropFirst(prefix), as: UTF8.self), m)) }
        }
        return out
    }

    func localTrashFiles() -> [String] {
        (FileManager.default.enumerator(atPath: localTrash.path)?.allObjects as? [String]) ?? []
    }

    func cleanup() async {
        precondition(remoteRoot.hasPrefix("_boxsync_test/") && remoteRoot.count > 20)
        if let r = try? await connect() {
            await Self.purge(r, RelativePath(remoteRoot))
            await r.close()
        }
        tmp.cleanup()
    }
    private static func purge(_ r: SFTPRemoteFileSystem, _ dir: RelativePath) async {
        guard let entries = try? await r.list(dir) else { return }
        for (p, m) in entries { if m.isDirectory { await purge(r, p) } else { try? await r.remove(p) } }
        try? await r.remove(dir)
    }
}

private func withBox(_ body: (BoxFixture) async throws -> Void) async throws {
    let fx = try BoxFixture()
    do { try await body(fx) } catch { await fx.cleanup(); throw error }
    await fx.cleanup()
}

@Suite(.serialized, .enabled(if: TestBox.configured, skipNote))
struct BoxIntegrationTests {
    @Test func uploadDownloadUmlautsAndHashesMatch() async throws {
        try await withBox { fx in
            let nfcName = "B\u{00FC}ro/\u{00DC}bersicht \u{00E4}\u{00F6}\u{00FC} \u{00DF}.txt"
            let nfdName = "Mu\u{0308}nchen.txt"   // only on the Box, NFD spelling
            try fx.writeLocal(nfcName, Data("lokal neu".utf8))
            try fx.writeLocal("neuer Ordner/ohne Namen im Code/x.bin", randomData(100_000))
            try await fx.putRemote("von-box/Datei.txt", Data("box neu".utf8))
            try await fx.putRemote(nfdName, Data("nfd inhalt".utf8))

            let st = await fx.sync()
            #expect(st.errors.isEmpty, "\(st.errors)")
            #expect(st.phase == .idle)

            let tree = try await fx.remoteTree()
            #expect(tree.keys.contains { $0.utf8.elementsEqual(nfcName.utf8) })      // exact spelling on the Box
            #expect(tree.keys.contains("neuer Ordner/ohne Namen im Code/x.bin"))
            #expect(fx.readLocal("von-box/Datei.txt") == Data("box neu".utf8))
            #expect(fx.readLocal(nfdName) == Data("nfd inhalt".utf8))
            #expect(tree.keys.contains { $0.utf8.elementsEqual(nfdName.utf8) })      // the Box file keeps its NFD spelling
            let local = try await DiskFileSystem().scan(root: fx.localRoot, exclusions: [], known: [:])

            // hash comparison of both sides: no difference
            for (boxPath, _) in tree {
                let meta = local.entries[RelativePath(boxPath).normalized]
                #expect(try await fx.remoteData(boxPath).map(sha) == meta?.hash, "\(boxPath)")
            }
            #expect(local.entries.count == tree.count)

            let again = await fx.sync()
            #expect(again.errors.isEmpty)
            #expect(again.progress.totalFiles == 0, "second run must be a no-op")
        }
    }

    @Test func bothChangedMakesConflictCopyNewerStays() async throws {
        try await withBox { fx in
            try fx.writeLocal("a.txt", Data("v0".utf8)); try fx.writeLocal("b.txt", Data("v0".utf8))
            #expect(await fx.sync().errors.isEmpty)
            try fx.writeLocal("a.txt", Data("local-new-a".utf8), mtime: 1_700_000_200)
            try await fx.putRemote("a.txt", Data("remote-old-a".utf8), mtime: 1_700_000_100)
            try fx.writeLocal("b.txt", Data("local-old-b".utf8), mtime: 1_700_000_100)
            try await fx.putRemote("b.txt", Data("remote-new-b".utf8), mtime: 1_700_000_200)

            let st = await fx.sync()
            #expect(st.errors.isEmpty, "\(st.errors)")
            #expect(st.conflicts.count == 2)
            let tree = try await fx.remoteTree()
            for (name, newer, older) in [("a", "local-new-a", "remote-old-a"), ("b", "remote-new-b", "local-old-b")] {
                let copy = try #require(tree.keys.first { $0.hasPrefix("\(name) (Konfliktkopie ") && $0.hasSuffix(").txt") })
                #expect(fx.readLocal("\(name).txt") == Data(newer.utf8))
                #expect(try await fx.remoteData("\(name).txt") == Data(newer.utf8))
                #expect(fx.readLocal(copy) == Data(older.utf8))
                #expect(try await fx.remoteData(copy) == Data(older.utf8))
            }
            let again = await fx.sync()
            #expect(again.errors.isEmpty && again.progress.totalFiles == 0, "\(again.errors) \(again.progress)")
        }
    }

    @Test func deletionGoesToTrashOnTheOtherSide() async throws {
        try await withBox { fx in
            try fx.writeLocal("x/doc.txt", Data("doc".utf8)); try fx.writeLocal("y.txt", Data("yyy".utf8))
            #expect(await fx.sync().errors.isEmpty)

            try FileManager.default.removeItem(at: fx.localRoot.appendingPathComponent("x/doc.txt"))
            var st = await fx.sync()
            #expect(st.errors.isEmpty, "\(st.errors)")
            var tree = try await fx.remoteTree()
            #expect(tree["x/doc.txt"] == nil)
            let trashed = try #require(tree.keys.first { $0.hasPrefix("_trash/") && $0.hasSuffix("/x/doc.txt") })
            #expect(try await fx.remoteData(trashed) == Data("doc".utf8))

            try await fx.removeRemote("y.txt")
            st = await fx.sync()
            #expect(st.errors.isEmpty, "\(st.errors)")
            #expect(fx.readLocal("y.txt") == nil)
            let localTrashed = try #require(fx.localTrashFiles().first { $0.hasSuffix("/y.txt") })
            #expect(try Data(contentsOf: fx.localTrash.appendingPathComponent(localTrashed)) == Data("yyy".utf8))
            tree = try await fx.remoteTree()
            #expect(tree["y.txt"] == nil && tree["x/doc.txt"] == nil)
            #expect(await fx.sync().progress.totalFiles == 0)
        }
    }

    @Test func renameMovesOnBoxWithoutReupload() async throws {
        try await withBox { fx in
            let data = randomData(2_000_000)
            try fx.writeLocal("gross/video.bin", data)
            #expect(await fx.sync().errors.isEmpty)

            try FileManager.default.createDirectory(at: fx.localRoot.appendingPathComponent("archiv"), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: fx.localRoot.appendingPathComponent("gross/video.bin"),
                                             to: fx.localRoot.appendingPathComponent("archiv/video2.bin"))
            let st = await fx.sync()
            #expect(st.errors.isEmpty, "\(st.errors)")
            #expect(st.progress.totalBytes == 0 && st.progress.completedBytes == 0, "no bytes may be transferred")
            let tree = try await fx.remoteTree()
            #expect(tree["gross/video.bin"] == nil)
            #expect(tree["archiv/video2.bin"]?.size == UInt64(data.count))
            #expect(!tree.keys.contains { $0.hasPrefix("_trash/") })
            #expect(try await fx.remoteData("archiv/video2.bin").map(sha) == sha(data))
        }
    }

    @Test func abortMidRunLeavesNoHalfFileAndResumesConsistently() async throws {
        try await withBox { fx in
            let data = randomData(4_000_000)
            try fx.writeLocal("big.bin", data)
            let holder = EngineHolder(), once = Once()
            let e = fx.engine { st in
                if st.progress.completedBytes >= 1_000_000, once.first() { Task { await holder.engine?.stop() } }
            }
            holder.engine = e
            await e.approveFirstSync()   // a first run on a non-empty pair needs the user's go

            var tree = try await fx.remoteTree()
            #expect(tree["big.bin"] == nil, "target must not exist before the transfer is complete")
            let partial = try #require(tree.first { $0.key.hasPrefix(".boxsync-") && $0.key.hasSuffix(".part") })
            #expect(partial.value.size > 0 && partial.value.size < UInt64(data.count))
            #expect(await fx.store.snapshotCount() == 0)

            let st = await fx.sync()   // fresh engine resumes from the partial file
            #expect(st.errors.isEmpty, "\(st.errors)")
            tree = try await fx.remoteTree()
            #expect(tree["big.bin"]?.size == UInt64(data.count))
            #expect(!tree.keys.contains { $0.hasSuffix(".part") })
            #expect(try await fx.remoteData("big.bin").map(sha) == sha(data))
        }
    }

    @Test func bothUnicodeSpellingsOnTheBoxSurviveAndAreReported() async throws {
        try await withBox { fx in
            let nfc = "K\u{00E4}se.txt", nfd = "Ka\u{0308}se.txt"
            try await fx.putRemote(nfc, Data("nfc".utf8))
            try await fx.putRemote(nfd, Data("nfd".utf8))
            let st = await fx.sync()
            #expect(fx.readLocal(nfc) == Data("nfc".utf8))      // NFC spelling is mirrored
            #expect(st.errors.count == 1 && st.errors[0].message.contains("NFC/NFD"), "\(st.errors)")
            let tree = try await fx.remoteTree()
            #expect(tree.count == 2, "both files must stay on the Box: \(tree.keys)")
            #expect(try await fx.remoteData(nfd) == Data("nfd".utf8))
            #expect(try await fx.remoteData(nfc) == Data("nfc".utf8))
            #expect(!tree.keys.contains { $0.hasPrefix("_trash/") })
            #expect(await fx.sync().progress.totalFiles == 0)
        }
    }

    @Test func filledPairWaitsForFirstSyncApprovalAndCheckChangesNothing() async throws {
        try await withBox { fx in
            try fx.writeLocal("lokal.txt", Data("l".utf8))
            try await fx.putRemote("box.txt", Data("b".utf8))
            let e = fx.engine()
            await e.syncNow()
            var st = await e.status
            #expect(st.awaitingFirstSync)
            #expect(st.pending?.uploads == 1 && st.pending?.downloads == 1, "\(String(describing: st.pending))")
            #expect(st.lastSync == nil && st.lastRun == nil)
            #expect(fx.readLocal("box.txt") == nil) // nothing was downloaded yet
            await e.checkNow()
            st = await e.status
            #expect(st.pending?.total == 2 && fx.readLocal("box.txt") == nil)
            await e.approveFirstSync()
            st = await e.status
            #expect(st.errors.isEmpty, "\(st.errors)")
            #expect(!st.awaitingFirstSync && fx.readLocal("box.txt") == Data("b".utf8))
            #expect(st.lastRun?.uploads == 1 && st.lastRun?.downloads == 1 && st.pending?.total == 0 && st.trackedFiles == 2)
        }
    }

    @Test func localOnlyPairWaitsForApprovalBeforeAnyUpload() async throws {
        try await withBox { fx in
            try fx.writeLocal("neu.txt", Data("n".utf8))
            let e = fx.engine()
            await e.syncNow()
            var st = await e.status
            #expect(st.awaitingFirstSync && st.pending?.uploads == 1)
            #expect(try await fx.remoteTree()["neu.txt"] == nil, "nothing may reach the Box before the user approves")
            await e.approveFirstSync()
            st = await e.status
            let uploaded = try await fx.remoteData("neu.txt")
            #expect(!st.awaitingFirstSync && st.errors.isEmpty && uploaded == Data("n".utf8))
        }
    }

    @Test func wrongPasswordIsAVisibleError() async throws {
        try await withBox { fx in
            try fx.writeLocal("a.txt", Data("a".utf8))
            let e = fx.engine(password: "definitiv-falsch")
            await e.syncNow()
            let st = await e.status
            #expect(st.phase == .error)
            let issue = try #require(st.errors.first)
            #expect(issue.message.contains("Verbindung fehlgeschlagen"), "\(issue.message)")
            #expect(st.lastSync == nil)
        }
    }
}

extension JSONStateStore {
    func snapshotCount() async -> Int { (try? await snapshot().records.count) ?? -1 }
}

@Suite(.serialized, .enabled(if: TestBox.configured, skipNote))
struct BoxE2ETests {
    /// Probe run: /private/tmp/boxsync-e2e <-> _boxsync_test/e2e, two rounds with changes on both sides, then SHA-256 of both trees.
    @Test func e2eProbeHashesMatch() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/boxsync-e2e")
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root.appendingPathComponent("sync"), withIntermediateDirectories: true)
        let local = root.appendingPathComponent("sync")
        let cfg = Config(syncFolder: local, host: TestBox.host, user: TestBox.user, remoteRoot: "_boxsync_test/e2e", localTrashURL: root.appendingPathComponent("trash"))
        let store = try JSONStateStore(url: root.appendingPathComponent("state.json"))
        func put(_ rel: String, _ d: Data) throws {
            let f = local.appendingPathComponent(rel)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: f)
        }
        func run() async -> SyncStatus {
            let e = BoxSyncEngine.sftp(config: cfg, password: password ?? "", store: store, hostKeys: MemoryHostKeys()); await e.approveFirstSync(); return await e.status
        }
        let r0 = try await SFTPRemoteFileSystem.connect(host: cfg.host, port: cfg.port, user: cfg.user, password: password ?? "", hostKeys: MemoryHostKeys())
        func purge(_ dir: RelativePath) async {
            guard let es = try? await r0.list(dir) else { return }
            for (p, m) in es { if m.isDirectory { await purge(p) } else { try? await r0.remove(p) } }
            try? await r0.remove(dir)
        }
        await purge(RelativePath("_boxsync_test/e2e"))

        try put("a/klein.txt", Data("eins".utf8))
        try put("B\u{00FC}ro/\u{00DC}ber.txt", Data("umlaut".utf8))
        try put("gross.bin", randomData(3_000_000))
        var st = await run()
        #expect(st.errors.isEmpty, "\(st.errors)")
        try put("a/klein.txt", Data("zwei, geaendert".utf8))
        try put("neu/ordner/x.bin", randomData(200_000))
        st = await run()
        #expect(st.errors.isEmpty, "\(st.errors)")

        let local2 = try await DiskFileSystem().scan(root: local, exclusions: [], known: [:])
        let r = try await SFTPRemoteFileSystem.connect(host: cfg.host, port: cfg.port, user: cfg.user, password: password ?? "", hostKeys: MemoryHostKeys())
        func walk(_ d: RelativePath) async throws -> [RelativePath] {
            var out: [RelativePath] = []
            for (p, m) in try await r.list(d) { if m.isDirectory { out += try await walk(p) } else { out.append(p) } }
            return out
        }
        let files = try await walk(RelativePath("_boxsync_test/e2e")).filter { !$0.raw.hasPrefix("_boxsync_test/e2e/_trash/") } // trash holds the replaced old version
        var diffs = 0
        let prefix = "_boxsync_test/e2e/".utf8.count
        for p in files {
            let rel = RelativePath(String(decoding: p.raw.utf8.dropFirst(prefix), as: UTF8.self)).normalized
            let dst = root.appendingPathComponent("get-\(UUID().uuidString)")
            try await r.read(p, offset: 0, to: dst) { _ in }
            if sha(try Data(contentsOf: dst)) != local2.entries[rel]?.hash { diffs += 1 }
        }
        if files.count != local2.entries.count { diffs += abs(files.count - local2.entries.count) }
        print("E2E_FILES=\(files.count) E2E_HASH_DIFFS=\(diffs)")
        #expect(diffs == 0 && files.count == 4)

        await purge(RelativePath("_boxsync_test/e2e"))
        await r.close(); await r0.close()
        try? fm.removeItem(at: root)
    }
}
