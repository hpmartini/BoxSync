import Foundation

/// Which Box names the drive shows and which local names it never uploads.
public enum Exclusions {
    /// Top-level Box folders owned by the Box or by BoxSync: never shown, never written by the user.
    public static let reservedTopLevel: Set<String> = ["_trash", ".ssh", "_backup", ".boxsync-partial"]

    /// Temp files of an upload in progress (`.boxsync-<id>.part`).
    public static func isPartialName(_ name: String) -> Bool {
        name.hasPrefix(".boxsync-") && name.hasSuffix(".part")
    }

    /// macOS housekeeping files: never uploaded, hidden when found on the Box.
    public static func isIgnoredName(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || isPartialName(name)
    }

    /// True when a Box entry named `name` directly inside `folder` stays out of the drive.
    public static func isHidden(_ name: String, inRoot: Bool) -> Bool {
        isIgnoredName(name) || (inRoot && reservedTopLevel.contains(name))
    }
}

public enum NameRules {
    /// `Name.ext` -> `Name (Konfliktkopie <stamp>).ext`, with " 2", " 3" ... appended while `isTaken` says so.
    public static func conflictName(_ name: String, stamp: String, isTaken: (String) -> Bool) -> String {
        numbered(name, isTaken: isTaken) { stem, n in "\(stem) (Konfliktkopie \(stamp)\(n == 1 ? "" : " \(n)"))" }
    }

    /// `Name.ext` -> `Name.ext` if free, else `Name 2.ext`, `Name 3.ext` ...
    public static func freeName(_ name: String, isTaken: (String) -> Bool) -> String {
        if !isTaken(name) { return name }
        return numbered(name, isTaken: isTaken, first: 2) { stem, n in "\(stem) \(n)" }
    }

    private static func numbered(_ name: String, isTaken: (String) -> Bool, first: Int = 1,
                                 _ make: (Substring, Int) -> String) -> String {
        let dot = name.dropFirst().lastIndex(of: ".")
        let (stem, ext) = dot.map { (name[..<$0], String(name[$0...])) } ?? (name[...], "")
        var n = first
        while true {
            let cand = make(stem, n) + ext
            if !isTaken(cand) { return cand }
            n += 1
        }
    }

    /// Key under which two names collide on a default macOS volume (case-insensitive, NFC/NFD equivalent).
    public static func collisionKey(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    /// Keeps one name per collision key: the one the drive already shows (`known`), else the byte-wise first.
    /// macOS cannot hold both, and letting it rename one locally would rename the file on the Box.
    public static func dedupe(_ names: [String], known: [String]) -> (kept: [String], dropped: [String]) {
        var groups: [String: [String]] = [:]
        for n in names { groups[collisionKey(n), default: []].append(n) }
        var kept: [String] = [], dropped: [String] = []
        for (_, g) in groups {
            let sorted = g.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            let keep = sorted.first { n in known.contains { $0.utf8.elementsEqual(n.utf8) } } ?? sorted[0]
            kept.append(keep)
            dropped += sorted.filter { !$0.utf8.elementsEqual(keep.utf8) }
        }
        return (kept, dropped)
    }
}
