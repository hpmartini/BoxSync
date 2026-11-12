import Citadel
import Foundation
import NIOCore

private struct UncheckedFile: @unchecked Sendable { let file: SFTPFile }

/// Citadel adapter, one SSH connection. Credentials come in as parameters.
/// Citadel's `listDirectory` never closes its directory handle, and the Box's sftp-server fails `opendir` with
/// SSH_FX_FAILURE once its descriptors run out. Listings therefore run on their own SFTP channel that is replaced
/// every `listsPerChannel` calls (closing a channel ends its server process and frees the handles). Listings are
/// serialized so a replacement never closes a channel another listing still uses; file transfers run concurrently.
public final class SFTPRemoteFileSystem: RemoteFileSystem, @unchecked Sendable {
    private let ssh: SSHClient
    private let sftp: SFTPClient
    private let listLock = AsyncLock()
    private var lister: SFTPClient?          // guarded by listLock
    private var listedOnLister = 0           // guarded by listLock
    static let listsPerChannel = 200

    /// Write/read window: 16 requests of one SFTP block each run concurrently; a batch finishes before the next starts.
    static let block = 32_000
    static let window = 16
    /// Bytes read from disk per upload batch.
    static let batchBytes = block * window

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

    /// False once the SSH connection or the main SFTP channel is gone; the session then reconnects.
    public var isConnected: Bool { sftp.isActive }

    public func close() async {
        await listLock.locked { try? await self.lister?.close() }
        try? await sftp.close()
        try? await ssh.close()
    }

    private func p(_ path: RelativePath) -> String { path.raw.isEmpty ? "." : path.raw }

    public static func isNoSuchFile(_ error: Error) -> Bool {
        if error is RemoteNotFound { return true }
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
        let listing: [SFTPMessage.Name] = try await listLock.locked {
            do {
                if self.lister?.isActive != true || self.listedOnLister >= Self.listsPerChannel {
                    try? await self.lister?.close()
                    self.lister = nil
                    self.lister = try await self.ssh.openSFTP()
                    self.listedOnLister = 0
                }
                self.listedOnLister += 1
                return try await self.lister!.listDirectory(atPath: self.p(dir))
            } catch where Self.isNoSuchFile(error) {
                throw RemoteNotFound(path: dir.raw)
            } catch {
                // A failing listing channel is not reused: the next listing opens a fresh one.
                try? await self.lister?.close()
                self.lister = nil
                throw RemoteListFailed(path: self.p(dir), detail: "\(error)")
            }
        }
        var out: [RelativePath: FileMeta] = [:]
        for c in listing.flatMap(\.components) where c.filename != "." && c.filename != ".." {
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

/// A Box name that would escape its folder locally ("/" or NUL inside a name).
public struct UnsafePath: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let path: String
    public var description: String { "Unsicherer Name auf der Box abgelehnt: \(path)" }
    public var errorDescription: String? { description }
}

/// The path does not exist on the Box.
public struct RemoteNotFound: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let path: String
    public init(path: String) { self.path = path }
    public var description: String { "Nicht mehr auf der Box: \(path)" }
    public var errorDescription: String? { description }
}

/// A Box folder could not be listed; names the folder, the SFTP status alone says nothing.
public struct RemoteListFailed: Error, LocalizedError, CustomStringConvertible, Equatable {
    public let path: String
    public let detail: String
    public var description: String { "Box-Ordner nicht lesbar: \(path) (\(detail))" }
    public var errorDescription: String? { description }
}

/// FIFO mutual exclusion across suspension points (an actor would interleave at every await).
final class AsyncLock: @unchecked Sendable {
    private let mutex = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func locked<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            mutex.lock()
            if busy { waiters.append(c); mutex.unlock() } else { busy = true; mutex.unlock(); c.resume() }
        }
    }

    private func release() {
        mutex.lock()
        if waiters.isEmpty { busy = false; mutex.unlock() } else { let next = waiters.removeFirst(); mutex.unlock(); next.resume() }
    }
}
