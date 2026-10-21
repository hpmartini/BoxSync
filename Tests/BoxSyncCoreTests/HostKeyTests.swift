import Foundation
import Testing
@testable import BoxSyncCore

// Host key pinning against the real Box (read-only: connect and close, nothing is written there).
// Without BOXSYNC_TEST_HOST, _USER and _PASSWORD the tests are skipped.

private let password = TestBox.password

@Suite("Host key pinning", .enabled(if: TestBox.configured, "BOXSYNC_TEST_HOST/_USER/_PASSWORD not set"))
struct HostKeyTests {
    let cfg = Config(syncFolder: URL(fileURLWithPath: "/private/tmp/boxsync-hostkey-unused"), host: TestBox.host, user: TestBox.user)

    private func connect(_ keys: HostKeyStore) async throws {
        let r = try await SFTPRemoteFileSystem.connect(host: cfg.host, port: cfg.port, user: cfg.user, password: password ?? "", hostKeys: keys)
        await r.close()
    }

    @Test func firstConnectPinsThenSameKeyIsAccepted() async throws {
        let keys = MemoryHostKeys()
        #expect(keys.pinnedKey(host: cfg.host, port: cfg.port) == nil)
        try await connect(keys)
        let pinned = try #require(keys.pinnedKey(host: cfg.host, port: cfg.port))
        #expect(pinned.hasPrefix("ssh-") || pinned.hasPrefix("ecdsa-"))
        try await connect(keys)
        #expect(keys.pinnedKey(host: cfg.host, port: cfg.port) == pinned)
    }

    @Test func changedKeyIsRefused() async throws {
        let keys = MemoryHostKeys()
        try await connect(keys)
        // Pin a different (valid but foreign) key, as a MITM would present.
        let foreign = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        _ = keys.pin(foreign, host: cfg.host, port: cfg.port)
        await #expect(throws: (any Error).self) { try await connect(keys) }
        #expect(keys.pinnedKey(host: cfg.host, port: cfg.port) == foreign) // a refused key must not overwrite the pin
    }

    @Test func storeFailureRefusesConnection() async throws {
        struct Failing: HostKeyStore {
            func pinnedKey(host: String, port: Int) -> String? { nil }
            func pin(_ key: String, host: String, port: Int) -> Bool { false }
        }
        await #expect(throws: (any Error).self) { try await connect(Failing()) }
    }
}
