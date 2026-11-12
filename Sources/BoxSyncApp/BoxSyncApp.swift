import SwiftUI
import BoxSyncCore

/// `--check` runs the headless connection check (see `Diagnose`), anything else starts the menu bar app.
@main
@MainActor
enum Entry {
    static func main() {
        if let options = Diagnose.parse(CommandLine.arguments) { Diagnose.run(options) }
        BoxSyncApp.main()
    }
}

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
    var body: some View { Image(systemName: statusSymbol(env)) }
}
