import Foundation
import BoxSyncCore

/// `BoxSync --check [--out FILE]`: connects with the saved settings, lists the Box's main folder, prints a short report
/// and writes it to FILE (default `~/Library/Logs/BoxSync/check.txt`). Nothing is changed on the Box or the drive.
/// Exit code: 0 connection fine, 1 an error, 2 the report could not be written.
enum Diagnose {
    struct Options { var out: URL }

    static var defaultOut: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BoxSync/check.txt")
    }

    /// nil when `--check` is not among the arguments (normal app start).
    static func parse(_ args: [String]) -> Options? {
        guard args.contains("--check") else { return nil }
        var out = defaultOut
        if let i = args.firstIndex(of: "--out"), args.indices.contains(i + 1) {
            out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        return Options(out: out)
    }

    static func run(_ o: Options) -> Never {
        Task { exit(await execute(o)) }
        dispatchMain()
    }

    static func execute(_ o: Options) async -> Int32 {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ["BoxSync Diagnose · \(fmt.string(from: Date()))"]
        var failed = false
        if let c = SharedSettings.load(), c.isComplete {
            lines.append("Box: \(c.user)@\(c.host):\(c.port) · lokal: \(c.localPath)")
            let session = BoxSession.shared()
            do {
                let entries = try await session.run { try await $0.list(RelativePath("")) }
                let shown = entries.keys.filter { !Exclusions.isHidden($0.name, inRoot: true) }
                lines.append("Verbindung OK · \(shown.count) Einträge im Hauptordner:")
                for p in shown.sorted() { lines.append("  \(p.raw)\(entries[p]?.isDirectory == true ? "/" : "")") }
            } catch {
                failed = true
                lines.append("FEHLER: \(BoxErrors.message(error))")
            }
            await session.close()
        } else {
            failed = true
            lines.append("FEHLER: nicht eingerichtet (Einstellungen)")
        }
        let s = SharedStatus.load()
        if let d = s.lastRefresh { lines.append("Letzte Aktualisierung des Laufwerks: \(fmt.string(from: d))") }
        for e in s.errors.suffix(10) { lines.append("Fehler \(fmt.string(from: e.date)): \(e.path.map { "\($0): " } ?? "")\(e.message)") }
        for k in s.conflicts.suffix(10) { lines.append("Konfliktkopie: \(k.copy)") }
        let text = lines.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        do {
            try FileManager.default.createDirectory(at: o.out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: o.out, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Bericht konnte nicht nach \(o.out.path) geschrieben werden: \(error.localizedDescription)\n".utf8))
            return 2
        }
        return failed ? 1 : 0
    }
}
