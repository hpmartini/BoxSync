import CryptoKit
import Foundation

extension RelativePath {
    var parent: RelativePath { RelativePath(raw.lastIndex(of: "/").map { String(raw[..<$0]) } ?? "") }
    func appending(_ name: String) -> RelativePath { RelativePath(raw.isEmpty ? name : raw + "/" + name) }
}

/// Scan -> plan -> execute -> state, one cycle at a time.
/// Safety rules: a failed remote listing aborts the cycle (a missing listing must never look like deletions);
/// nothing is hard-deleted (trash on both sides); transfers go to temp files first and are moved into place at the end.
public actor BoxSyncEngine: SyncEngine {
    private struct Context {
        var local: Snapshot, remote: Snapshot, base: StateSnapshot
        var remoteFS: RemoteFileSystem
        var names: LogicalRemote
        var dateFolder: String
    }

    private let config: Config
    private let store: StateStore
    private let disk: LocalFileSystem
    private let connect: @Sendable () async throws -> RemoteFileSystem
    private let onStatus: @Sendable (SyncStatus) -> Void

    public private(set) var status = SyncStatus()
    private var currentRun: Task<Void, Never>?
    private var rerun = false
    private var paused = false
    private var stopped = false
    private var firstSyncApproved = false
    private var watcher: FolderWatcher?
    private var timer: Task<Void, Never>?
    private var ctx: Context?
    private var doneBytes: UInt64 = 0
    private var reportedShadowed = Set<RelativePath>()

    public init(config: Config, store: StateStore, local: LocalFileSystem = DiskFileSystem(),
                connect: @escaping @Sendable () async throws -> RemoteFileSystem,
                onStatus: @escaping @Sendable (SyncStatus) -> Void = { _ in }) {
        self.config = config; self.store = store; self.disk = local
        self.connect = connect; self.onStatus = onStatus
    }

    /// Engine against the Storage Box. The password comes from the app (Keychain).
    public static func sftp(config: Config, password: String, store: StateStore, hostKeys: HostKeyStore,
                            onStatus: @escaping @Sendable (SyncStatus) -> Void = { _ in }) -> BoxSyncEngine {
        BoxSyncEngine(config: config, store: store, connect: {
            try await SFTPRemoteFileSystem.connect(host: config.host, port: config.port, user: config.user, password: password, hostKeys: hostKeys)
        }, onStatus: onStatus)
    }

    // MARK: SyncEngine

    public func start() async {
        guard watcher == nil else { return }
        stopped = false
        watcher = FolderWatcher(path: config.syncFolder) { [weak self] in Task { await self?.syncNow() } }
        let interval = UInt64(max(config.intervalSeconds, 1)) * 1_000_000_000
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.setNext(Date().addingTimeInterval(Double(interval) / 1e9))
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self?.syncNow()
            }
        }
        await syncNow()
    }

    public func pause() async {
        paused = true
        currentRun?.cancel()
        update { $0.phase = .paused }
    }

    public func resume() async {
        paused = false
        update { $0.phase = .idle }
        await syncNow()
    }

    public func stop() async {
        stopped = true
        timer?.cancel(); timer = nil
        watcher?.stop(); watcher = nil
        currentRun?.cancel()
    }

    public func checkNow() async {
        if stopped || currentRun != nil { return }
        let run = Task { await self.cycle(dryRun: true) }
        currentRun = run
        await run.value
        currentRun = nil
    }

    public func approveFirstSync() async {
        firstSyncApproved = true
        await syncNow()
    }

    public func syncNow() async {
        if paused || stopped { return }
        if let run = currentRun { rerun = true; await run.value; return }
        repeat {
            rerun = false
            let run = Task { await self.cycle() }
            currentRun = run
            await run.value
            currentRun = nil
        } while rerun && !paused && !stopped
    }

    // MARK: Cycle

    private func update(_ f: (inout SyncStatus) -> Void) { f(&status); onStatus(status) }

    private func addIssue(_ path: RelativePath?, _ message: String) {
        update {
            $0.errors.append(SyncIssue(path: path?.raw, message: message))
            if $0.errors.count > 50 { $0.errors.removeFirst($0.errors.count - 50) }
        }
    }

    private func setNext(_ d: Date) { update { $0.nextSync = d } }

    private func cycle(dryRun: Bool = false) async {
        let issuesBefore = status.errors.last?.id
        doneBytes = 0
        update { $0.phase = .running; $0.progress = SyncProgress() }
        var cancelled = false
        do {
            let remote = try await connect()
            do { try await work(remote, dryRun: dryRun) } catch is CancellationError { cancelled = true } catch { addIssue(nil, "Lauf abgebrochen: \(error)") }
            await remote.close()
        } catch {
            addIssue(nil, "Verbindung fehlgeschlagen: \(error)")
        }
        try? await store.flush()
        ctx = nil
        let hadNew = status.errors.last?.id != issuesBefore
        update {
            $0.progress.currentPath = nil
            if paused { $0.phase = .paused }
            else if hadNew { $0.phase = .error }
            else { $0.phase = .idle; if !cancelled && !dryRun && !$0.awaitingFirstSync { $0.lastSync = Date() } }
        }
    }

    private func work(_ remote: RemoteFileSystem, dryRun: Bool) async throws {
        if !rootPath.raw.isEmpty { try await remote.mkdirAll(rootPath) }
        let base = try await store.snapshot()
        let localSnap = try await disk.scan(root: config.syncFolder, exclusions: config.exclusions,
                                            known: base.records.mapValues(\.local))
        let names = SyncPlanner.logicalRemote(try await scanRemote(remote))
        let remoteSnap = names.snapshot
        for extra in names.shadowed where reportedShadowed.insert(extra).inserted {
            addIssue(extra, "Auf der Box liegt derselbe Name in zwei Unicode-Schreibweisen (NFC/NFD); nur eine wird gespiegelt, diese bleibt unberührt auf der Box")
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let now = Date()
        ctx = Context(local: localSnap, remote: remoteSnap, base: base, remoteFS: remote, names: names, dateFolder: fmt.string(from: now))
        let (plan, blocked) = SyncPlanner.guardMassTrash(
            SyncPlanner.plan(local: localSnap, remote: remoteSnap, base: base, now: now), recordCount: base.records.count)
        if blocked > 0 {
            addIssue(nil, "\(blocked) Löschungen bei \(base.records.count) bekannten Dateien auf einmal: nichts in den Papierkorb verschoben (falscher, leerer oder nicht eingehängter Ordner, oder leere Box-Liste?). Ordner und Box prüfen; in kleineren Schritten löschen geht.")
        }

        let counts = SyncCounts(plan)
        let awaiting = !dryRun && base.records.isEmpty && !(localSnap.entries.isEmpty && remoteSnap.entries.isEmpty) && !firstSyncApproved
        update { $0.pending = counts; if !dryRun { $0.awaitingFirstSync = awaiting }; if !base.records.isEmpty { $0.trackedFiles = base.records.count } }
        if dryRun || awaiting { return }
        update {
            $0.progress.totalFiles = plan.actions.count
            $0.progress.totalBytes = plan.actions.reduce(0) { $0 + transferSize($1, localSnap, remoteSnap) }
        }
        for action in plan.actions.sorted(by: { rank($0) < rank($1) }) {
            try Task.checkCancellation()
            do { try await perform(action) }
            catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                addIssue(path(of: action), "\(error)")
            }
            update { $0.progress.completedFiles += 1 }
        }
        let tracked = (try? await store.snapshot().records.count) ?? 0
        update { $0.lastRun = counts; $0.pending = SyncCounts(); $0.trackedFiles = tracked }
    }

    private func rank(_ a: SyncAction) -> Int {
        switch a {
        case .forget, .adopt: 0
        case .rename: 1
        case .conflictCopy: 2
        case .trashLocal, .trashRemote: 3
        case .download: 4
        case .upload: 5
        }
    }

    private func path(of a: SyncAction) -> RelativePath {
        switch a {
        case .upload(let p), .download(let p), .trashLocal(let p), .trashRemote(let p),
             .adopt(let p), .forget(let p): p
        case .conflictCopy(let o, _, _): o
        case .rename(_, let to): to
        }
    }

    private func transferSize(_ a: SyncAction, _ l: Snapshot, _ r: Snapshot) -> UInt64 {
        switch a {
        case .upload(let p): l.entries[p]?.size ?? 0
        case .download(let p): r.entries[p]?.size ?? 0
        case .conflictCopy(let o, _, _): (l.entries[o]?.size ?? 0) + (r.entries[o]?.size ?? 0)
        default: 0
        }
    }

    // MARK: Paths

    private var rootPath: RelativePath { RelativePath(config.remoteRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    /// Box path of a logical (NFC) sync path, in the spelling the Box actually uses.
    private func rpath(_ p: RelativePath) -> RelativePath {
        let sp = ctx?.names.spelling(of: p) ?? p
        return rootPath.raw.isEmpty ? sp : rootPath.appending(sp.raw)
    }
    private func lurl(_ p: RelativePath) -> URL { config.syncFolder.appendingPathComponent(p.raw) }
    private var partialDir: URL { config.syncFolder.appendingPathComponent(".boxsync-partial") }
    private var localTrashDir: URL { config.localTrashURL.appendingPathComponent(ctx!.dateFolder) }

    /// Temp name derived from path, size and mtime: a changed source never resumes a stale partial.
    private func partialName(_ p: RelativePath, size: UInt64, mtime: Int64) -> String {
        let h = SHA256.hash(data: Data(p.raw.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ".boxsync-\(h)-\(size)-\(mtime).part"
    }

    private func scanRemote(_ remote: RemoteFileSystem) async throws -> Snapshot {
        var entries: [RelativePath: FileMeta] = [:]
        var stack = [rootPath]
        let prefixLen = rootPath.raw.isEmpty ? 0 : rootPath.raw.utf8.count + 1
        while let dir = stack.popLast() {
            try Task.checkCancellation()
            for (full, m) in try await remote.list(dir) {
                let rel = RelativePath(String(decoding: full.raw.utf8.dropFirst(prefixLen), as: UTF8.self))
                if Exclusions.isReserved(rel) || Exclusions.matches(rel, patterns: config.exclusions) { continue }
                if m.isDirectory { stack.append(full) } else { entries[rel] = m }
            }
        }
        return Snapshot(entries: entries)
    }

    // MARK: Actions

    private func perform(_ action: SyncAction) async throws {
        let c = ctx!
        switch action {
        case .forget(let p):
            try await store.remove(p)
        case .adopt(let p):
            guard let l = c.local.entries[p], var r = c.remote.entries[p] else { return }
            r.hash = c.base.records[p]?.remote.hash ?? l.hash
            try await store.upsert(StateRecord(path: p, local: l, remote: r))
        case .upload(let p):
            if let rec = try await upload(p) { try await store.upsert(rec) }
        case .download(let p):
            guard let r = c.remote.entries[p] else { return }
            try await store.upsert(try await download(remote: p, as: p, meta: r))
        case .trashLocal(let p):
            try await disk.trash(p, root: config.syncFolder, trashRoot: localTrashDir)
            try await store.remove(p)
        case .trashRemote(let p):
            try await trashRemote(p)
            try await store.remove(p)
        case .rename(let from, let to):
            try await rename(from, to)
        case .conflictCopy(let original, let copy, let keepLocal):
            try await conflict(original, copy, keepLocal: keepLocal)
        }
    }

    private func note(_ p: RelativePath, _ bytes: UInt64) {
        update { $0.progress.currentPath = p.raw; $0.progress.completedBytes = doneBytes + bytes }
    }

    /// Temp file next to the target, then atomic rename. Returns nil when the file changed since the scan
    /// (the next cycle picks it up).
    private func upload(_ p: RelativePath) async throws -> StateRecord? {
        let c = ctx!
        guard let l = (c.local.entries[p] ?? conflictSource[p]) else { return nil }
        guard let now = try disk.meta(p, root: config.syncFolder, hash: l.hash),
              now.size == l.size, now.mtimeSeconds == l.mtimeSeconds else { return nil }
        let remote = c.remoteFS, target = rpath(p)
        try await remote.mkdirAll(target.parent)
        let tmp = target.parent.appending(partialName(p, size: l.size, mtime: l.mtimeSeconds))
        let existing = try await remote.stat(tmp)?.size ?? 0
        let offset = existing > l.size ? 0 : SFTPRemoteFileSystem.resumeOffset(remoteSize: existing)
        let startNote = doneBytes
        try await remote.write(tmp, from: lurl(p), offset: offset) { pos in Task { await self.note(p, pos) } }
        guard try await remote.stat(tmp)?.size == l.size else { throw SyncError.sizeMismatch(p) }
        try await remote.setModificationDate(tmp, to: l.mtime)
        if try await remote.stat(target) != nil { try await trashRemote(p) }   // SFTP v3 cannot overwrite
        try await remote.rename(tmp, to: target)
        doneBytes = startNote + l.size
        note(p, 0)
        return StateRecord(path: p, local: l, remote: FileMeta(size: l.size, mtime: Date(timeIntervalSince1970: TimeInterval(l.mtimeSeconds)), hash: l.hash))
    }

    /// Downloads `remote` (a path relative to the sync root) into the local path `local`.
    private func download(remote p: RelativePath, as local: RelativePath, meta r: FileMeta) async throws -> StateRecord {
        let remote = ctx!.remoteFS
        let fm = FileManager.default
        let tmp = partialDir.appendingPathComponent(partialName(p, size: r.size, mtime: r.mtimeSeconds))
        let have = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let offset = have <= r.size ? have : 0
        let startNote = doneBytes
        try await remote.read(rpath(p), offset: offset, to: tmp) { pos in Task { await self.note(local, pos) } }
        let got = (try fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard got == r.size else { throw SyncError.sizeMismatch(p) }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(r.mtimeSeconds))], ofItemAtPath: tmp.path)
        let hash = try DiskFileSystem.sha256(of: tmp)
        try await disk.install(partial: tmp, as: local, root: config.syncFolder, trashRoot: localTrashDir)
        guard let lm = try disk.meta(local, root: config.syncFolder, hash: hash) else { throw SyncError.sizeMismatch(local) }
        doneBytes = startNote + r.size
        note(local, 0)
        var rm = r; rm.hash = hash
        return StateRecord(path: local, local: lm, remote: rm)
    }

    private func trashRemote(_ p: RelativePath) async throws {
        let remote = ctx!.remoteFS
        let dayDir = rpath(RelativePath(config.remoteTrashPath)).appending(ctx!.dateFolder)
        var dest = dayDir.appending(p.raw)
        try await remote.mkdirAll(dest.parent)
        var n = 2
        while try await remote.stat(dest) != nil { dest = dayDir.appending(p.raw + " \(n)"); n += 1 }
        try await remote.rename(rpath(p), to: dest)
    }

    private func rename(_ from: RelativePath, _ to: RelativePath) async throws {
        let c = ctx!
        guard let b = c.base.records[from], let l = c.local.entries[to] else { return }
        try await c.remoteFS.mkdirAll(rpath(to).parent)
        try await c.remoteFS.rename(rpath(from), to: rpath(to))
        try await store.remove(from)
        try await store.upsert(StateRecord(path: to, local: l, remote: b.remote))
    }

    /// Source of an upload that is not in the scan (the old local version moved to the conflict copy path).
    private var conflictSource: [RelativePath: FileMeta] = [:]

    /// Newer version stays at `original`, the older one is stored at `copy` on both sides. Every step leaves a
    /// state the next cycle converges from (an abort in the middle loses nothing).
    private func conflict(_ original: RelativePath, _ copy: RelativePath, keepLocal: Bool) async throws {
        let c = ctx!
        guard let l = c.local.entries[original], let r = c.remote.entries[original] else { return }
        if keepLocal {
            try await c.remoteFS.rename(rpath(original), to: rpath(copy))        // old Box version -> copy
            try await store.upsert(try await download(remote: copy, as: copy, meta: r))
            if let rec = try await upload(original) { try await store.upsert(rec) }
        } else {
            try await disk.move(original, to: copy, root: config.syncFolder)     // old local version -> copy
            conflictSource[copy] = l
            defer { conflictSource[copy] = nil }
            if let rec = try await upload(copy) { try await store.upsert(rec) }
            try await store.upsert(try await download(remote: original, as: original, meta: r))
        }
        update { $0.conflicts.append(ConflictInfo(original: original.raw, copy: copy.raw)) }
    }
}

enum SyncError: Error, CustomStringConvertible {
    case sizeMismatch(RelativePath)
    var description: String {
        switch self { case .sizeMismatch(let p): "Größe nach Übertragung stimmt nicht (Datei hat sich geändert?): \(p.raw)" }
    }
}
