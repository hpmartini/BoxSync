import SwiftUI
import BoxSyncCore

struct SettingsView: View {
    @ObservedObject var env: AppEnvironment
    @State private var host: String
    @State private var port: Int
    @State private var user: String
    @State private var minutes: Int
    @State private var localPath: String
    @State private var password = ""
    @State private var savedNote: String?
    @State private var saving = false

    init(env: AppEnvironment) {
        self.env = env
        let c = env.config
        _host = State(initialValue: c.host)
        _port = State(initialValue: c.port)
        _user = State(initialValue: c.user)
        _minutes = State(initialValue: max(1, c.intervalSeconds / 60))
        _localPath = State(initialValue: c.localPath)
    }

    private var draft: Config {
        Config(host: host.trimmingCharacters(in: .whitespaces), port: port, user: user.trimmingCharacters(in: .whitespaces),
               intervalSeconds: minutes * 60, localPath: localPath.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        Form {
            Section("Storage Box") {
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("Benutzer", text: $user)
                SecureField("Passwort (leer = unverändert)", text: $password)
                if Keychain.hasPassword(for: draft) {
                    Text("Passwort im Schlüsselbund gespeichert").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Laufwerk") {
                TextField("Lokaler Ordner", text: $localPath)
                Text("Verweis auf das Laufwerk BoxSync (Finder-Seitenleiste). Dateien sind Platzhalter und werden beim Öffnen geladen.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Änderungen anderer Geräte holen: alle \(minutes) Min", value: $minutes, in: 1...240)
            }
            Section {
                Toggle("Beim Login starten", isOn: Binding(get: { env.launchAtLogin }, set: env.setLaunchAtLogin))
                Toggle("Benachrichtigungen bei Fehlern/Konflikten",
                       isOn: Binding(get: { env.notificationsEnabled }, set: { env.notificationsEnabled = $0 }))
            }
            if let e = env.settingsError { Text(e).foregroundStyle(.red) }
            else if let n = savedNote { Text(n).foregroundStyle(.secondary) }
            Button("Sichern") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }

    private func save() {
        saving = true
        let withPassword = !password.isEmpty
        Task {
            let ok = await env.apply(draft, password: password)
            saving = false
            guard ok else { savedNote = nil; return }   // keep the typed password for a retry
            password = ""
            let time = Date().formatted(date: .omitted, time: .shortened)
            savedNote = "Gesichert\(withPassword ? " inkl. Passwort" : "") (\(time))."
        }
    }
}
