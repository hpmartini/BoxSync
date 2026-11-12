import Foundation
import Security

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Schlüsselbund: \(SecCopyErrorMessageString(status, nil) as String? ?? "Fehler") (\(status))" }
}

/// Password and host-key storage in the data protection Keychain, shared by app and extension through one keychain
/// access group (needs the provisioning profile Xcode creates for the team).
/// Never logs or returns the secret anywhere but to the caller of `password`.
public enum Keychain {
    static let service = "de.martini-labs.BoxSync"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: AppGroup.keychainGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    /// Keychain account of a connection.
    public static func account(_ c: Config) -> String { "\(c.user)@\(c.host)" }

    public static func password(for c: Config) -> String? {
        var q = query(account(c))
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func hasPassword(for c: Config) -> Bool {
        var q = query(account(c))
        q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// Throws when the Keychain refused (the caller shows the error).
    public static func setPassword(_ password: String, for c: Config) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(account(c)) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query(account(c))
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    // Pinned SSH host keys (public data, stored next to the password).
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
    static func pinHostKey(_ key: String, host: String, port: Int) -> Bool {
        var add = query(hostKeyAccount(host, port))
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// Keychain-backed pin store for the SFTP host key (trust on first use).
public struct KeychainHostKeys: HostKeyStore {
    public init() {}
    public func pinnedKey(host: String, port: Int) throws -> String? {
        do { return try Keychain.hostKey(host: host, port: port) }
        catch { throw HostKeyStoreUnavailable(host: host, detail: error.localizedDescription) }
    }
    public func pin(_ key: String, host: String, port: Int) -> Bool { Keychain.pinHostKey(key, host: host, port: port) }
}
