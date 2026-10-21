import SwiftUI
import AppKit
import BoxSyncCore

struct SettingsView: View {
    /// One editable sync pair; `config` keeps the fields the form does not show (trash locations).
    private struct Row: Identifiable {
        let id = UUID()
        var config: Config
        var exclusions: String
    }

    @ObservedObject var env: AppEnvironment
    @State private var rows: [Row]
    @State private var host: String
    @State private var port: Int
    @State private var user: String
    @State private var minutes: Int
    @State private var password = ""

    init(env: AppEnvironment) {
        self.env = env
        let c = env.configs.first ?? Config(syncFolder: URL(fileURLWithPath: NSHomeDirectory()))
        _rows = State(initialValue: env.configs.map { Row(config: $0, exclusions: $0.exclusions.joined(separator: "\n")) })
        _host = State(initialValue: c.host)
        _port = State(initialValue: c.port)
        _user = State(initialValue: c.user)
        _minutes = State(initialValue: max(1, c.intervalSeconds / 60))
    }

    var body: some View {
        Form {
            Section("Storage Box") {
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("Benutzer", text: $user)
                SecureField("Passwort (leer = unverändert)", text: $password)
                if Keychain.hasPassword(account: Keychain.account(host: host, user: user)) {
                    Text("Passwort im Schlüsselbund gespeichert").font(.caption).foregroundStyle(.secondary)
                }
                Stepper("Intervall: \(minutes) Min", value: $minutes, in: 1...240)
            }
            ForEach($rows) { $row in
                Section("Ordner") {
                    HStack {
                        Text(row.config.syncFolder.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Wählen…") { if let u = chooseFolder(row.config.syncFolder) { row.config.syncFolder = u } }
                    }
                    TextField("Ordner auf der Box (leer = Hauptordner)", text: $row.config.remoteRoot)
                    Text("Ausschlüsse (ein Muster pro Zeile)").font(.caption)
                    TextEditor(text: $row.exclusions).font(.body.monospaced()).frame(height: 70)
                    if rows.count > 1 {
                        Button("Diesen Ordner entfernen", role: .destructive) { rows.removeAll { $0.id == row.id } }
                    }
                }
            }
            Button("Ordner hinzufügen…") { addRow() }
            Section {
                Toggle("Beim Login starten", isOn: Binding(get: { env.launchAtLogin }, set: env.setLaunchAtLogin))
                Toggle("Benachrichtigungen bei Fehlern/Konflikten",
                       isOn: Binding(get: { env.notificationsEnabled }, set: { env.notificationsEnabled = $0 }))
            }
            if let e = env.settingsError { Text(e).foregroundStyle(.red) }
            Button("Sichern und neu starten") { save() }.keyboardShortcut(.defaultAction)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }

    private func chooseFolder(_ start: URL?) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = start
        return p.runModal() == .OK ? p.url : nil
    }

    private func addRow() {
        guard let u = chooseFolder(nil) else { return }
        let c = Config(syncFolder: u, remoteRoot: u.lastPathComponent)
        rows.append(Row(config: c, exclusions: c.exclusions.joined(separator: "\n")))
    }

    private func save() {
        let configs = rows.map { r -> Config in
            var c = r.config
            c.host = host; c.port = port; c.user = user
            c.intervalSeconds = minutes * 60
            c.remoteRoot = c.remoteRoot.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            c.exclusions = r.exclusions.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return c
        }
        env.apply(configs, password: password)
        password = ""
    }
}
