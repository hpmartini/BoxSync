import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Persistence for pinned host keys (the app backs it with the Keychain). Keys are OpenSSH public-key lines.
public protocol HostKeyStore: Sendable {
    /// nil = nothing pinned yet (a first connect). Throws when the store cannot answer, for example a denied or locked
    /// Keychain: that must never look like "nothing pinned", the connection is refused instead.
    func pinnedKey(host: String, port: Int) throws -> String?
    /// Returns false when the key could not be stored; the connection is then refused.
    func pin(_ key: String, host: String, port: Int) -> Bool
}

public struct HostKeyMismatch: Error, LocalizedError, Equatable {
    public let host: String
    public var errorDescription: String? {
        "Host-Schlüssel von \(host) weicht vom gespeicherten ab. Verbindung abgebrochen (möglicher Angriff oder neuer Server). Zum Erneuern den Eintrag im Schlüsselbund löschen."
    }
}

public struct HostKeyNotStored: Error, LocalizedError, Equatable {
    public let host: String
    public var errorDescription: String? { "Host-Schlüssel von \(host) konnte nicht im Schlüsselbund gespeichert werden. Verbindung abgebrochen." }
}

/// The store could not be read (denied or locked Keychain). Not the same as "nothing pinned".
public struct HostKeyStoreUnavailable: Error, LocalizedError, Equatable {
    public let host: String
    public let detail: String
    public init(host: String, detail: String) { self.host = host; self.detail = detail }
    public var errorDescription: String? {
        "Gespeicherter Host-Schlüssel von \(host) ist nicht lesbar (\(detail)). Verbindung abgebrochen, damit kein vorhandener Schlüssel ersetzt wird."
    }
}

enum HostKeyTrust {
    /// Trust on first use as a pure decision: throws when the connection must be refused.
    static func check(presented: String, host: String, port: Int, store: HostKeyStore) throws {
        guard let pinned = try store.pinnedKey(host: host, port: port) else {
            guard store.pin(presented, host: host, port: port) else { throw HostKeyNotStored(host: host) }
            return
        }
        if pinned != presented { throw HostKeyMismatch(host: host) }
    }
}

/// Trust on first use: the first key seen is pinned, every later connection must present the same key.
struct TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    let host: String
    let port: Int
    let store: HostKeyStore

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            try HostKeyTrust.check(presented: String(openSSHPublicKey: hostKey), host: host, port: port, store: store)
            validationCompletePromise.succeed(())
        } catch { validationCompletePromise.fail(error) }
    }
}

extension SSHHostKeyValidator {
    static func pinned(host: String, port: Int, store: HostKeyStore) -> SSHHostKeyValidator {
        .custom(TOFUHostKeyValidator(host: host, port: port, store: store))
    }
}
