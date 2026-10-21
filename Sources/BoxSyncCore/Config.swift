import CryptoKit
import Foundation

/// User settings. The password is not part of it (Keychain only).
public struct Config: Codable, Hashable, Sendable {
    public var syncFolder: URL
    public var host: String
    public var port: Int
    public var user: String
    /// Remote directory the sync folder maps to, relative to the SFTP home ("" = home).
    public var remoteRoot: String
    /// Glob patterns relative to the sync root.
    public var exclusions: [String]
    public var intervalSeconds: Int
    /// Remote trash, relative to `remoteRoot`; a dated subfolder is added per run.
    public var remoteTrashPath: String
    /// Local trash folder; a dated subfolder is added per run.
    public var localTrashURL: URL

    /// Short name for menus and reports: the Box folder, else the local folder name.
    public var displayName: String { remoteRoot.isEmpty ? syncFolder.lastPathComponent : remoteRoot }

    /// Identifies the sync pair; the state store is per pair, so records of another folder/Box never apply.
    public var stateID: String {
        let key = [syncFolder.standardizedFileURL.path, host, String(port), user, remoteRoot].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public init(
        syncFolder: URL,
        host: String = "",
        port: Int = 23,
        user: String = "",
        remoteRoot: String = "",
        exclusions: [String] = [".DS_Store", ".staging/**"],
        intervalSeconds: Int = 300,
        remoteTrashPath: String = "_trash",
        localTrashURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/BoxSync")
    ) {
        self.syncFolder = syncFolder; self.host = host; self.port = port; self.user = user
        self.remoteRoot = remoteRoot; self.exclusions = exclusions
        self.intervalSeconds = intervalSeconds
        self.remoteTrashPath = remoteTrashPath; self.localTrashURL = localTrashURL
    }
}
