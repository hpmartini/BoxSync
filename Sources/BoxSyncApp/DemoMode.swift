import Foundation
import BoxSyncCore

/// Invented data for screenshots (`BOXSYNC_DEMO=1 open BoxSync.app` or `swift run`). Touches neither disk nor network
/// and never reads or writes the real settings.
enum Demo {
    static var enabled: Bool { ProcessInfo.processInfo.environment["BOXSYNC_DEMO"] != nil }

    static let configs: [Config] = [
        Config(syncFolder: URL(fileURLWithPath: "/Users/demo/Documents"), host: "u123456.your-storagebox.de", user: "u123456"),
        Config(syncFolder: URL(fileURLWithPath: "/Users/demo/Notes"), host: "u123456.your-storagebox.de", user: "u123456",
               remoteRoot: "Notes", exclusions: [".DS_Store", ".git", ".obsidian/workspace*"]),
    ]

    static func status(for config: Config) -> SyncStatus {
        var s = SyncStatus()
        let now = Date()
        if config.remoteRoot.isEmpty {
            s.lastSync = now.addingTimeInterval(-120)
            s.nextSync = now.addingTimeInterval(180)
            s.trackedFiles = 1284
            s.pending = SyncCounts()
            s.lastRun = counts(uploads: 4, downloads: 1)
        } else {
            s.trackedFiles = 412
            s.nextSync = now.addingTimeInterval(240)
            s.pending = counts(uploads: 3, downloads: 2)
            s.lastRun = counts(uploads: 12, downloads: 4, conflicts: 1)
            s.conflicts = [ConflictInfo(original: "Ideas.md", copy: "Ideas (Konfliktkopie 2026-10-20 1412).md")]
        }
        return s
    }

    private static func counts(uploads: Int = 0, downloads: Int = 0, conflicts: Int = 0) -> SyncCounts {
        var c = SyncCounts()
        c.uploads = uploads; c.downloads = downloads; c.conflicts = conflicts
        return c
    }
}

/// Publishes one fixed status and ignores every command.
struct DemoEngine: SyncEngine {
    let status: SyncStatus
    let onStatus: @Sendable (SyncStatus) -> Void
    func start() async { onStatus(status) }
    func pause() async {}
    func resume() async {}
    func syncNow() async {}
    func checkNow() async {}
    func approveFirstSync() async {}
    func stop() async {}
}
