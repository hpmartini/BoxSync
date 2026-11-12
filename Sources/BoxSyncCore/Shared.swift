import Foundation

/// The app group shared by the menu bar app and the File Provider extension (settings, status, index, Keychain).
public enum AppGroup {
    /// Keychain access group of app and extension (entitlement `keychain-access-groups`).
    public static let keychainGroup = "B6VK6QB456.de.martini-labs.BoxSync.shared"
    public static let id = "B6VK6QB456.de.martini-labs.BoxSync"
    public static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
    }

    /// Item index of the drive for one Box (`Config.identity`); a different Box gets a different file.
    public static func indexURL(identity: String) -> URL? {
        let safe = identity.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "_" }
        return containerURL?.appendingPathComponent("index-\(String(safe)).sqlite")
    }

    /// The Box identity the registered drive was built for; another Box means the drive is rebuilt.
    public static let domainIdentityKey = "domainIdentity"

    /// Darwin notification posted whenever the extension updates `SharedStatus` (payload-free by design).
    public static let statusChanged = "\(id).status"
}

/// Settings written by the app, read by the extension when it connects.
public enum SharedSettings {
    private static let key = "config.v2"

    public static func load() -> Config? {
        guard let d = AppGroup.defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: d)
    }

    public static func save(_ c: Config) {
        if let d = try? JSONEncoder().encode(c) { AppGroup.defaults.set(d, forKey: key) }
    }
}

public struct ProviderIssue: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var path: String?
    public var message: String
    public init(date: Date = Date(), path: String? = nil, message: String) {
        self.date = date; self.path = path; self.message = message
    }
}

public struct ProviderConflict: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var original: String
    public var copy: String
    public init(date: Date = Date(), original: String, copy: String) {
        self.date = date; self.original = original; self.copy = copy
    }
}

/// What the extension reports to the app. Both processes read-modify-write it; the last writer wins, which is fine
/// for a status display.
public struct ProviderStatus: Codable, Equatable, Sendable {
    /// Last time the Box was reached and the known folders were compared with it.
    public var lastRefresh: Date?
    /// Set by a failed Box operation, cleared by the next successful refresh.
    public var currentError: ProviderIssue?
    /// Newest last, capped.
    public var errors: [ProviderIssue] = []
    public var conflicts: [ProviderConflict] = []
    public init() {}

    public static let cap = 20
    public mutating func add(_ e: ProviderIssue) {
        currentError = e
        errors.append(e); if errors.count > Self.cap { errors.removeFirst(errors.count - Self.cap) }
    }
    public mutating func add(_ c: ProviderConflict) {
        conflicts.append(c); if conflicts.count > Self.cap { conflicts.removeFirst(conflicts.count - Self.cap) }
    }
}

public enum SharedStatus {
    private static let key = "status.v1"

    public static func load() -> ProviderStatus {
        guard let d = AppGroup.defaults.data(forKey: key) else { return ProviderStatus() }
        return (try? JSONDecoder().decode(ProviderStatus.self, from: d)) ?? ProviderStatus()
    }

    public static func update(_ change: (inout ProviderStatus) -> Void) {
        var s = load()
        change(&s)
        if let d = try? JSONEncoder().encode(s) { AppGroup.defaults.set(d, forKey: key) }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(AppGroup.statusChanged as CFString), nil, nil, true)
    }
}
