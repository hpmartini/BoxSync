import Foundation

public enum SyncAction: Hashable, Sendable {
    case upload(RelativePath)
    case download(RelativePath)
    /// Both sides changed: newer stays `original`, the older one is stored under `copy`
    /// ("Name (Konfliktkopie JJJJ-MM-TT HHMM).ext") on both sides.
    case conflictCopy(original: RelativePath, copy: RelativePath, keepLocal: Bool)
    case trashLocal(RelativePath)
    case trashRemote(RelativePath)
    /// Same content (hash), new path locally; applied on the Box. A rename seen on the Box is not detected:
    /// size+mtime cannot prove equal content, so it is download + trash.
    case rename(from: RelativePath, to: RelativePath)
    /// Both sides already agree (or only mtime was touched): record the current state, transfer nothing.
    case adopt(RelativePath)
    /// Gone on both sides: drop the state record.
    case forget(RelativePath)
}

public struct SyncPlan: Sendable {
    public var actions: [SyncAction]
    public init(actions: [SyncAction] = []) { self.actions = actions }
}

/// Remote snapshot keyed by NFC path, plus how to address the files on the Box.
public struct LogicalRemote: Sendable {
    public var snapshot: Snapshot
    /// NFC path -> actual spelling on the Box (only for files that exist there).
    public var rawName: [RelativePath: RelativePath]
    /// NFC directory path -> actual spelling of that directory on the Box.
    public var rawDirs: [String: String]
    /// Further spellings of an already mirrored name (NFC and NFD of the same file on the Box):
    /// not mirrored, never touched. The Box keeps both; reported to the user.
    public var shadowed: [RelativePath]

    /// Box path for a logical path: the existing spelling, else the NFC name inside the existing (NFC or NFD) folders.
    public func spelling(of p: RelativePath) -> RelativePath {
        if let r = rawName[p] { return r }
        var out: [String] = [], logicalPrefix = ""
        let comps = p.raw.split(separator: "/", omittingEmptySubsequences: true)
        for (i, comp) in comps.enumerated() {
            logicalPrefix += (logicalPrefix.isEmpty ? "" : "/") + comp
            let isDir = i < comps.count - 1
            out.append(isDir ? rawDirs[logicalPrefix].map { String($0.split(separator: "/").last ?? "") } ?? String(comp) : String(comp))
        }
        return RelativePath(out.joined(separator: "/"))
    }
}

/// Pure planner: no I/O, testable without network.
public enum SyncPlanner {
    /// Pairs local and remote files by NFC name. Per name the NFC spelling is mirrored if the Box has it,
    /// otherwise the byte-wise first one; every other spelling is listed in `shadowed`.
    /// Names (and folders on the way) that differ only in letter case cannot coexist on a case-insensitive volume,
    /// so only one new spelling is mirrored per name. Every spelling the user already has (`known`: local files and
    /// state records) stays mirrored, so a tracked file can never drop out of the mirror, which the planner would read
    /// as "deleted on the Box" and trash locally (a new `Report.md` on the Box next to the tracked `report.md`; or both
    /// spellings on a case-sensitive volume). An unknown spelling is only mirrored if no spelling of that name is yet.
    /// shortcut: `lowercased()` instead of APFS's exact folding table, upgrade if a locale mismatch ever shows up.
    public static func logicalRemote(_ remote: Snapshot, preferring known: Set<RelativePath> = []) -> LogicalRemote {
        var out = LogicalRemote(snapshot: Snapshot(), rawName: [:], rawDirs: [:], shadowed: [])
        func prefixes(_ p: String) -> [String] {
            let parts = p.split(separator: "/", omittingEmptySubsequences: true)
            return (1...max(parts.count, 1)).map { parts.prefix($0).joined(separator: "/") }
        }
        var mirrored: [String: Set<String>] = [:]   // case-folded path prefix -> spellings that are mirrored
        for p in known.map(\.logical) { for pre in prefixes(p) { mirrored[pre.lowercased(), default: []].insert(pre) } }
        for p in remote.entries.keys.map(\.logical).sorted() {
            for pre in prefixes(p) where mirrored[pre.lowercased()] == nil { mirrored[pre.lowercased()] = [pre] }
        }
        for raw in remote.entries.keys.sorted() {
            let key = raw.normalized
            if prefixes(key.raw).contains(where: { mirrored[$0.lowercased()]?.contains($0) != true }) {
                out.shadowed.append(raw); continue   // a case variant of a name or folder that is mirrored in another spelling
            }
            if let current = out.rawName[key] {
                if raw == key {   // NFC spelling wins over the one mirrored so far
                    out.shadowed.append(current); out.rawName[key] = raw; out.snapshot.entries[key] = remote.entries[raw]
                } else { out.shadowed.append(raw) }
                continue
            }
            out.rawName[key] = raw; out.snapshot.entries[key] = remote.entries[raw]
        }
        for raw in remote.entries.keys.sorted() {   // directory spellings: NFC wins, else the first one seen
            let r = raw.raw.split(separator: "/", omittingEmptySubsequences: true)
            for i in 1..<max(r.count, 1) {
                let candidate = r[..<i].joined(separator: "/"), lk = candidate.precomposedStringWithCanonicalMapping
                if out.rawDirs[lk] == nil || candidate == lk && out.rawDirs[lk] != lk { out.rawDirs[lk] = candidate }
            }
        }
        return out
    }

