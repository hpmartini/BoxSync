import Foundation

/// Exclusion and reserved-name rules shared by both scans and the planner.
public enum Exclusions {
    /// Never sync content: top-level names on the Box (or in the sync folder) owned by tooling.
    public static let reservedTopLevel: Set<String> = ["_trash", ".ssh", "_backup", ".boxsync-partial"]

    /// Temp files of an interrupted upload (`.boxsync-<hash>-<size>-<mtime>.part`).
    public static func isPartialName(_ name: String) -> Bool {
        name.hasPrefix(".boxsync-") && name.hasSuffix(".part")
    }

    public static func isReserved(_ path: RelativePath) -> Bool {
        let comps = path.raw.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = comps.first else { return false }
        return reservedTopLevel.contains(String(first)) || isPartialName(String(comps.last!))
    }

    /// Patterns: `dir/**` (everything below dir), a bare name or glob (matches any path component),
    /// or a glob containing `/` (matches the whole relative path).
    public static func matches(_ path: RelativePath, patterns: [String]) -> Bool {
        let comps = path.raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for pat in patterns {
            if pat.hasSuffix("/**") {
                let prefix = String(pat.dropLast(3))
                if path.raw == prefix || path.raw.hasPrefix(prefix + "/") { return true }
            } else if pat.contains("/") {
                if fnmatch(pat, path.raw, 0) == 0 { return true }
            } else if comps.contains(where: { fnmatch(pat, $0, 0) == 0 }) {
                return true
            }
        }
        return false
    }
}
