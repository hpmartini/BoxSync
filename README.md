# BoxSync

A native macOS drive for a [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box/) over SFTP, built like
iCloud Drive: Finder shows every file and folder of the Box as a placeholder, and a file is downloaded only when you
open it. Changes go straight back to the Box. No `rclone`, no mounts: a menu bar app plus a File Provider extension.

> The app's interface is in German for now. The code, comments and this README are in English.
> BoxSync is an independent project and is not affiliated with Hetzner.

## Features

- **Placeholders, download on open.** The drive appears in the Finder sidebar as *BoxSync*
  (`~/Library/CloudStorage/BoxSync-BoxSync`), plus a link at a path of your choice (default `~/BoxSync`).
  Finder's *Download Now* and *Remove Download* work as with iCloud Drive.
- **Writes go to the Box at once,** through a temp file and a rename, so the Box never holds a half-written file.
- **Never deletes for good.** Deleting (or emptying the Mac trash) leaves the item in `_trash/<date>/` on the Box.
  A replaced version of a file goes there too.
- **Conflicts:** a file changed on the Box and on the Mac at the same time keeps the newer version under its name;
  the other one is stored next to it as `Name (Konfliktkopie YYYY-MM-DD HHMM).ext`. A file changed on the Box is not
  deleted by a local delete.
- **Changes from other devices** are picked up every 5 minutes (adjustable), on wake and with *Jetzt aktualisieren*.
  Only folders you have opened are compared, so a large Box costs nothing until you browse it.
- **Gentle with the Box:** one SSH connection; after a failed connect BoxSync waits (30 s up to 15 min) instead of
  retrying, and a rejected login is not retried until the settings change. The Box blocks an address for a while
  after too many attempts.
- **Security:** the password lives in the Keychain only. The host key is pinned on first connect (trust on first use);
  a changed key aborts the connection.
- **Unicode and case:** NFC and NFD names stay distinct on the Box. Two names that only differ in letter case or
  Unicode form cannot both exist on the Mac; the drive shows one and reports the other.

## Requirements

- macOS 14 or newer, Xcode 16+ with an Apple ID signed in (Xcode > Settings > Accounts; a free Personal Team works)
- `xcodegen` (`brew install xcodegen`)
- A Hetzner Storage Box with SFTP (port 23) and password login

## Build and run

```sh
scripts/build-app.sh          # builds build/BoxSync.app, signed for the team in project.yml
ditto build/BoxSync.app ~/Applications/BoxSync.app && open ~/Applications/BoxSync.app
```

To build for another team, change `DEVELOPMENT_TEAM`, the app group and the keychain group (`B6VK6QB456...`) in
`project.yml`, `Resources/*.entitlements`, `Resources/FileProvider-Info.plist` and `Sources/BoxSyncCore/Shared.swift`.

First start:

1. *Einstellungen…*: host (`uXXXXX.your-storagebox.de`), user (`uXXXXX`, not your e-mail address), password,
   and the local folder for the link. Save.
2. macOS asks once to allow the extension: System Settings > General > Login Items & Extensions > File Providers >
   turn on *BoxSync*.

## Check from the command line

```sh
~/Applications/BoxSync.app/Contents/MacOS/BoxSync --check                 # report in ~/Library/Logs/BoxSync/check.txt
~/Applications/BoxSync.app/Contents/MacOS/BoxSync --check --out ~/check.txt
```

Connects with the saved settings, lists the Box's main folder and prints the drive's last refresh, errors and conflict
copies. Changes nothing. Exit code: `0` connection fine, `1` an error, `2` the report could not be written.

## Tests

```sh
swift test                    # unit tests, no network
BOXSYNC_TEST_HOST=uXXXXX.your-storagebox.de BOXSYNC_TEST_USER=uXXXXX BOXSYNC_TEST_PASSWORD=... swift test
```

The integration tests only create and remove folders under `_boxsync_test/` (and their copies in `_trash/<date>/`).
Without the three variables they are skipped.

## Screenshots with demo data

`BOXSYNC_DEMO=1 ~/Applications/BoxSync.app/Contents/MacOS/BoxSync` starts the menu bar app with invented status,
without touching the drive or the network.

## Using the same folder from an iPhone

An Obsidian vault on the Box can be shared with the iPhone through the Remotely Save plugin (WebDAV).
See [docs/obsidian-iphone.md](docs/obsidian-iphone.md).

## Limits

- Password login only (no SSH keys yet). Symlinks on the Box are not shown.
- With a free Personal Team, Xcode's provisioning profile is valid for 7 days. Rebuild and reinstall within that
  time (`scripts/build-app.sh`), or the app and the extension stop starting.
- Thumbnails are not provided by the extension; Finder shows icons for files that are not downloaded.
- Orphaned `.boxsync-*.part` files from interrupted uploads are hidden but not removed from the Box.
- The interface is German only.

## Design

See [ARCHITECTURE.md](ARCHITECTURE.md) (German).

## License

[MIT](LICENSE)
