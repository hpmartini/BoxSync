import Foundation
import Combine
import UserNotifications
import ServiceManagement
import BoxSyncCore

/// One sync pair (local folder <-> Box folder) with its own engine, state file and status.
@MainActor
final class SyncPair: Identifiable {
    let config: Config
    let state = SyncState()
    let engine: SyncEngine
    nonisolated let id: String
    var name: String { config.displayName }

    init(config: Config) {
        self.config = config
        id = config.stateID
        engine = AppEnvironment.makeEngine(config: config, state: state)
    }
}

@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var pairs: [SyncPair] = []
    @Published var settingsError: String?
    private var bag = Set<AnyCancellable>()
    private var seenErrors = Set<UUID>()
    private var seenConflicts = Set<UUID>()

    private static let legacyConfigKey = "config.v1"
    private static let pairsKey = "pairs.v1"
    private static let notifyKey = "notify"

    /// The ONE place that decides which engine runs. Password comes from the Keychain (empty => visible auth error).
    static func makeEngine(config: Config, state: SyncState) -> SyncEngine {
        let password = Keychain.read(account: Keychain.account(host: config.host, user: config.user)) ?? ""
        let onStatus: @Sendable (SyncStatus) -> Void = { s in Task { @MainActor in state.status = s } }
        if Demo.enabled { return DemoEngine(status: Demo.status(for: config), onStatus: onStatus) }
        do {
            return BoxSyncEngine.sftp(config: config, password: password, store: try JSONStateStore(url: JSONStateStore.url(for: config)), hostKeys: KeychainHostKeys(), onStatus: onStatus)
        } catch {
            return FailedEngine(message: "Zustandsdatei: \(error.localizedDescription)", onStatus: onStatus)
        }
    }

    init() {
        pairs = Self.loadConfigs().map(SyncPair.init)
        observePairs()
        if Self.canNotify {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        for p in pairs { Task { [engine = p.engine] in await engine.start() } }
    }

    var configs: [Config] { pairs.map(\.config) }

    /// Status changes of any pair redraw the menu and may raise notifications.
    private func observePairs() {
        bag.removeAll()
        for p in pairs {
            p.state.$status.sink { [weak self, name = p.name] s in
                self?.notifyNew(s, pair: name)
                self?.objectWillChange.send()
            }.store(in: &bag)
        }
    }

    // MARK: Commands (nil = all pairs)
    func syncNow(_ p: SyncPair? = nil) { each(p) { await $0.syncNow() } }
    func checkNow(_ p: SyncPair? = nil) { each(p) { await $0.checkNow() } }
    func approveFirstSync(_ p: SyncPair) { each(p) { await $0.approveFirstSync() } }

    private func each(_ p: SyncPair?, _ f: @escaping @Sendable (SyncEngine) async -> Void) {
        for engine in (p.map { [$0] } ?? pairs).map(\.engine) { Task { await f(engine) } }
    }

    var allPaused: Bool { !pairs.isEmpty && pairs.allSatisfy { $0.state.status.phase == .paused } }

    func togglePause() {
        let resume = allPaused
        each(nil) { resume ? await $0.resume() : await $0.pause() }
    }

    /// Persist new settings and restart all engines with them.
    func apply(_ new: [Config], password: String?) {
        guard let first = new.first else { settingsError = "Mindestens ein Ordner nötig."; return }
        guard Set(new.map(\.stateID)).count == new.count else { settingsError = "Zwei Einträge zeigen auf denselben Ordner."; return }
        if let password, !password.isEmpty,
           !Keychain.write(password, account: Keychain.account(host: first.host, user: first.user)) {
            settingsError = "Schlüsselbund hat das Passwort abgelehnt."
            return
        }
        settingsError = nil
        if !Demo.enabled, let data = try? JSONEncoder().encode(new) { UserDefaults.standard.set(data, forKey: Self.pairsKey) }
        let old = pairs.map(\.engine)
        pairs = new.map(SyncPair.init)
        observePairs()
        let fresh = pairs.map(\.engine)
        Task {
            for e in old { await e.stop() }
            for e in fresh { await e.start() }
        }
    }

    // MARK: Login item
    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settingsError = nil
        } catch {
            settingsError = "Start bei Login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    // MARK: Notifications
    var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.notifyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.notifyKey); objectWillChange.send() }
    }

    /// UNUserNotificationCenter traps outside an app bundle (e.g. `swift run`).
    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func notifyNew(_ s: SyncStatus, pair: String) {
        let newErrors = s.errors.filter { seenErrors.insert($0.id).inserted }
        let newConflicts = s.conflicts.filter { seenConflicts.insert($0.id).inserted }
        guard notificationsEnabled, Self.canNotify else { return }
        for e in newErrors { post("BoxSync Fehler · \(pair)", e.message) }
        for c in newConflicts { post("BoxSync Konflikt · \(pair)", c.copy) }
    }

    private func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    /// `pairs.v1`, else the single pre-multi-pair `config.v1`, else the default folder.
    static func loadConfigs() -> [Config] {
        if Demo.enabled { return Demo.configs }
        let d = UserDefaults.standard
        if let data = d.data(forKey: pairsKey), let c = try? JSONDecoder().decode([Config].self, from: data), !c.isEmpty { return c }
        if let data = d.data(forKey: legacyConfigKey), let c = try? JSONDecoder().decode(Config.self, from: data) { return [c] }
        return [Config(syncFolder: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("BoxSync"))]
    }
}

/// Reports a start-up failure as a visible error instead of crashing.
private struct FailedEngine: SyncEngine {
    let message: String
    let onStatus: @Sendable (SyncStatus) -> Void
    func start() async {
        var s = SyncStatus(); s.phase = .error; s.errors = [SyncIssue(message: message)]
        onStatus(s)
    }
    func pause() async {}
    func resume() async {}
    func syncNow() async { await start() }
    func checkNow() async { await start() }
    func approveFirstSync() async { await start() }
    func stop() async {}
}
