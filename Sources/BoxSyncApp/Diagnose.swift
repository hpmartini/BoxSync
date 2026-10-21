import Foundation
import BoxSyncCore

/// `BoxSyncApp --check [--out FILE]`: scans every folder pair in check-only mode, prints the report and writes it to FILE
/// (default `~/Library/Logs/BoxSync/check.txt`). No window, no menu, nothing is changed on either side.
/// Exit code: 0 all in sync, 1 work pending or an error, 2 the report could not be written.
/// It runs inside the app binary on purpose: the Keychain approval belongs to that binary, a separate tool would ask again.
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

    @MainActor static func run(_ o: Options) -> Never {
        Task { exit(await execute(o)) }
        dispatchMain()
    }

    @MainActor static func execute(_ o: Options) async -> Int32 {
        var checks: [PairCheck] = []
        for c in AppEnvironment.loadConfigs() {
            checks.append(PairCheck(name: c.displayName, folder: c.syncFolder.path,
                                    remote: "\(c.host):\(c.remoteRoot.isEmpty ? "~" : c.remoteRoot)", status: await status(of: c)))
        }
        let text = DiagnosisReport.text(checks, date: Date())
        print(text, terminator: "")
        do {
            try FileManager.default.createDirectory(at: o.out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: o.out, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("Bericht konnte nicht nach \(o.out.path) geschrieben werden: \(error.localizedDescription)\n".utf8))
            return 2
        }
        return DiagnosisReport.exitCode(checks)
    }

    @MainActor private static func status(of c: Config) async -> SyncStatus {
        if Demo.enabled { return Demo.status(for: c) }
        do {
            let store = try JSONStateStore(url: JSONStateStore.url(for: c))
            let password = Keychain.read(account: Keychain.account(host: c.host, user: c.user)) ?? ""
            let engine = BoxSyncEngine.sftp(config: c, password: password, store: store, hostKeys: KeychainHostKeys())
            await engine.checkNow()
            return await engine.status
        } catch {
            var s = SyncStatus()
            s.phase = .error; s.errors = [SyncIssue(message: "Zustandsdatei: \(error.localizedDescription)")]
            return s
        }
    }
}
