import Foundation

/// Path relative to the SFTP home, no leading slash.
/// Equality and hashing use the raw UTF-8 bytes, so NFC and NFD spellings stay distinct
/// (the Box can hold both as separate files). `logical` is the NFC form.
public struct RelativePath: Hashable, Sendable, Comparable, Codable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public init(from d: Decoder) throws { raw = try d.singleValueContainer().decode(String.self) }
    public func encode(to e: Encoder) throws { var c = e.singleValueContainer(); try c.encode(raw) }

    public var logical: String { raw.precomposedStringWithCanonicalMapping }

    public static func == (a: Self, b: Self) -> Bool { a.raw.utf8.elementsEqual(b.raw.utf8) }
    public func hash(into h: inout Hasher) { for b in raw.utf8 { h.combine(b) } }
    public static func < (a: Self, b: Self) -> Bool { a.raw.utf8.lexicographicallyPrecedes(b.raw.utf8) }

    public var parent: RelativePath { RelativePath(raw.lastIndex(of: "/").map { String(raw[..<$0]) } ?? "") }
    public var name: String { raw.lastIndex(of: "/").map { String(raw[raw.index(after: $0)...]) } ?? raw }
    public func appending(_ name: String) -> RelativePath { RelativePath(raw.isEmpty ? name : raw + "/" + name) }
}

/// Metadata of one file or directory. `mtime` has whole-second resolution (SFTP v3);
/// compare with `mtimeSeconds`, never with Date equality.
public struct FileMeta: Hashable, Sendable, Codable {
    public var size: UInt64
    public var mtime: Date
    public var isDirectory: Bool

    public init(size: UInt64, mtime: Date, isDirectory: Bool = false) {
        self.size = size; self.mtime = mtime; self.isDirectory = isDirectory
    }

    public var mtimeSeconds: Int64 { Int64(mtime.timeIntervalSince1970.rounded(.down)) }
}
