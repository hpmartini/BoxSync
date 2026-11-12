import Citadel
import Foundation
import Testing
@testable import BoxSyncCore

/// The Box blocks an address after too many connection attempts: failed connects must not be retried on every call.
struct BoxSessionTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var password = "pw"
        var clock = Date(timeIntervalSince1970: 1_000)
        func hit() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func session(_ c: Counter, failWith error: Error) -> BoxSession {
        BoxSession(load: { Credentials(config: Config(host: "h", user: "u"), password: c.password) },
                   open: { _ in _ = c.hit(); throw error },
                   now: { c.clock })
    }

    @Test func refusedConnectWaitsBeforeTheNextAttempt() async {
        let c = Counter()
        let s = session(c, failWith: CocoaError(.fileReadUnknown))   // stands in for a refused TCP connect
        for _ in 0..<5 { _ = try? await s.run { _ in 0 } }
        #expect(c.count == 1)
        c.clock += BoxSession.firstBackoff + 1
        _ = try? await s.run { _ in 0 }
        #expect(c.count == 2)
        c.clock += BoxSession.firstBackoff + 1   // second failure doubled the wait
        _ = try? await s.run { _ in 0 }
        #expect(c.count == 2)
    }

    @Test func rejectedLoginIsNotRetriedUntilThePasswordChanges() async {
        let c = Counter()
        let s = session(c, failWith: SSHClientError.allAuthenticationOptionsFailed)
        _ = try? await s.run { _ in 0 }
        c.clock += 10_000
        _ = try? await s.run { _ in 0 }
        #expect(c.count == 1)
        c.password = "new"
        _ = try? await s.run { _ in 0 }
        #expect(c.count == 2)
    }
}
