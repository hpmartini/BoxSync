import SwiftUI
import AppKit
import BoxSyncCore

struct MenuContent: View {
    @ObservedObject var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = env.status
        Text(statusLine(env)).font(.headline)
        if env.config.isComplete {
            Text("\(env.config.user)@\(env.config.host) · \(env.config.localPath)").font(.caption)
        }
        if let e = s.currentError { Text("\(e.path.map { "\($0): " } ?? "")\(e.message)") }

        if !s.conflicts.isEmpty {
            Divider()
            Text("Konfliktkopien")
            ForEach(s.conflicts.suffix(10).reversed()) { c in Button(c.copy) { env.reveal(c.copy) } }
        }
        if !s.errors.isEmpty {
            Divider()
            Menu("Letzte Fehler") {
                ForEach(s.errors.suffix(10).reversed()) { e in
                    Text("\(e.date.formatted(date: .omitted, time: .shortened)) · \(e.path.map { "\($0): " } ?? "")\(e.message)")
                }
            }
        }
        Divider()
        Button("Im Finder öffnen") { env.openInFinder() }.disabled(env.driveURL == nil)
        Button("Jetzt aktualisieren") { env.refreshNow() }.disabled(!env.isReady)
        Divider()
        Button("Einstellungen…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }.keyboardShortcut(",")
        Button("Beenden") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor
private func statusLine(_ env: AppEnvironment) -> String {
    guard env.isReady else { return "BoxSync · nicht eingerichtet (Einstellungen)" }
    if env.status.currentError != nil { return "BoxSync · Fehler" }
    if let d = env.status.lastRefresh { return "BoxSync · aktuell (\(d.formatted(date: .omitted, time: .shortened)))" }
    return "BoxSync · verbunden"
}

@MainActor
func statusSymbol(_ env: AppEnvironment) -> String {
    if !env.isReady { return "externaldrive.badge.questionmark" }
    if env.status.currentError != nil { return "exclamationmark.icloud" }
    return "externaldrive.connected.to.line.below"
}
