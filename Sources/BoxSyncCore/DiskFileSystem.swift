import CryptoKit
import Foundation

public struct DiskFileSystem: LocalFileSystem {
    public init() {}

    public func scan(root: URL, exclusions: [String], known: [RelativePath: FileMeta]) async throws -> Snapshot {
        try Self.scanSync(root: root, exclusions: exclusions, known: known)
    }

    // NSEnumerator iteration is unavailable from async contexts, hence the sync helper.
    private static func scanSync(root: URL, exclusions: [String], known: [RelativePath: FileMeta]) throws -> Snapshot {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root.path) else { throw CocoaError(.fileReadNoSuchFile) }
        var entries: [RelativePath: FileMeta] = [:]
        while let rel = en.nextObject() as? String {
            try Task.checkCancellation()
            // Foundation reports names decomposed (NFD); the NFC name is the identity, APFS opens either.
            let path = RelativePath(rel).normalized
            if Exclusions.isReserved(path) || Exclusions.matches(path, patterns: exclusions) {
                // Only for directories: on a plain file skipDescendants also drops the rest of its folder.
                if (en.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory { en.skipDescendants() }
                continue
            }
            let attrs = try fm.attributesOfItem(atPath: root.appendingPathComponent(rel).path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else { continue }   // dirs, symlinks: not synced
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = attrs[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
            var meta = FileMeta(size: size, mtime: mtime)
            if let k = known[path], k.size == size, k.mtimeSeconds == meta.mtimeSeconds, let h = k.hash {
                meta.hash = h
            } else {
                meta.hash = try sha256(of: root.appendingPathComponent(rel))
            }
            entries[path] = meta
        }
        return Snapshot(entries: entries)
    }

    static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func hash(_ path: RelativePath, root: URL) async throws -> String {
        try Self.sha256(of: Self.safeURL(root, path))
    }

    public func meta(_ path: RelativePath, root: URL, hash: String?) throws -> FileMeta? {
        let url = try Self.safeURL(root, path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        var m = FileMeta(size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                         mtime: attrs[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0))
        m.hash = try hash ?? Self.sha256(of: url)
        return m
    }

    public func move(_ from: RelativePath, to: RelativePath, root: URL) async throws {
        let src = try Self.safeURL(root, from), dst = try Self.safeURL(root, to)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: dst)
    }

    public func trash(_ path: RelativePath, root: URL, trashRoot: URL) async throws {
        try Self.moveToTrash(Self.safeURL(root, path), trashRoot: trashRoot, path: path)
    }

    public func install(partial: URL, as path: RelativePath, root: URL, trashRoot: URL) async throws {
        let dst = try Self.safeURL(root, path)
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try Self.moveToTrash(dst, trashRoot: trashRoot, path: path) }
        try fm.moveItem(at: partial, to: dst)
    }

    public func setModificationDate(_ path: RelativePath, root: URL, to date: Date) async throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: Self.safeURL(root, path).path)
    }

    /// Never overwrites an earlier trash entry: appends " 2", " 3" ... to the name.
    private static func moveToTrash(_ src: URL, trashRoot: URL, path: RelativePath) throws {
        let fm = FileManager.default
        var dst = try safeURL(trashRoot, path)
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        var n = 2
        while fm.fileExists(atPath: dst.path) {
            dst = try safeURL(trashRoot, RelativePath(path.raw + " \(n)")); n += 1
        }
        try fm.moveItem(at: src, to: dst)
    }

    /// `root` + `path`, refused when the path could leave `root`: empty, ".", ".." or NUL components, absolute paths,
    /// or an existing ancestor that is a symlink pointing outside `root` (paths come from the Box, which is untrusted input).
    static func safeURL(_ root: URL, _ path: RelativePath) throws -> URL {
        let parts = path.raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.raw.isEmpty, !path.raw.hasPrefix("/"),
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") })
        else { throw UnsafePath(path: path.raw) }
        let url = root.appendingPathComponent(path.raw)
        let fm = FileManager.default
        // Resolve the deepest existing ancestor; a root that does not exist yet (e.g. a fresh trash folder) is resolved the same way.
        func realExisting(_ u: URL) -> String {
            var a = u
            var tail: [String] = []
            while !fm.fileExists(atPath: a.path), a.path != "/" { tail.insert(a.lastPathComponent, at: 0); a = a.deletingLastPathComponent() }
            return a.resolvingSymlinksInPath().appendingPathComponent(tail.joined(separator: "/")).path
        }
        let base = realExisting(root)
        let real = realExisting(url.deletingLastPathComponent())
        guard real == base || real.hasPrefix(base + "/") else { throw UnsafePath(path: path.raw) }
        return url
    }
}

public struct UnsafePath: Error, LocalizedError, Equatable {
    public let path: String
    public var errorDescription: String? { "Unsicherer Pfad abgelehnt (verlässt den Sync-Ordner): \(path)" }
}
