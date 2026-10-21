import Citadel
import Foundation
import NIOCore
import NIOSSH

/// Persistence for pinned host keys (the app backs it with the Keychain). Keys are OpenSSH public-key lines.
public protocol HostKeyStore: Sendable {
    func pinnedKey(host: String, port: Int) -> String?
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

/// Trust on first use: the first key seen is pinned, every later connection must present the same key.
struct TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    let host: String
    let port: Int
    let store: HostKeyStore

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let presented = String(openSSHPublicKey: hostKey)
        guard let pinned = store.pinnedKey(host: host, port: port) else {
            if store.pin(presented, host: host, port: port) { validationCompletePromise.succeed(()) }
            else { validationCompletePromise.fail(HostKeyNotStored(host: host)) }
            return
        }
        if pinned == presented { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(HostKeyMismatch(host: host)) }
    }
}

extension SSHHostKeyValidator {
    static func pinned(host: String, port: Int, store: HostKeyStore) -> SSHHostKeyValidator {
        .custom(TOFUHostKeyValidator(host: host, port: port, store: store))
    }
}
