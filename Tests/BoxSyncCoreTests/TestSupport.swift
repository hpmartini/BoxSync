import Foundation
@testable import BoxSyncCore

/// Temp folder under the project, removed by `cleanup`.
struct TempDir {
    let url: URL
    init() throws {
        url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".testdata").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func file(_ name: String, _ data: Data) throws -> URL {
        let f = url.appendingPathComponent(name)
        try data.write(to: f)
        return f
    }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

final class MemoryHostKeys: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock(); private var keys: [String: String] = [:]
    func pinnedKey(host: String, port: Int) -> String? { lock.lock(); defer { lock.unlock() }; return keys["\(host):\(port)"] }
    func pin(_ key: String, host: String, port: Int) -> Bool { lock.lock(); defer { lock.unlock() }; keys["\(host):\(port)"] = key; return true }
}
