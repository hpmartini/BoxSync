import CryptoKit
import Foundation

/// The settings are incomplete or the password is missing: the user has to open the settings.
public struct NotConfigured: Error, LocalizedError, CustomStringConvertible {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var description: String { detail }
    public var errorDescription: String? { detail }
}

/// What a connection needs; `fingerprint` changes when the Box or the password changes.
public struct Credentials: Sendable {
    public var config: Config
    public var password: String
    public init(config: Config, password: String) { self.config = config; self.password = password }
    var fingerprint: String {
        SHA256.hash(data: Data("\(config.identity)\u{1F}\(password)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One shared SSH connection to the Box, opened on first use and reopened after it dropped.
///
/// The Box blocks an address for a while after too many connection attempts, so failed connects are not retried
/// right away: after a refused or failed connect, further attempts wait 30 s, doubling up to 15 min. A rejected
/// login is not retried at all until the settings or the password change.
public actor BoxSession {
    public typealias Open = @Sendable (Credentials) async throws -> SFTPRemoteFileSystem
    public typealias Load = @Sendable () throws -> Credentials
    private let load: Load
    private let open: Open
    private let now: @Sendable () -> Date
    private var current: SFTPRemoteFileSystem?
    private var connecting: Task<SFTPRemoteFileSystem, Error>?
    private var lastFailure: (fingerprint: String, error: Error, retryAt: Date?)?   // retryAt nil: wait for new credentials
    private var backoff: TimeInterval = 0

    static let firstBackoff: TimeInterval = 30
    static let maxBackoff: TimeInterval = 900

    public init(load: @escaping Load, open: @escaping Open, now: @escaping @Sendable () -> Date = { Date() }) {
        self.load = load; self.open = open; self.now = now
    }

    /// Connects with the shared settings, the shared Keychain password and the pinned host key.
    public static func shared() -> BoxSession {
        BoxSession(load: {
            guard let c = SharedSettings.load(), c.isComplete else { throw NotConfigured("BoxSync ist noch nicht eingerichtet (Einstellungen).") }
            guard let pw = Keychain.password(for: c), !pw.isEmpty else { throw NotConfigured("Kein Passwort gespeichert (Einstellungen).") }
            return Credentials(config: c, password: pw)
        }, open: { cr in
            try await SFTPRemoteFileSystem.connect(host: cr.config.host, port: cr.config.port, user: cr.config.user,
                                                   password: cr.password, hostKeys: KeychainHostKeys())
        })
    }

    /// Runs `op` on the connection. A connection found dead afterwards is dropped (the next call reconnects); with
    /// `idempotent` (reads only) `op` then runs once more on a new connection. Writes are never repeated: a write
    /// that reached the Box before the connection broke would otherwise run twice.
    public func run<T: Sendable>(idempotent: Bool = false, _ op: @Sendable (SFTPRemoteFileSystem) async throws -> T) async throws -> T {
        let r = try await remote()
        do {
            return try await op(r)
        } catch where !r.isConnected && !(error is CancellationError) {
            drop(r)
            guard idempotent else { throw error }
            return try await op(try await remote())
        }
    }

    public func close() async {
        let r = current
        current = nil
        await r?.close()
    }

    private func remote() async throws -> SFTPRemoteFileSystem {
        if let c = current, c.isConnected { return c }
        if let c = current { drop(c) }
        if let t = connecting { return try await t.value }
        let creds = try load()
        let fp = creds.fingerprint
        if let f = lastFailure, f.fingerprint == fp, f.retryAt.map({ now() < $0 }) ?? true { throw f.error }
        let t = Task { [open] in try await open(creds) }
        connecting = t
        defer { connecting = nil }
        do {
            let r = try await t.value
            current = r
            lastFailure = nil
            backoff = 0
            return r
        } catch {
            if BoxErrors.kind(error) == .notAuthenticated {
                lastFailure = (fp, error, nil)
            } else {
                backoff = min(Self.maxBackoff, max(Self.firstBackoff, backoff * 2))
                lastFailure = (fp, error, now().addingTimeInterval(backoff))
            }
            throw error
        }
    }

    private func drop(_ r: SFTPRemoteFileSystem) {
        guard current === r else { return }
        current = nil
        Task { await r.close() }
    }
}
