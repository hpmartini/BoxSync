import Foundation
import FileProvider
import AppKit
import UserNotifications
import ServiceManagement
import BoxSyncCore

/// Menu bar side of the drive: settings, the File Provider domain, the periodic refresh and the status display.
/// All Box work happens in the extension.
@MainActor
final class AppEnvironment: ObservableObject {
    @Published private(set) var config: Config
    @Published private(set) var status = ProviderStatus()
    @Published var settingsError: String?
    @Published private(set) var driveURL: URL?
    private var timer: Timer?
    private var seenErrors = Set<UUID>()
    private var seenConflicts = Set<UUID>()

    static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("box"), displayName: "BoxSync")
    private static let notifyKey = "notify"

    init() {
        config = Demo.enabled ? Demo.config : (SharedSettings.load() ?? Self.migrateLegacySettings())
        if Demo.enabled { status = Demo.status; return }
        status = SharedStatus.load()
        seenErrors = Set(status.errors.map(\.id)); seenConflicts = Set(status.conflicts.map(\.id))
        observeStatus()
        if Self.canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        Task { await startDrive() }
    }

    var isReady: Bool { config.isComplete && Keychain.hasPassword(for: config) }

    // MARK: Drive

    /// Registers the domain, links it into the home folder and starts the refresh timer. A domain built for another
    /// Box (or by an older build) is removed first; macOS keeps local edits that never reached the Box.
    private func startDrive() async {
        guard isReady else { return }
        do {
            let builtFor = AppGroup.defaults.string(forKey: AppGroup.domainIdentityKey)
            let registered = try await NSFileProviderManager.domains().contains { $0.identifier == Self.domain.identifier }
            if registered && builtFor != config.identity {
                if let kept = try await NSFileProviderManager.remove(Self.domain, mode: .preserveDirtyUserData) {
                    settingsError = "Nicht hochgeladene Änderungen des alten Laufwerks liegen in \(kept.path)."
                }
                if let builtFor, let url = AppGroup.indexURL(identity: builtFor) {
                    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
                }
                SharedStatus.update { $0 = ProviderStatus() }
            }
            try await NSFileProviderManager.add(Self.domain)
            AppGroup.defaults.set(config.identity, forKey: AppGroup.domainIdentityKey)
            await linkDrive()
            scheduleRefresh()
            refreshNow()
        } catch {
            settingsError = "Laufwerk konnte nicht angelegt werden: \(error.localizedDescription)"
        }
    }

    /// Asks the extension to compare the folders macOS has seen with the Box.
    func refreshNow() {
        guard isReady, !Demo.enabled else { return }
        NSFileProviderManager(for: Self.domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(60, config.intervalSeconds)), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    /// `config.localPath` becomes a symbolic link to the drive. An existing link is replaced, an empty folder too;
    /// anything else stays and is reported.
    private func linkDrive() async {
        guard let manager = NSFileProviderManager(for: Self.domain),
              let root = try? await manager.getUserVisibleURL(for: .rootContainer) else { return }
        driveURL = root
        let link = config.localURL
        let fm = FileManager.default
        if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if dest == root.path { return }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            guard (try? fm.contentsOfDirectory(atPath: link.path))?.isEmpty == true else {
                settingsError = "\(link.path) existiert und ist nicht leer. Das Laufwerk liegt unter \(root.path) (Finder: Seitenleiste „BoxSync“)."
                return
            }
            try? fm.removeItem(at: link)
        }
        do { try fm.createSymbolicLink(at: link, withDestinationURL: root) }
        catch { settingsError = "Verweis \(link.path) nicht anlegbar: \(error.localizedDescription)" }
    }

    /// Removes a link this app created at `path`.
    private func unlink(_ path: String) {
        let u = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: u.path),
              dest == driveURL?.path else { return }
        try? FileManager.default.removeItem(at: u)
    }

    func openInFinder() {
        if let u = driveURL { NSWorkspace.shared.open(u) }
    }

    /// Shows a Box path (as the extension reports it) in Finder: the file if it is there, else its folder.
    func reveal(_ boxPath: String) {
        guard let root = driveURL else { return }
        let u = root.appendingPathComponent(boxPath)
        if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        else { NSWorkspace.shared.open(u.deletingLastPathComponent()) }
    }

    // MARK: Settings

    /// Saves the settings. Another Box (host, port or user) rebuilds the drive from scratch (see `startDrive`).
    func apply(_ new: Config, password: String) async -> Bool {
        guard new.isComplete else { settingsError = "Host und Benutzer fehlen."; return false }
        if !password.isEmpty {
            do { try Keychain.setPassword(password, for: new) }
            catch { settingsError = "Schlüsselbund hat das Passwort abgelehnt: \(error.localizedDescription)"; return false }
        }
        guard Keychain.hasPassword(for: new) else { settingsError = "Passwort fehlt."; return false }
        settingsError = nil
        let old = config
        config = new
        SharedSettings.save(new)
        if old.localPath != new.localPath || old.identity != new.identity { unlink(old.localPath) }
        await startDrive()
        return settingsError == nil
    }

    /// One-time: host, port, user, interval and local folder from the folder-pair settings of the mirror version.
    private static func migrateLegacySettings() -> Config {
        struct Legacy: Decodable { var host: String; var port: Int; var user: String; var intervalSeconds: Int; var syncFolder: URL }
        var c = Config()
        if let d = UserDefaults.standard.data(forKey: "pairs.v1"), let l = (try? JSONDecoder().decode([Legacy].self, from: d))?.first {
            c = Config(host: l.host, port: l.port, user: l.user, intervalSeconds: l.intervalSeconds,
                       localPath: (l.syncFolder.path as NSString).abbreviatingWithTildeInPath)
            SharedSettings.save(c)
        }
        return c
    }

    // MARK: Status from the extension

    private func observeStatus() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let me = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(center, me, { _, observer, _, _, _ in
            guard let observer else { return }
            let env = Unmanaged<AppEnvironment>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in env.reloadStatus() }
        }, AppGroup.statusChanged as CFString, nil, .deliverImmediately)
    }

    func reloadStatus() {
        let s = SharedStatus.load()
        let newErrors = s.errors.filter { seenErrors.insert($0.id).inserted }
        let newConflicts = s.conflicts.filter { seenConflicts.insert($0.id).inserted }
        status = s
        guard notificationsEnabled, Self.canNotify else { return }
        for e in newErrors { post("BoxSync Fehler", "\(e.path.map { "\($0): " } ?? "")\(e.message)") }
        for c in newConflicts { post("BoxSync Konflikt", c.copy) }
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

    private static var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func post(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
