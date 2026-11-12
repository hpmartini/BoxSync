import Foundation
import BoxSyncCore

/// Invented data for screenshots (`BOXSYNC_DEMO=1`). Touches neither the drive nor the network
/// and never reads or writes the real settings.
enum Demo {
    static var enabled: Bool { ProcessInfo.processInfo.environment["BOXSYNC_DEMO"] != nil }

    static let config = Config(host: "u123456.your-storagebox.de", user: "u123456", localPath: "~/BoxSync")

    static var status: ProviderStatus {
        var s = ProviderStatus()
        s.lastRefresh = Date().addingTimeInterval(-120)
        s.add(ProviderConflict(original: "Notes/Ideas.md", copy: "Notes/Ideas (Konfliktkopie 2026-10-20 1412).md"))
        return s
    }
}
