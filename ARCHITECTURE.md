# BoxSync Architektur

Zwei-Wege-Sync lokaler Ordner <-> Hetzner Storage Box per SFTP (mehrere Ordner-Paare, je eine Engine) (Citadel 0.12.1, exakt gepinnt).

## Schichten
- `BoxSyncApp` (SwiftUI-Menüleiste): nur Anzeige und Bedienung. Liest `SyncState` (ObservableObject), ruft `SyncEngine`. Keine Sync-Logik.
- `BoxSyncCore` (Bibliothek, UI-frei):
  - `SyncEngine`: Ablauf Scan -> Plan -> Ausführen -> Zustand schreiben. Schreibt `SyncStatus`.
  - `SyncPlanner.plan(local:remote:base:)`: reine Funktion, kein I/O, ohne Netz testbar.
  - `RemoteFileSystem` (Citadel-Adapter), `LocalFileSystem` (Platte + FSEvents), `StateStore` (JSON-Datei je Ordner-Paar): austauschbar, in Tests durch Fakes ersetzt.
  - `Config`: Ordner, Host/Port/User, Ausschlüsse, Intervall, Papierkorb. Passwort nur im Schlüsselbund.

## Datenfluss
1. Auslöser: FSEvents lokal, Timer für die Box (Standard 300 s), "Jetzt sync", Start.
2. Scan: lokaler `Snapshot` und entfernter `Snapshot` (Listing liefert Größe + mtime). Hash nur bei Bedarf.
3. `StateSnapshot` = letzter gemeinsamer Stand je Datei (Pfad, Hash/Größe/mtime lokal und entfernt).
4. Planner vergleicht lokal/remote je gegen Basis -> `SyncPlan` (Liste von `SyncAction`).
5. Engine führt aus (Upload, Download, Konfliktkopie, Papierkorb, Rename), danach `StateStore.upsert/remove` je Datei.
6. Nach jedem Upload: Box-mtime per setstat auf lokale mtime setzen. mtime-Vergleich in ganzen Sekunden (SFTP v3).
7. Abbruch: Teil-Datei wird mit Offset fortgesetzt (Upload: Remote-Größe, Download: lokale Teilgröße). Zustand erst nach vollständiger Übertragung.

## Namen und Pfade
- Pfade relativ zum SFTP-Home, ohne führenden Slash (`_boxsync_test/x`).
- `RelativePath` vergleicht und hasht über UTF-8-Bytes: NFC und NFD bleiben getrennte Dateien. `logical` (NFC) nur zum Zuordnen. Originalschreibweise geht an jeden SFTP-Aufruf.

## Konfliktregeln
- Beide Seiten seit Basis geändert (Hash/Größe weicht von Basis ab): die neuere mtime bleibt Original.
- Die ältere Version wird `Name (Konfliktkopie JJJJ-MM-TT HHMM).ext` daneben gelegt, auf beiden Seiten, und in `SyncStatus.conflicts` gemeldet.
- Gleicher Inhalt auf beiden Seiten: kein Konflikt, nur Basis nachziehen.
- Änderung gegen Löschung: Änderung gewinnt, Datei wird neu übertragen.

## Löschregel
- Nie hartes Löschen. Löschung auf einer Seite -> Datei auf der anderen Seite in den Papierkorb.
- Box: `<remoteRoot>/_trash/<Datum>/<Pfad>`. Lokal: `~/.Trash/BoxSync/<Datum>/<Pfad>`.
- Rename nur lokal erkannt (gleicher SHA-256 wie die Basis): auf der Box verschieben statt neu hochladen. Neue Box-Datei mit gleicher Größe/mtime wie eine verschwundene gilt nicht als Rename (kein Inhaltsbeweis): Download plus Papierkorb.
- Massenlösch-Sperre: mehr als 20 Papierkorb-Aktionen und mehr als die Hälfte aller Zustandsdatensätze: Papierkorb-Aktionen entfallen, Fehler sichtbar. Zustandsdatei je Paar (Ordner, Host, Port, Nutzer, Box-Wurzel): `state-<id>.json`.
- Rename auf Zielpfad, der existiert: Ziel zuerst in den Papierkorb (SFTP v3 überschreibt nicht).

## Fehler
- Jeder Fehler landet sichtbar in `SyncStatus.errors` (Menüleiste, Benachrichtigung). Kein stilles Weitermachen.
- Falsches Passwort: `allAuthenticationOptionsFailed` -> Phase `.error`.
- Verbindungsabbruch: neu verbinden, Handles neu öffnen, per Offset fortsetzen.

## Phase 2: File Provider
- Erweiterung nutzt `RemoteFileSystem` und `StateStore` unverändert; Platzhalter sind ein weiterer Zustand je Datei (lokal "nur Metadaten").
- Planner bleibt rein, bekommt nur neue `SyncAction`-Fälle (Materialisieren, Entladen).
- Engine läuft als Dienst im Hauptprozess oder per XPC; die Oberfläche kennt nur `SyncEngine` und `SyncState`.
- Bekannte Falle: `listDirectory` von Citadel schließt Handles nicht -> Listings selten oder Bibliothek patchen.
