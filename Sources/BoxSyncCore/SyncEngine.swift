import Foundation

public struct SyncProgress: Equatable, Sendable {
    public var completedFiles = 0
    public var totalFiles = 0
    public var completedBytes: UInt64 = 0
    public var totalBytes: UInt64 = 0
    public var currentPath: String?
    public init() {}
}

public struct SyncIssue: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var date: Date
    public var path: String?
    public var message: String
    public init(date: Date = Date(), path: String? = nil, message: String) {
        self.date = date; self.path = path; self.message = message
    }
}

public struct ConflictInfo: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var date: Date
    public var original: String
    public var copy: String
    public init(date: Date = Date(), original: String, copy: String) {
        self.date = date; self.original = original; self.copy = copy
    }
}

/// What a plan would do (or did), by kind. Adopt/forget are bookkeeping and not counted.
public struct SyncCounts: Equatable, Sendable {
    public var uploads = 0, downloads = 0, conflicts = 0, trashed = 0, renames = 0
    public var total: Int { uploads + downloads + conflicts + trashed + renames }
    public init() {}
    public init(_ plan: SyncPlan) {
        for a in plan.actions {
            switch a {
            case .upload: uploads += 1
            case .download: downloads += 1
            case .conflictCopy: conflicts += 1
            case .trashLocal, .trashRemote: trashed += 1
            case .rename: renames += 1
            case .adopt, .forget: break
            }
        }
    }
}

public enum SyncPhase: Equatable, Sendable { case idle, running, paused, error }

/// Everything the UI shows.
public struct SyncStatus: Equatable, Sendable {
    public var phase: SyncPhase = .idle
    public var progress = SyncProgress()
    /// Newest last, capped at 50.
    public var errors: [SyncIssue] = []
    public var conflicts: [ConflictInfo] = []
    public var lastSync: Date?
    /// Planned work seen by the last scan; nil before the first scan.
    public var pending: SyncCounts?
    /// What the last completed run did.
    public var lastRun: SyncCounts?
    /// Files known to be in sync.
    public var trackedFiles = 0
    public var nextSync: Date?
    /// First run on an already filled folder pair: nothing is done until the user approves the shown plan.
    public var awaitingFirstSync = false
    public init() {}
}

/// ObservableObject-compatible holder; the UI observes it, the engine writes it.
@MainActor
public final class SyncState: ObservableObject {
    @Published public var status = SyncStatus()
    public init() {}
}

/// UI-independent engine. Phase 2 (File Provider) can drive the same protocol.
public protocol SyncEngine: Sendable {
    /// Starts FSEvents watcher and Box timer, and runs a first cycle.
    func start() async
    func pause() async
    func resume() async
    /// Runs one full cycle now ("Jetzt sync"); returns when it is done.
    func syncNow() async
    /// Scans both sides and publishes what a run would do, without changing anything.
    func checkNow() async
    /// Lets the first run on an already filled folder pair proceed.
    func approveFirstSync() async
    /// Cancels a running cycle (the next one resumes consistently) and stops watcher and timer.
    func stop() async
}
