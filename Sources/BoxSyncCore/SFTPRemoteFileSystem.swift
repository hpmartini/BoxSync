import Citadel
import Foundation
import NIOCore

private struct UncheckedFile: @unchecked Sendable { let file: SFTPFile }

/// Citadel adapter. One connection per sync run (listDirectory leaks a directory handle per call,
/// closing the session releases them). Credentials come in as parameters; Keychain is the app's job.
public final class SFTPRemoteFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let ssh: SSHClient
    private let sftp: SFTPClient

    /// Write/read window: 16 requests of one SFTP block each run concurrently; a batch finishes before the next starts.
    static let block = 32_000
    static let window = 16
    /// Batch size, also the granularity of the resume offset (see `resumeOffset`).
    public static let batchBytes = block * window

    private init(ssh: SSHClient, sftp: SFTPClient) { self.ssh = ssh; self.sftp = sftp }

    /// Wrong password throws Citadel's `allAuthenticationOptionsFailed`.
    /// The host key is pinned on first use via `hostKeys` and must match on every later connection.
    public static func connect(host: String, port: Int, user: String, password: String,
                               hostKeys: HostKeyStore) async throws -> SFTPRemoteFileSystem {
        let ssh = try await SSHClient.connect(to: SSHClientSettings(
            host: host, port: port,
            authenticationMethod: { .passwordBased(username: user, password: password) },
            hostKeyValidator: .pinned(host: host, port: port, store: hostKeys)))
        do {
            return SFTPRemoteFileSystem(ssh: ssh, sftp: try await ssh.openSFTP())
        } catch {
            try? await ssh.close()
            throw error
        }
    }

    public func close() async {
        try? await sftp.close()
        try? await ssh.close()
    }

    /// Resume point for an interrupted upload: start of the batch that holds the last byte on the Box.
    /// Writes inside a batch complete out of order, so only earlier batches are known complete.
    public static func resumeOffset(remoteSize: UInt64) -> UInt64 {
        remoteSize == 0 ? 0 : (remoteSize - 1) / UInt64(batchBytes) * UInt64(batchBytes)
    }

    private func p(_ path: RelativePath) -> String { path.raw.isEmpty ? "." : path.raw }

    private static func isNoSuchFile(_ error: Error) -> Bool {
        if let s = error as? SFTPMessage.Status { return s.errorCode == .noSuchFile }
        if case SFTPError.errorStatus(let s) = error { return s.errorCode == .noSuchFile }
        return false
    }

    private static func meta(_ a: SFTPFileAttributes, longname: String = "") -> (FileMeta, isRegular: Bool) {
        let fmt = (a.permissions ?? 0) & 0o170000
        let isDir = a.permissions != nil ? fmt == 0o040000 : longname.hasPrefix("d")
        let isRegular = a.permissions != nil ? fmt == 0o100000 : longname.hasPrefix("-")
        return (FileMeta(size: a.size ?? 0, mtime: a.accessModificationTime?.modificationTime ?? Date(timeIntervalSince1970: 0),
                         isDirectory: isDir), isRegular)
    }

    public func list(_ dir: RelativePath) async throws -> [RelativePath: FileMeta] {
        var out: [RelativePath: FileMeta] = [:]
        for c in try await sftp.listDirectory(atPath: p(dir)).flatMap(\.components) where c.filename != "." && c.filename != ".." {
            // A Box name with "/" or NUL would escape its folder locally; abort the run (nothing is deleted on a partial listing).
            guard !c.filename.isEmpty, !c.filename.contains("/"), !c.filename.contains("\0") else { throw UnsafePath(path: dir.raw + "/" + c.filename) }
            let (m, regular) = Self.meta(c.attributes, longname: c.longname)
            guard m.isDirectory || regular else { continue }   // symlinks, specials: not synced
            out[RelativePath(dir.raw.isEmpty ? c.filename : dir.raw + "/" + c.filename)] = m
        }
        return out
    }

    public func stat(_ path: RelativePath) async throws -> FileMeta? {
        do { return Self.meta(try await sftp.getAttributes(at: p(path))).0 }
        catch where Self.isNoSuchFile(error) { return nil }
    }

    public func mkdir(_ path: RelativePath) async throws {
        if let m = try await stat(path) {
            if m.isDirectory { return }
            throw CocoaError(.fileWriteFileExists)
        }
        try await sftp.createDirectory(atPath: path.raw)
    }

    public func rename(_ from: RelativePath, to: RelativePath) async throws { try await sftp.rename(at: from.raw, to: to.raw) }

    public func remove(_ path: RelativePath) async throws {
        if try await stat(path)?.isDirectory == true { try await sftp.rmdir(at: path.raw) }
        else { try await sftp.remove(at: path.raw) }
    }

    public func setModificationDate(_ path: RelativePath, to date: Date) async throws {
        let d = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        try await sftp.setAttributes(at: path.raw, to: SFTPFileAttributes(accessModificationTime: .init(accessTime: d, modificationTime: d)))
    }

    public func write(_ path: RelativePath, from localURL: URL, offset: UInt64,
                      progress: @Sendable (UInt64) -> Void) async throws {
        let fh = try FileHandle(forReadingFrom: localURL)
        defer { try? fh.close() }
        try fh.seek(toOffset: offset)
        let file = UncheckedFile(file: try await sftp.openFile(
            filePath: path.raw, flags: offset == 0 ? [.write, .create, .truncate] : [.write]))
        do {
            var pos = offset
            while true {
                try Task.checkCancellation()
                guard let data = try fh.read(upToCount: Self.batchBytes), !data.isEmpty else { break }
                try await withThrowingTaskGroup(of: Void.self) { g in
                    var i = 0
                    while i < data.count {
                        let end = min(i + Self.block, data.count)
                        let chunk = Data(data[(data.startIndex + i)..<(data.startIndex + end)])   // fresh buffer, readerIndex 0
                        let at = pos + UInt64(i)
                        g.addTask { try await file.file.write(ByteBuffer(bytes: chunk), at: at) }
                        i = end
                    }
                    try await g.waitForAll()
                }
                pos += UInt64(data.count)
                progress(pos)
            }
        } catch {
            try? await file.file.close()
            throw error
        }
        try await file.file.close()
    }

    public func read(_ path: RelativePath, offset: UInt64, to localURL: URL,
                     progress: @Sendable (UInt64) -> Void) async throws {
        guard let size = try await stat(path)?.size else { throw CocoaError(.fileNoSuchFile) }
        if offset == 0 || !FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: localURL.path, contents: nil)
        }
        let fh = try FileHandle(forWritingTo: localURL)
        defer { try? fh.close() }
        try fh.truncate(atOffset: offset)
        try fh.seek(toOffset: offset)
        let file = UncheckedFile(file: try await sftp.openFile(filePath: path.raw, flags: .read))
        do {
            var pos = offset
            let step = 32_768   // the server returns at most this much per read
            while pos < size {
                try Task.checkCancellation()
                let reqs = (0..<Self.window).map { (pos + UInt64($0 * step), $0) }.filter { $0.0 < size }
                var bufs = [ByteBuffer?](repeating: nil, count: reqs.count)
                try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { g in
                    for (at, i) in reqs {
                        g.addTask { (i, try await file.file.read(from: at, length: UInt32(min(UInt64(step), size - at)))) }
                    }
                    for try await (i, b) in g { bufs[i] = b }
                }
                for (k, (at, _)) in reqs.enumerated() {
                    let b = bufs[k]!
                    let want = Int(min(UInt64(step), size - at))
                    if b.readableBytes == 0 { throw CocoaError(.fileReadCorruptFile) }   // unexpected EOF
                    try fh.write(contentsOf: Data(b.readableBytesView))
                    pos += UInt64(b.readableBytes)
                    if b.readableBytes < want { break }   // short read: refetch the rest from the new position
                }
                progress(pos)
            }
        } catch {
            try? await file.file.close()
            throw error
        }
        try await file.file.close()
    }
}
