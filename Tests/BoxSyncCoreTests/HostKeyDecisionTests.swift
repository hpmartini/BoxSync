import Foundation
import Testing
@testable import BoxSyncCore

// The trust-on-first-use decision without any network: what happens for every answer the key store can give.

private final class FakeStore: HostKeyStore, @unchecked Sendable {
    enum Mode { case empty, pinned(String), unreadable, cannotWrite }
    let mode: Mode
    private(set) var pins: [String] = []
    init(_ mode: Mode) { self.mode = mode }

    struct Denied: Error, LocalizedError { var errorDescription: String? { "denied (-25293)" } }

    func pinnedKey(host: String, port: Int) throws -> String? {
        switch mode {
        case .empty, .cannotWrite: nil
        case .pinned(let k): k
        case .unreadable: throw HostKeyStoreUnavailable(host: host, detail: Denied().localizedDescription)
        }
    }
    func pin(_ key: String, host: String, port: Int) -> Bool {
        if case .cannotWrite = mode { return false }
        pins.append(key); return true
    }
}

private func check(_ store: FakeStore, presented: String = "ssh-ed25519 AAAA-new") throws {
    try HostKeyTrust.check(presented: presented, host: "box.example", port: 23, store: store)
}

@Test func firstConnectPinsThePresentedKey() throws {
    let s = FakeStore(.empty)
    try check(s)
    #expect(s.pins == ["ssh-ed25519 AAAA-new"])
}

@Test func samePinnedKeyIsAcceptedWithoutWriting() throws {
    let s = FakeStore(.pinned("ssh-ed25519 AAAA-new"))
    try check(s)
    #expect(s.pins.isEmpty)
}

@Test func changedKeyIsRefusedAndNeverReplacesThePin() {
    let s = FakeStore(.pinned("ssh-ed25519 AAAA-old"))
    #expect(throws: HostKeyMismatch.self) { try check(s) }
    #expect(s.pins.isEmpty)
}

@Test func unreadableStoreRefusesTheConnectionAndNeverPins() {
    // A denied or locked Keychain is not a first connect: pinning now could replace the trusted key.
    let s = FakeStore(.unreadable)
    #expect(throws: HostKeyStoreUnavailable.self) { try check(s) }
    #expect(s.pins.isEmpty)
}

@Test func failedPinRefusesTheConnection() {
    #expect(throws: HostKeyNotStored.self) { try check(FakeStore(.cannotWrite)) }
}

@Test func unavailableMessageCarriesTheReason() {
    let msg = HostKeyStoreUnavailable(host: "box.example", detail: "denied (-25293)").errorDescription ?? ""
    #expect(msg.contains("box.example") && msg.contains("-25293"))
}
