import Foundation

/// Result of one check-only run of a folder pair (`BoxSyncApp --check`).
public struct PairCheck: Sendable {
    public var name: String
    public var folder: String
    public var remote: String
    public var status: SyncStatus
    public init(name: String, folder: String, remote: String, status: SyncStatus) {
        self.name = name; self.folder = folder; self.remote = remote; self.status = status
    }

    public enum Verdict: Int, Comparable, Sendable {
        case ok = 0, pending = 1, failed = 2
        public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    /// failed: any error or no plan at all (the scan did not complete); pending: the plan has work; else ok.
    public var verdict: Verdict {
        if !status.errors.isEmpty || status.phase == .error { return .failed }
        guard let p = status.pending else { return .failed }
        return p.total > 0 ? .pending : .ok
    }
}

/// Plain-text report of a check run. Pure, so it is tested without network.
public enum DiagnosisReport {
    /// 0 = every pair in sync, 1 = work pending or an error, so scripts can branch on it.
    public static func exitCode(_ checks: [PairCheck]) -> Int32 {
        (checks.map(\.verdict).max() ?? .ok) == .ok ? 0 : 1
    }

    public static func text(_ checks: [PairCheck], date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = ["BoxSync Diagnose · \(fmt.string(from: date))", "Modus: nur prüfen, es wurde nichts geändert", ""]
        for c in checks {
            out.append("[\(c.name)]  \(c.folder) <-> \(c.remote)")
            out.append("  Ergebnis: \(headline(c))")
            if c.status.trackedFiles > 0 { out.append("  Dateien synchron: \(c.status.trackedFiles)") }
            if let p = c.status.pending { out.append("  Ausstehend: \(summary(p))") }
            for e in c.status.errors { out.append("  Fehler: \(e.path.map { "\($0): " } ?? "")\(e.message)") }
            for k in c.status.conflicts { out.append("  Konflikt: \(k.copy)") }
            out.append("")
        }
        let worst = checks.map(\.verdict).max() ?? .ok
        out.append("Gesamt: " + (worst == .ok ? "ALLES OK, nichts zu synchronisieren" : worst == .pending ? "AUSSTEHEND, es gibt Änderungen" : "FEHLER, siehe oben"))
        return out.joined(separator: "\n") + "\n"
    }

    private static func headline(_ c: PairCheck) -> String {
        switch c.verdict {
        case .ok: "OK, nichts zu synchronisieren"
        case .pending: "AUSSTEHEND, \(c.status.pending?.total ?? 0) Änderungen"
        case .failed: "FEHLER"
        }
    }

    private static func summary(_ c: SyncCounts) -> String {
        "↑ \(c.uploads) hoch · ↓ \(c.downloads) runter · ⚠ \(c.conflicts) Konflikte · 🗑 \(c.trashed) Papierkorb · ↔ \(c.renames) umbenannt"
    }
}
