import SwiftUI
import BoxSyncCore

@main
struct BoxSyncApp: App {
    @StateObject private var env = AppEnvironment()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(env: env)
        } label: {
            StatusIcon(env: env)
        }
        Window("BoxSync Einstellungen", id: "settings") {
            SettingsView(env: env)
        }
        .windowResizability(.contentSize)
    }
}

private struct StatusIcon: View {
    @ObservedObject var env: AppEnvironment
    var body: some View {
        Image(systemName: SyncPhase.combined(env.pairs.map(\.state.status)).symbol)
    }
}
