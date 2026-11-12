# BoxSync Architektur

Laufwerk für eine Hetzner Storage Box per SFTP als File-Provider-Erweiterung (Platzhalter, Laden beim Öffnen),
Citadel 0.12.1 (exakt gepinnt).

## Teile
- `BoxSync` (SwiftUI-Menüleiste, nicht sandboxed): Einstellungen, Passwort, Anmelden der File-Provider-Domain,
  Verweis `config.localPath` -> Laufwerk, Timer für Aktualisierungen, Statusanzeige, `--check`. Kein Box-Zugriff
  außer `--check`.
- `BoxSyncFileProvider` (`NSFileProviderReplicatedExtension`, sandboxed): alle Box-Operationen.
- `BoxSyncCore` (Swift-Paket, UI-frei, getestet mit `swift test`):
  - `SFTPRemoteFileSystem` (Citadel-Adapter), `BoxSession` (eine geteilte Verbindung, Wiederaufbau, Backoff),
    `BoxOperations` (Upload über Temp-Datei, Box-Papierkorb, Konfliktkopie-Namen).
  - `ItemIndex` (SQLite in der App-Group): stabile Item-IDs <-> Box-Pfad (Eltern-ID + Name), Änderungslog.
  - `Shared` (App-Group-UserDefaults: Einstellungen, Status; Darwin-Notification bei Statusänderung), `Keychain`
    (Data-Protection-Keychain, Zugriffsgruppe `B6VK6QB456.de.martini-labs.BoxSync.shared`).
- Gebaut mit Xcode aus `project.yml` (XcodeGen), automatische Signierung; das Profil erlaubt die Keychain-Gruppe.

## Identität
- Item-ID = UUID aus dem Index (Wurzel und Papierkorb: die System-IDs). IDs bleiben bei Umbenennen/Verschieben gleich;
  Pfade werden aus Eltern-Kette und Namen gebildet.
- Namen bleiben in Box-Schreibweise (NFC/NFD getrennt, Vergleich über UTF-8-Bytes). Listings sind Arrays, keine
  Dictionaries mit String-Schlüsseln (die würden NFC und NFD zusammenlegen).
- Kollidierende Namen (nur Groß-/Kleinschreibung oder Unicode-Form verschieden): eines wird gezeigt (das bekannte, sonst
  das byteweise erste), das andere als Fehler gemeldet. Sonst würde macOS lokal umbenennen und das auf der Box nachziehen.
- Nie gezeigt: `_trash`, `.ssh`, `_backup`, `.boxsync-partial` in der Wurzel; überall `.DS_Store`, `._*`,
  `.boxsync-*.part`. Diese Namen werden auch nicht hochgeladen (`excludedFromSync`).

## Ablauf
- Ordner öffnen: `FolderEnumerator` listet live, `ItemIndex.reconcile` gleicht ab (neu, geändert, weg) und protokolliert.
  Der Ordner gilt danach als "gesehen".
- Fremde Änderungen: App signalisiert alle `intervalSeconds` (und beim Aufwachen) den Working Set. Dessen
  `enumerateChanges` listet alle gesehenen Ordner (Eltern zuerst, höchstens alle 20 s) und meldet die Einträge des
  Änderungslogs seit dem Anker. Log hält 50 000 Einträge; älterer Anker -> `syncAnchorExpired` (System zählt neu auf).
- Öffnen: `fetchContents` lädt in das Temp-Verzeichnis des Managers und prüft die Größe.
- Anlegen: Ordner per `mkdir` (bestehender Box-Ordner wird übernommen); Datei per Upload. Name belegt -> Konfliktkopie
  (bei `mayAlreadyExist` mit gleicher Größe und mtime: vorhandene Datei übernehmen).
- Ändern: Umbenennen/Verschieben per `rename` (Ziel belegt -> `filenameCollision`). Inhalt: Box unverändert seit
  letztem Stand -> alte Version in den Box-Papierkorb, neue an ihre Stelle. Box inzwischen geändert -> neuere Version
  behält den Namen, die andere wird `Name (Konfliktkopie JJJJ-MM-TT HHMM).ext` daneben.
- Papierkorb: Finder-Papierkorb = sofort `_trash/<Datum>/<Pfad>` auf der Box (Index merkt den Box-Pfad), Zurücklegen =
  `rename` zurück. Papierkorb leeren oder Löschen außerhalb des Papierkorbs: Item bleibt in `_trash` auf der Box.
  Löschen einer Datei, die sich auf der Box geändert hat -> `deletionRejected` (Änderung gewinnt).
- Anderer Box-Zugang (Host, Port, Benutzer): Domain wird entfernt (lokale, nie hochgeladene Änderungen bewahrt macOS)
  und neu angelegt, mit neuem Index.

## Verbindung
- Eine SSH-Verbindung je Erweiterungsprozess; Dateiübertragungen parallel auf einem SFTP-Kanal.
- Citadel `listDirectory` schließt Verzeichnis-Handles nicht -> Listings laufen seriell auf einem eigenen Kanal, der
  alle 200 Listings ersetzt wird (sonst `SSH_FX_FAILURE` bei großen Boxen).
- Die Box sperrt eine Adresse nach zu vielen Verbindungsversuchen. Nach fehlgeschlagenem Verbindungsaufbau wartet
  `BoxSession` 30 s, verdoppelt bis 15 min; abgelehnte Anmeldung wird erst nach geänderten Zugangsdaten wiederholt.

## Fehler
- Jeder Fehler landet sichtbar im gemeinsamen Status (Menüleiste, Benachrichtigung) und als File-Provider-Fehler
  (`notAuthenticated`, `serverUnreachable`, `cannotSynchronize`, `noSuchItem`). Kein stilles Weitermachen.