    public static func plan(local: Snapshot, remote: Snapshot, base: StateSnapshot, now: Date = Date()) -> SyncPlan {
        func localChanged(_ l: FileMeta, _ b: StateRecord) -> Bool {
            if let h = l.hash, let bh = b.local.hash { return h != bh }
            return l.size != b.local.size || l.mtimeSeconds != b.local.mtimeSeconds
        }
        func remoteChanged(_ r: FileMeta, _ b: StateRecord) -> Bool {
            r.size != b.remote.size || r.mtimeSeconds != b.remote.mtimeSeconds
        }

        let loc = local.entries.filter { !Exclusions.isReserved($0.key) }
        let rem = remote.entries.filter { !Exclusions.isReserved($0.key) }
        var actions: [SyncAction] = []
        var consumed = Set<RelativePath>()   // base paths / new paths already handled by a rename

        // 1. Renames (same content at a new path).
        let localOnlyNew = loc.keys.filter { rem[$0] == nil && base.records[$0] == nil }.sorted()
        var byHash: [String: [RelativePath]] = [:]
        for (p, b) in base.records where loc[p] == nil && !b.local.isDirectory {
            if let r = rem[p], !remoteChanged(r, b), b.local.size > 0, let h = b.local.hash { byHash[h, default: []].append(p) }
        }
        for p in localOnlyNew {
            guard let l = loc[p], l.size > 0, let h = l.hash,
                  let from = byHash[h]?.sorted().first(where: { !consumed.contains($0) }) else { continue }
            actions.append(.rename(from: from, to: p))
            consumed.insert(from); consumed.insert(p)
        }

        // 2. Everything else, per path.
        var taken = Set(loc.keys).union(rem.keys)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = fmt.string(from: now)

        for p in Set(loc.keys).union(rem.keys).union(base.records.keys).sorted() where !consumed.contains(p) {
            if Exclusions.isReserved(p) { continue }
            let l = loc[p], r = rem[p], b = base.records[p]
            switch (l, r, b) {
            case let (l?, r?, nil):
                if l.size == r.size && l.mtimeSeconds == r.mtimeSeconds { actions.append(.adopt(p)) }
                else { actions.append(conflict(p, l, r, stamp, &taken)) }
            case (_?, nil, nil):
                actions.append(.upload(p))
            case (nil, _?, nil):
                actions.append(.download(p))
            case let (l?, r?, b?):
                let lc = localChanged(l, b), rc = remoteChanged(r, b)
                if lc && rc { actions.append(conflict(p, l, r, stamp, &taken)) }
                else if lc { actions.append(.upload(p)) }
                else if rc { actions.append(.download(p)) }
                else if l.mtimeSeconds != b.local.mtimeSeconds { actions.append(.adopt(p)) }
            case let (l?, nil, b?):
                actions.append(localChanged(l, b) ? .upload(p) : .trashLocal(p))   // change beats deletion
            case let (nil, r?, b?):
                actions.append(remoteChanged(r, b) ? .download(p) : .trashRemote(p))
            case (nil, nil, _?):
                actions.append(.forget(p))
            case (nil, nil, nil):
                break
            }
        }
        return SyncPlan(actions: actions)
    }

    /// Mass-deletion guard: a side that suddenly lists (almost) empty (wrong folder, unmounted volume, empty Box
    /// listing) would otherwise move the whole mirror to the trash. More than `minCount` trash actions AND more
    /// than half of all state records: the trash actions are dropped, `blocked` says how many.
    public static func guardMassTrash(_ plan: SyncPlan, recordCount: Int, minCount: Int = 20) -> (plan: SyncPlan, blocked: Int) {
        func isTrash(_ a: SyncAction) -> Bool { if case .trashLocal = a { true } else if case .trashRemote = a { true } else { false } }
        let n = plan.actions.filter(isTrash).count
        guard n > minCount, n * 2 > recordCount else { return (plan, 0) }
        return (SyncPlan(actions: plan.actions.filter { !isTrash($0) }), n)
    }

    private static func conflict(_ p: RelativePath, _ l: FileMeta, _ r: FileMeta, _ stamp: String,
                                 _ taken: inout Set<RelativePath>) -> SyncAction {
        let copy = conflictName(p, stamp: stamp, taken: taken)
        taken.insert(copy)
        return .conflictCopy(original: p, copy: copy, keepLocal: l.mtime >= r.mtime)
    }

    /// `dir/Name.ext` -> `dir/Name (Konfliktkopie <stamp>).ext`; appends " 2", " 3" ... if taken.
    public static func conflictName(_ p: RelativePath, stamp: String, taken: Set<RelativePath>) -> RelativePath {
        let raw = p.raw
        let slash = raw.lastIndex(of: "/").map { raw.index(after: $0) } ?? raw.startIndex
        let dir = raw[..<slash], file = raw[slash...]
        let dot = file.dropFirst().lastIndex(of: ".")
        let (stem, ext) = dot.map { (file[..<$0], file[$0...]) } ?? (file, "")
        var n = 1
        while true {
            let suffix = n == 1 ? "" : " \(n)"
            let cand = RelativePath("\(dir)\(stem) (Konfliktkopie \(stamp)\(suffix))\(ext)")
            if !taken.contains(cand) { return cand }
            n += 1
        }
    }
}
