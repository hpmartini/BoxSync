import Foundation

/// Box-side steps of the drive. Nothing is ever deleted for good: replaced and deleted items go to
/// `_trash/<yyyy-MM-dd>/<path>` on the Box.
public enum BoxOperations {
    public static let trashRoot = RelativePath("_trash")

    public static func dayStamp(_ d: Date) -> String { formatted(d, "yyyy-MM-dd") }
    /// Used in conflict copy names.
    public static func minuteStamp(_ d: Date) -> String { formatted(d, "yyyy-MM-dd HHmm") }

    private static func formatted(_ d: Date, _ format: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format
        return f.string(from: d)
    }

    /// Writes `local` to `path` through a temp file in the same folder, so the Box never holds a half-written file
    /// under the real name. With `replacing`, an existing file at `path` goes to the Box trash first (its trash folder
    /// is prepared before, so the name is empty only between two renames); without, an existing file is an error.
    /// Returns the metadata the Box reports afterwards.
    @discardableResult
    public static func upload(_ r: RemoteFileSystem, from local: URL, to path: RelativePath, mtime: Date?,
                              replacing: Bool, now: Date = Date(),
                              progress: @Sendable (UInt64) -> Void = { _ in }) async throws -> FileMeta {
        let temp = path.parent.appending(".boxsync-\(UUID().uuidString).part")
        do {
            try await r.write(temp, from: local, offset: 0, progress: progress)
            if let mtime { try await r.setModificationDate(temp, to: mtime) }
            if let existing = try await r.stat(path) {
                guard replacing, !existing.isDirectory else { throw CocoaError(.fileWriteFileExists) }
                let dest = try await trashTarget(r, for: path, now: now)
                try await r.rename(path, to: dest)
            }
            try await r.rename(temp, to: path)
        } catch {
            try? await r.remove(temp)
            throw error
        }
        guard let m = try await r.stat(path) else { throw RemoteNotFound(path: path.raw) }
        return m
    }

    /// Downloads `path` into `dir` and returns the file with the metadata it matches. A cancelled attempt leaves its
    /// bytes behind, and the next call for the same `key` and Box version continues from there: ForkLift and Finder
    /// cancel and re-request an open after a few seconds, so restarting at 0 never finished large files.
    /// Callers must not run two downloads of one `key` at once (they would share the partial file).
    public static func download(_ r: RemoteFileSystem, _ path: RelativePath, key: String, into dir: URL,
                                progress: @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws -> (URL, FileMeta) {
        guard let m = try await r.stat(path), !m.isDirectory else { throw RemoteNotFound(path: path.raw) }
        let prefix = partialPrefix + String(key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }) + "-"
        let dst = dir.appendingPathComponent("\(prefix)\(m.size)-\(m.mtimeSeconds)")
        let fm = FileManager.default
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where old.hasPrefix(prefix) && old != dst.lastPathComponent {
            try? fm.removeItem(at: dir.appendingPathComponent(old))   // an older Box version of this file
        }
        let have = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.uint64Value ?? 0
        try await r.read(path, offset: have <= m.size ? have : 0, to: dst) { progress($0, m.size) }
        let got = (try fm.attributesOfItem(atPath: dst.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard got == m.size else {
            try? fm.removeItem(at: dst)
            throw CocoaError(.fileReadCorruptFile)
        }
        return (dst, m)
    }

    static let partialPrefix = "partial-"

    /// Removes partial downloads nobody came back for (previews scrolled past).
    public static func sweepPartials(in dir: URL, olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(partialPrefix) {
            let u = dir.appendingPathComponent(name)
            if let d = try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date, now.timeIntervalSince(d) > age {
                try? fm.removeItem(at: u)
            }
        }
    }

    /// Moves a file or folder to `_trash/<day>/<path>`. Returns where it went.
    @discardableResult
    public static func trash(_ r: RemoteFileSystem, _ path: RelativePath, now: Date = Date()) async throws -> RelativePath {
        let dest = try await trashTarget(r, for: path, now: now)
        try await r.rename(path, to: dest)
        return dest
    }

    /// A free place for `path` under `_trash/<day>/`, its folders created. A name already taken there gets
    /// " 2", " 3" ... appended; so does a folder component that exists as a file (from an earlier trashed file).
    static func trashTarget(_ r: RemoteFileSystem, for path: RelativePath, now: Date) async throws -> RelativePath {
        var dir = trashRoot.appending(dayStamp(now))
        try await r.mkdirAll(dir)
        for comp in path.parent.raw.split(separator: "/").map(String.init) {
            var cand = dir.appending(comp), n = 2
            while let m = try await r.stat(cand), !m.isDirectory {
                cand = dir.appending(comp.numbered(n)); n += 1
            }
            try await r.mkdir(cand)
            dir = cand
        }
        var dest = dir.appending(path.name), n = 2
        while try await r.stat(dest) != nil {
            dest = dir.appending(path.name.numbered(n)); n += 1
        }
        return dest
    }

    /// A free sibling name for a conflict copy of `path`.
    public static func conflictCopyPath(_ r: RemoteFileSystem, for path: RelativePath, now: Date = Date()) async throws -> RelativePath {
        let siblings = Set(try await r.list(path.parent).keys.map(\.name))
        let name = NameRules.conflictName(path.name, stamp: minuteStamp(now)) { siblings.contains($0) }
        return path.parent.appending(name)
    }
}

private extension String {
    /// `Name.ext` -> `Name n.ext`.
    func numbered(_ n: Int) -> String {
        let dot = dropFirst().lastIndex(of: ".")
        return dot.map { "\(self[..<$0]) \(n)\(self[$0...])" } ?? "\(self) \(n)"
    }
}
