import Foundation

/// Remote side (SFTP). Paths are relative to the SFTP home, no leading slash.
/// Implementations must keep the original remote spelling (NFC/NFD) for every call.
public protocol RemoteFileSystem: Sendable {
    /// Direct children only (no "." / ".."), keyed by their full path.
    func list(_ dir: RelativePath) async throws -> [RelativePath: FileMeta]
    func stat(_ path: RelativePath) async throws -> FileMeta?
    /// Reads from `offset` into `localURL` (resume = size of the partial file). Appends.
    func read(_ path: RelativePath, offset: UInt64, to localURL: URL,
              progress: @Sendable (UInt64) -> Void) async throws
    /// Writes from `localURL` starting at `offset` (resume = remote size). Offset 0 truncates.
    func write(_ path: RelativePath, from localURL: URL, offset: UInt64,
               progress: @Sendable (UInt64) -> Void) async throws
    /// SFTP v3 does not overwrite: the target must not exist.
    func rename(_ from: RelativePath, to: RelativePath) async throws
    /// File or empty directory.
    func remove(_ path: RelativePath) async throws
    /// Idempotent: existing directory is fine.
    func mkdir(_ path: RelativePath) async throws
    func setModificationDate(_ path: RelativePath, to date: Date) async throws
    func close() async
}

extension RemoteFileSystem {
    /// `mkdir -p`.
    public func mkdirAll(_ path: RelativePath) async throws {
        var prefix = ""
        for comp in path.raw.split(separator: "/") {
            prefix += (prefix.isEmpty ? "" : "/") + comp
            try await mkdir(RelativePath(prefix))
        }
    }
}
