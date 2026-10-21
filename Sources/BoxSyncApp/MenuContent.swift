import SwiftUI
import AppKit
import BoxSyncCore

struct MenuContent: View {
    @ObservedObject var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(env.pairs) { pair in
            Menu("\(pair.name) · \(statusLine(pair.state.status))") { PairMenu(env: env, pair: pair, state: pair.state) }
        }
        Divider()
        Button("Alle jetzt synchronisieren") { env.syncNow() }
            .disabled(env.pairs.contains { let s = $0.state.status; return s.phase == .running || s.phase == .paused || s.awaitingFirstSync })
        Button("Alle nur prüfen (ändert nichts)") { env.checkNow() }
            .disabled(env.pairs.contains { $0.state.status.phase == .running })
        Button(env.allPaused ? "Alle weiter" : "Alle pausieren") { env.togglePause() }
        Divider()
        Button("Einstellungen…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }.keyboardShortcut(",")
        Button("Beenden") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

/// Details and commands of one sync pair.
private struct PairMenu: View {
    let env: AppEnvironment
    let pair: SyncPair
    @ObservedObject var state: SyncState

    var body: some View {
        let s = state.status
        let cfg = pair.config
        Text("\(cfg.syncFolder.path) ↔ \(cfg.host):\(cfg.remoteRoot.isEmpty ? "~" : cfg.remoteRoot)").font(.caption)
        Text(statusLine(s))
        if s.phase == .running {
            if s.progress.totalFiles > 0 {
                Text("\(s.progress.completedFiles) von \(s.progress.totalFiles) Aktionen · \(bytes(s.progress.completedBytes)) von \(bytes(s.progress.totalBytes))")
            }
            if let p = s.progress.currentPath { Text(p) }
        } else {
            if s.trackedFiles > 0 { Text("\(s.trackedFiles) Dateien synchron") }
            if let p = s.pending, p.total > 0 { Text("Ausstehend: \(summary(p))") }
            else if s.pending != nil { Text(s.awaitingFirstSync ? "Plan: keine Änderungen nötig" : "Nichts zu synchronisieren") }
            if let r = s.lastRun, r.total > 0 { Text("Letzter Lauf: \(summary(r))") }
            if let n = s.nextSync, s.phase == .idle { Text("Nächster Abgleich: \(n.formatted(date: .omitted, time: .shortened))") }
        }

        if s.awaitingFirstSync {
            Divider()
            Text("Erstabgleich wartet auf dich")
            Text("Erster Abgleich dieses Ordners. Prüfe die Zahlen oben.")
            Button("Erstabgleich starten") { env.approveFirstSync(pair) }
        }
        if !s.errors.isEmpty {
            Divider()
            Text("Letzte Fehler")
            ForEach(s.errors.suffix(5)) { Text("\($0.path.map { "\($0): " } ?? "")\($0.message)") }
        }
        if !s.conflicts.isEmpty {
            Divider()
            Text("Konflikte")
            ForEach(s.conflicts.suffix(10)) { c in
                Button(c.copy) { reveal(c.copy) }
            }
        }
        Divider()
        Button("Jetzt synchronisieren") { env.syncNow(pair) }.disabled(s.phase == .running || s.phase == .paused || s.awaitingFirstSync)
        Button("Nur prüfen (ändert nichts)") { env.checkNow(pair) }.disabled(s.phase == .running)
        Button("Sync-Ordner im Finder zeigen") { NSWorkspace.shared.open(cfg.syncFolder) }
    }

    private func summary(_ c: SyncCounts) -> String {
        var parts: [String] = []
        if c.uploads > 0 { parts.append("↑ \(c.uploads) hoch") }
        if c.downloads > 0 { parts.append("↓ \(c.downloads) runter") }
        if c.conflicts > 0 { parts.append("⚠ \(c.conflicts) Konflikte") }
        if c.trashed > 0 { parts.append("🗑 \(c.trashed) in Papierkorb") }
        if c.renames > 0 { parts.append("↔ \(c.renames) umbenannt") }
        return parts.joined(separator: " · ")
    }

    private func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// `copy` may be absolute or relative to the sync folder.
    private func reveal(_ path: String) {
        let root = pair.config.syncFolder
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

private func statusLine(_ s: SyncStatus) -> String {
    switch s.phase {
    case .idle:
        if s.awaitingFirstSync { return "Erstabgleich noch nicht freigegeben" }
        if let p = s.pending, p.total > 0 { return "Ausstehend · \(p.total) Änderungen" }
        return s.lastSync.map { "Aktuell · zuletzt \($0.formatted(date: .omitted, time: .shortened))" } ?? "Bereit · noch nicht synchronisiert"
    case .running:
        return "Synchronisiert …"
    case .paused: return "Pausiert"
    case .error: return "Fehler · siehe Untermenü"
    }
}

extension SyncPhase {
    var symbol: String {
        switch self {
        case .idle: "checkmark.arrow.trianglehead.counterclockwise"
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    /// Worst phase wins for the menu bar icon: error, then running, then paused, then idle.
    static func combined(_ states: [SyncStatus]) -> SyncPhase {
        let phases = states.map { $0.phase == .idle && !$0.errors.isEmpty ? SyncPhase.error : $0.phase }
        for p in [SyncPhase.error, .running, .paused] where phases.contains(p) { return p }
        return .idle
    }
}
