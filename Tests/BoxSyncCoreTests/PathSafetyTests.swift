import Foundation
import Testing
@testable import BoxSyncCore

// Paths that come from the Box are untrusted: they must never resolve outside the sync folder.
struct PathSafetyTests {
    @Test func rejectsTraversalAbsoluteAndEmptyComponents() throws {
        let t = try TempDir(); defer { t.cleanup() }
        for bad in ["../x", "a/../../x", "/etc/passwd", "a//b", "./a", "a/.", ""] {
            #expect(throws: UnsafePath.self) { _ = try DiskFileSystem.safeURL(t.url, RelativePath(bad)) }
        }
        _ = try DiskFileSystem.safeURL(t.url, RelativePath("a/B\u{00FC}ro/x.txt")) // normal paths pass
    }

    @Test func rejectsSymlinkedParentPointingOutside() throws {
        let t = try TempDir(); defer { t.cleanup() }
        let outside = t.url.appendingPathComponent("outside"), sync = t.url.appendingPathComponent("sync")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sync.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: UnsafePath.self) { _ = try DiskFileSystem.safeURL(sync, RelativePath("link/evil.txt")) }
        try FileManager.default.createDirectory(at: sync.appendingPathComponent("real"), withIntermediateDirectories: true)
        _ = try DiskFileSystem.safeURL(sync, RelativePath("real/ok.txt"))
    }

    @Test func installRefusesSymlinkEscape() async throws {
        let t = try TempDir(); defer { t.cleanup() }
        let outside = t.url.appendingPathComponent("outside"), sync = t.url.appendingPathComponent("sync")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sync, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sync.appendingPathComponent("link"), withDestinationURL: outside)
        let part = t.url.appendingPathComponent("p.part"); try Data("x".utf8).write(to: part)
        await #expect(throws: UnsafePath.self) {
            try await DiskFileSystem().install(partial: part, as: RelativePath("link/evil.txt"), root: sync, trashRoot: t.url.appendingPathComponent("trash"))
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("evil.txt").path))
    }
}

// Regression: an excluded plain file (.DS_Store) must not hide its sibling files from the scan.
struct ScanExclusionTests {
    @Test func excludedFileDoesNotHideSiblings() async throws {
        let t = try TempDir(); defer { t.cleanup() }
        try t.write(".DS_Store", "x")
        try t.write("a.txt", "a")
        try t.write("d/.DS_Store", "x")
        try t.write("d/b.txt", "b")
        try t.write("d/e/c.txt", "c")
        try t.write(".staging/skip.txt", "s")
        let snap = try await DiskFileSystem().scan(root: t.url, exclusions: [".DS_Store", ".staging/**"], known: [:])
        #expect(Set(snap.entries.keys.map(\.raw)) == ["a.txt", "d/b.txt", "d/e/c.txt"])
    }

    /// The vault pair's patterns: git data, volatile Obsidian layout and tool output stay out; notes and plugin settings stay in.
    @Test func vaultExclusions() async throws {
        let t = try TempDir(); defer { t.cleanup() }
        for f in ["note.md", "sub/n2.md", ".obsidian/app.json", ".obsidian/plugins/x/data.json",
                  ".git/HEAD", ".git/objects/ab/cd", ".obsidian/workspace.json", ".obsidian/workspaces.json",
                  "graphify-out/g.json", "sub/graphify-out/h.json"] {
            try t.write(f, "x")
        }
        let snap = try await DiskFileSystem().scan(root: t.url, exclusions: [".DS_Store", ".git", ".obsidian/workspace*", "graphify-out"], known: [:])
        #expect(Set(snap.entries.keys.map(\.raw)) == ["note.md", "sub/n2.md", ".obsidian/app.json", ".obsidian/plugins/x/data.json"])
    }
}
