import Foundation

/// Connection data for the Box integration tests, taken from the environment so that no account data lives in the repo.
/// Without all three variables the tests that need a Box are skipped.
enum TestBox {
    private static let env = ProcessInfo.processInfo.environment
    static let host = env["BOXSYNC_TEST_HOST"] ?? ""
    static let user = env["BOXSYNC_TEST_USER"] ?? ""
    static let password = env["BOXSYNC_TEST_PASSWORD"]
    static var configured: Bool { !host.isEmpty && !user.isEmpty && password != nil }
}
