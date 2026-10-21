import Foundation
import BoxSyncCore
import Security

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Schlüsselbund: \(SecCopyErrorMessageString(status, nil) as String? ?? "Fehler") (\(status))" }
}

/// Password storage. Never logs or returns the secret anywhere but to the caller of `read`.
enum Keychain {
    static let service = "de.martini-labs.BoxSync"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func hasPassword(account: String) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Returns false when the keychain refused (caller shows an error).
    @discardableResult
    static func write(_ password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var add = query(account)
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Keychain account for a connection; the real engine must use the same.
    static func account(host: String, user: String) -> String { "\(user)@\(host)" }

    // Pinned SSH host keys (public data, stored as generic password items so they live next to the password).
    private static func hostKeyAccount(_ host: String, _ port: Int) -> String { "hostkey:\(host):\(port)" }

    /// nil only when no pin exists; any other failure (denied, locked) throws so it can never pass as a first connect.
    static func hostKey(host: String, port: Int) throws -> String? {
        var q = query(hostKeyAccount(host, port))
        q[kSecReturnData as String] = true
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data else { throw KeychainError(status: status) }
        return String(data: d, encoding: .utf8)
    }
    /// Add-only: an existing pin is never replaced, not even when `hostKey` failed to read it (a locked or broken Keychain
    /// would otherwise look like a first connect). A duplicate makes this return false and the connection is refused.
    @discardableResult
    static func pinHostKey(_ key: String, host: String, port: Int) -> Bool {
        var add = query(hostKeyAccount(host, port))
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Keychain-backed pin store for the SFTP host key (trust on first use).
struct KeychainHostKeys: HostKeyStore {
    func pinnedKey(host: String, port: Int) throws -> String? {
        do { return try Keychain.hostKey(host: host, port: port) }
        catch { throw HostKeyStoreUnavailable(host: host, detail: error.localizedDescription) }
    }
    func pin(_ key: String, host: String, port: Int) -> Bool { Keychain.pinHostKey(key, host: host, port: port) }
}
