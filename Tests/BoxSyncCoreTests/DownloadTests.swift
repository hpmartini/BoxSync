import Foundation
import Testing
@testable import BoxSyncCore

/// A cancelled open must not throw away what was downloaded: the next request continues from there.
struct DownloadTests {
    /// One file on a fake Box; a read stops with CancellationError once `stopAfter` bytes were written.
    final class FakeBox: RemoteFileSystem, @unchecked Sendable {
        var data: Data
        var mtime = Date(timeIntervalSince1970: 1_700_000_000)
        var stopAfter: Int?
        var offsets: [UInt64] = []
        init(_ data: Data) { self.data = data }

        func stat(_ path: RelativePath) async throws -> FileMeta? { FileMeta(size: UInt64(data.count), mtime: mtime, isDirectory: false) }
        func read(_ path: RelativePath, offset: UInt64, to localURL: URL, progress: @Sendable (UInt64) -> Void) async throws {
            offsets.append(offset)
            if offset == 0 || !FileManager.default.fileExists(atPath: localURL.path) {
                FileManager.default.createFile(atPath: localURL.path, contents: nil)
            }
            let fh = try FileHandle(forWritingTo: localURL)
            defer { try? fh.close() }
            try fh.truncate(atOffset: offset)
            let end = stopAfter.map { min(data.count, Int(offset) + $0) } ?? data.count
            try fh.write(contentsOf: data[Int(offset)..<end])
            if end < data.count { throw CancellationError() }
        }
        func list(_ dir: RelativePath) async throws -> [RelativePath: FileMeta] { [:] }
        func write(_ path: RelativePath, from localURL: URL, offset: UInt64, progress: @Sendable (UInt64) -> Void) async throws {}
        func rename(_ from: RelativePath, to: RelativePath) async throws {}
        func remove(_ path: RelativePath) async throws {}
        func mkdir(_ path: RelativePath) async throws {}
        func setModificationDate(_ path: RelativePath, to date: Date) async throws {}
        func close() async {}
    }

    @Test func cancelledDownloadResumes() async throws {
        let t = try TempDir(); defer { t.cleanup() }
        let content = Data((0..<10_000).map { UInt8($0 % 251) })
        let box = FakeBox(content)
        box.stopAfter = 4_000
        await #expect(throws: CancellationError.self) { try await BoxOperations.download(box, RelativePath("a/f.bin"), key: "id/1", into: t.url) }
        await #expect(throws: CancellationError.self) { try await BoxOperations.download(box, RelativePath("a/f.bin"), key: "id/1", into: t.url) }
        box.stopAfter = nil
        let (url, meta) = try await BoxOperations.download(box, RelativePath("a/f.bin"), key: "id/1", into: t.url)
        #expect(box.offsets == [0, 4_000, 8_000])
        #expect(try Data(contentsOf: url) == content)
        #expect(meta.size == 10_000)
    }

    @Test func sameKeyWaitsOtherKeyDoesNot() async {
        final class Log: @unchecked Sendable { let l = NSLock(); var v: [String] = []; func add(_ s: String) { l.withLock { v.append(s) } } }
        let lock = KeyedLock(), log = Log()
        async let a: Void = lock.locked("x") { log.add("a1"); try? await Task.sleep(nanoseconds: 200_000_000); log.add("a2") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        async let b: Void = lock.locked("x") { log.add("b") }
        async let c: Void = lock.locked("y") { log.add("c") }
        _ = await (a, b, c)
        #expect(log.v == ["a1", "c", "a2", "b"])
    }

    @Test func changedBoxVersionStartsOver() async throws {
        let t = try TempDir(); defer { t.cleanup() }
        let box = FakeBox(Data(repeating: 1, count: 1_000))
        box.stopAfter = 400
        _ = try? await BoxOperations.download(box, RelativePath("f"), key: "id", into: t.url)
        box.data = Data(repeating: 2, count: 1_000)
        box.mtime += 60
        box.stopAfter = nil
        let (url, _) = try await BoxOperations.download(box, RelativePath("f"), key: "id", into: t.url)
        #expect(box.offsets == [0, 0])
        #expect(try Data(contentsOf: url) == box.data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: t.url.path).count == 1)   // old partial removed
    }
}
