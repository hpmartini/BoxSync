import Foundation

/// Path relative to the sync root / remote home, no leading slash.
/// Equality and hashing use the raw UTF-8 bytes, so NFC and NFD spellings stay distinct
/// (the Box holds both as separate files). `logical` is the NFC form for matching across sides.
public struct RelativePath: Hashable, Sendable, Comparable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(from d: Decoder) throws { raw = try d.singleValueContainer().decode(String.self) }
    public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(raw) }

    public var logical: String { raw.precomposedStringWithCanonicalMapping }
    /// The NFC spelling as a path: the identity used to pair local and remote files.
    public var normalized: RelativePath { RelativePath(logical) }

    public static func == (a: Self, b: Self) -> Bool { a.raw.utf8.elementsEqual(b.raw.utf8) }
    public func hash(into h: inout Hasher) { for b in raw.utf8 { h.combine(b) } }
    public static func < (a: Self, b: Self) -> Bool { a.raw.utf8.lexicographicallyPrecedes(b.raw.utf8) }
}

/// Metadata of one file or directory. `mtime` has whole-second resolution (SFTP v3);
/// compare with `mtimeSeconds`, never with Date equality.
public struct FileMeta: Hashable, Sendable, Codable {
    public var size: UInt64
    public var mtime: Date
    public var isDirectory: Bool
    /// Content hash (SHA-256 hex) when known; nil if not computed yet.
    public var hash: String?

    public init(size: UInt64, mtime: Date, isDirectory: Bool = false, hash: String? = nil) {
        self.size = size; self.mtime = mtime; self.isDirectory = isDirectory; self.hash = hash
    }

    public var mtimeSeconds: Int64 { Int64(mtime.timeIntervalSince1970.rounded(.down)) }
}

/// State of one side at one point in time.
public struct Snapshot: Sendable {
    public var entries: [RelativePath: FileMeta]
    public init(entries: [RelativePath: FileMeta] = [:]) { self.entries = entries }
}

/// Last common state of one file (what both sides had after the last successful sync).
public struct StateRecord: Hashable, Sendable, Codable {
    public var path: RelativePath
    public var local: FileMeta
    public var remote: FileMeta
    public init(path: RelativePath, local: FileMeta, remote: FileMeta) {
        self.path = path; self.local = local; self.remote = remote
    }
}

/// All records of the state store; the third input of the planner.
public struct StateSnapshot: Sendable {
    public var records: [RelativePath: StateRecord]
    public init(records: [RelativePath: StateRecord] = [:]) { self.records = records }
}
