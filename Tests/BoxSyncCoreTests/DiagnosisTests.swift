import Foundation
import Testing
@testable import BoxSyncCore

private func counts(up: Int = 0, down: Int = 0, conflicts: Int = 0) -> SyncCounts {
    var c = SyncCounts(); c.uploads = up; c.downloads = down; c.conflicts = conflicts; return c
}

private func check(_ name: String = "Docs", pending: SyncCounts? = SyncCounts(), errors: [String] = [], tracked: Int = 0) -> PairCheck {
    var s = SyncStatus()
    s.pending = pending; s.trackedFiles = tracked
    s.errors = errors.map { SyncIssue(message: $0) }
    return PairCheck(name: name, folder: "/Users/x/\(name)", remote: "box.example:\(name)", status: s)
}

@Test func verdictFollowsPlanAndErrors() {
    #expect(check().verdict == .ok)
    #expect(check(pending: counts(up: 2)).verdict == .pending)
    #expect(check(errors: ["Verbindung fehlgeschlagen"]).verdict == .failed)
    #expect(check(pending: nil).verdict == .failed, "no plan means the scan did not finish")
    #expect(check(pending: counts(up: 5), errors: ["x"]).verdict == .failed, "an error beats pending work")
}

@Test func exitCodeIsZeroOnlyWhenEverythingIsInSync() {
    #expect(DiagnosisReport.exitCode([check("A"), check("B")]) == 0)
    #expect(DiagnosisReport.exitCode([check("A"), check("B", pending: counts(down: 1))]) == 1)
    #expect(DiagnosisReport.exitCode([check("A", errors: ["x"])]) == 1)
    #expect(DiagnosisReport.exitCode([]) == 0)
}

@Test func reportNamesEveryPairWithItsNumbers() {
    let text = DiagnosisReport.text([check("Docs", tracked: 1229), check("Notes", pending: counts(up: 3, down: 2, conflicts: 1))],
                                    date: Date(timeIntervalSince1970: 1_800_000_000))
    #expect(text.contains("[Docs]") && text.contains("[Notes]"))
    #expect(text.contains("Dateien synchron: 1229"))
    #expect(text.contains("↑ 3 hoch · ↓ 2 runter · ⚠ 1 Konflikte"))
    #expect(text.contains("nur prüfen, es wurde nichts geändert"))
    #expect(text.hasSuffix("Gesamt: AUSSTEHEND, es gibt Änderungen\n"))
}

@Test func reportShowsErrorsAndNeverClaimsOkAfterOne() {
    let text = DiagnosisReport.text([check(errors: ["Verbindung fehlgeschlagen: Connect timeout (10 s)"])], date: Date())
    #expect(text.contains("Ergebnis: FEHLER"))
    #expect(text.contains("Fehler: Verbindung fehlgeschlagen: Connect timeout (10 s)"))
    #expect(text.contains("Gesamt: FEHLER") && !text.contains("ALLES OK"))
}

@Test func reportOfAnInSyncSetSaysSo() {
    let text = DiagnosisReport.text([check("A"), check("B")], date: Date())
    #expect(text.contains("Gesamt: ALLES OK, nichts zu synchronisieren"))
}

@Test func displayNameIsBoxFolderElseLocalFolder() {
    #expect(Config(syncFolder: URL(fileURLWithPath: "/Users/x/Documents")).displayName == "Documents")
    #expect(Config(syncFolder: URL(fileURLWithPath: "/Users/x/Notes"), remoteRoot: "Vault").displayName == "Vault")
}
