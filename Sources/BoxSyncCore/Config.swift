import Foundation

/// Settings of the BoxSync drive. The password is not part of it (Keychain only).
public struct Config: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var user: String
    /// How often the app asks the extension to look for changes made elsewhere (other devices, the Box web UI).
    public var intervalSeconds: Int
    /// Where the drive is reachable in the home folder. macOS keeps the drive itself under
    /// `~/Library/CloudStorage`; this path is a symbolic link to it.
    public var localPath: String

    public static let defaultLocalPath = "~/BoxSync"

    public init(host: String = "", port: Int = 23, user: String = "", intervalSeconds: Int = 300,
                localPath: String = Config.defaultLocalPath) {
        self.host = host; self.port = port; self.user = user; self.intervalSeconds = intervalSeconds
        self.localPath = localPath
    }

    public var isComplete: Bool { !host.isEmpty && !user.isEmpty }

    /// Which Box the drive shows. A change means a different Box: the drive is rebuilt from scratch.
    public var identity: String { "\(user)@\(host):\(port)" }

    public var localURL: URL { URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath) }
}
