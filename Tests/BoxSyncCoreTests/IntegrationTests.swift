import Foundation
import Testing
@testable import BoxSyncCore

// Integration tests against the Storage Box. They only ever touch `_boxsync_test/<UUID>/` and `_trash/<day>/_boxsync_test/`
// (removed at the end). Without BOXSYNC_TEST_HOST, _USER and _PASSWORD they are skipped.

private let skipNote: Comment = "Box integration tests skipped: set BOXSYNC_TEST_HOST, BOXSYNC_TEST_USER and BOXSYNC_TEST_PASSWORD (they only touch _boxsync_test/ on that Box)."

private final class BoxFixture: @unchecked Sendable {
    let root = RelativePath("_boxsync_test/\(UUID().uuidString)")
    let tmp: TempDir
    let r: SFTPRemoteFileSystem
    let now = Date()

    init() async throws {
        tmp = try TempDir()
        r = try await SFTPRemoteFileSystem.connect(host: TestBox.host, port: 23, user: TestBox.user,
                                                   password: TestBox.password ?? "", hostKeys: MemoryHostKeys())
        try await r.mkdirAll(root)
    }

    func local(_ s: String) throws -> URL { try tmp.file(UUID().uuidString, Data(s.utf8)) }

    func read(_ p: RelativePath) async throws -> String {
        let dst = tmp.url.appendingPathComponent(UUID().uuidString)
        try await r.read(p, offset: 0, to: dst) { _ in }
        return String(decoding: try Data(contentsOf: dst), as: UTF8.self)
    }

    var trashedRoot: RelativePath { BoxOperations.trashRoot.appending(BoxOperations.dayStamp(now)).appending(root.raw) }

    func cleanup() async {
        precondition(root.raw.hasPrefix("_boxsync_test/") && root.raw.count > 20)
        for p in [root, trashedRoot] { await purge(p) }
        await r.close()
        tmp.cleanup()
    }
    private func purge(_ dir: RelativePath) async {
        guard let entries = try? await r.list(dir) else { return }
        for (p, m) in entries { if m.isDirectory { await purge(p) } else { try? await r.remove(p) } }
        try? await r.remove(dir)
    }
}

private func withBox(_ body: (BoxFixture) async throws -> Void) async throws {
    let fx = try await BoxFixture()
    do { try await body(fx) } catch { await fx.cleanup(); throw error }
    await fx.cleanup()
}

@Suite(.serialized, .enabled(if: TestBox.configured, skipNote))
struct BoxIntegrationTests {
    @Test func replacingUploadKeepsOldVersionInTrashAndLeavesNoTempFile() async throws {
        try await withBox { fx in
            let p = fx.root.appending("Notiz \u{00E4}.md")
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            let m1 = try await BoxOperations.upload(fx.r, from: try fx.local("eins"), to: p, mtime: mtime, replacing: false, now: fx.now)
            #expect(m1.size == 4 && m1.mtimeSeconds == 1_700_000_000)
            await #expect(throws: (any Error).self) {
                try await BoxOperations.upload(fx.r, from: try fx.local("x"), to: p, mtime: nil, replacing: false, now: fx.now)
            }
            try await BoxOperations.upload(fx.r, from: try fx.local("zwei"), to: p, mtime: nil, replacing: true, now: fx.now)
            #expect(try await fx.read(p) == "zwei")
            #expect(try await fx.read(fx.trashedRoot.appending(p.name)) == "eins")
            #expect(try await fx.r.list(fx.root).keys.map(\.name) == [p.name])   // no .part left behind
        }
    }

    @Test func trashAddsNumberWhenTheDayFolderHasTheNameAlready() async throws {
        try await withBox { fx in
            let p = fx.root.appending("a.txt")
            for s in ["1", "2"] {
                try await BoxOperations.upload(fx.r, from: try fx.local(s), to: p, mtime: nil, replacing: false, now: fx.now)
                try await BoxOperations.trash(fx.r, p, now: fx.now)
            }
            #expect(try await fx.read(fx.trashedRoot.appending("a.txt")) == "1")
            #expect(try await fx.read(fx.trashedRoot.appending("a 2.txt")) == "2")
            #expect(try await fx.r.stat(p) == nil)
        }
    }

    /// Regression: Citadel leaks one directory handle per listing; the Box failed after about a thousand.
    @Test func manyListingsOnOneConnectionKeepWorking() async throws {
        try await withBox { fx in
            for _ in 0..<1_100 { _ = try await fx.r.list(fx.root) }
        }
    }
}
