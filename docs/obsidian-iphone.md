# Obsidian vault on the iPhone via Remotely Save

BoxSync keeps a Mac folder (for example an Obsidian vault) in sync with a Hetzner Storage Box over SFTP.
The iPhone cannot run BoxSync, so it reaches the same Box folder through the Obsidian plugin
[Remotely Save](https://github.com/remotely-save/remotely-save), which speaks **WebDAV** (not SFTP).

```
Mac folder  <-- BoxSync (SFTP) -->  Storage Box folder  <-- Remotely Save (WebDAV) -->  iPhone vault
```

Both tools must point at the **same Box folder**. This guide uses `MyVault` as the example folder name.
Replace it with the name of your vault folder.

## Before you start

- In the [Hetzner Console](https://console.hetzner.com/) open your Storage Box, choose "Change settings"
  and make sure **WebDAV support** and **External Reachability** are on.
- WebDAV address of the main user: `https://uXXXXX.your-storagebox.de`
  (sub account: `https://uXXXXX-subX.your-storagebox.de`).
- Do **not** set an end-to-end encryption password in Remotely Save. Encrypted files on the Box
  are unreadable for BoxSync and for the Mac.
- A vault folder that already exists on the Box under another name (for example the plugin's default,
  the vault name) stays untouched. Remotely Save never moves or deletes it.

## Switch the iPhone vault to the BoxSync folder

1. **Back up.** In the Files app, copy the vault folder of the iPhone vault somewhere safe.
2. Open the vault in Obsidian on the iPhone, then *Settings -> Community plugins -> Remotely Save*.
3. Under **Remote For Webdav** keep (or enter) *Server Address*, *Username*, *Password*.
   Tap **Check** next to *Check Connectivity*. It must say the server can be accessed.
4. Find **Change The Remote Base Directory (experimental)**, type `MyVault`, tap **Confirm**, then
   confirm again with **Confirm To Change**.
   The plugin does not move anything. From now on it syncs against `MyVault` and treats it as new.
5. Set **Regex Of Paths To Ignore** (one regex per line):

   ```
   ^_trash(/|$)
   ^\.obsidian/workspace
   ```

   - `_trash` is where BoxSync parks files that were deleted on one side.
   - `.obsidian/workspace*` holds the window layout and changes on every open. BoxSync skips it as well.
   - Remotely Save already skips every path that starts with `.` or `_` unless you turn on
     *Sync _ Files Or Folders* or *Sync Config Dir*. Keep both **off**. The desktop plugins in `.obsidian`
     do not run on iOS. The two lines above only matter if you ever turn those options on.
6. Set **Skip Large Files** to `50` (MB). Obsidian on iOS has trouble with files above that size.
   Optional: to keep big folders off the phone, add more lines to the ignore list, for example `^wiki/`.
7. Leave **Abort Sync If Modification Above Percentage** at 50. It stops a sync that would delete, modify or
   conflict-resolve more than half of the files at once. Newly created files do not count (checked in the plugin
   source), so the first merge normally passes. If it still aborts, read the plan before raising the value.
8. **Preview first.** Open the command palette and run *Remotely Save: start sync (dry run only)*,
   then *export sync plans (latest 1)* and read the plan.
   Expect many downloads: the iPhone vault is merged with the Box folder in both directions.
   Files that exist only in the old iPhone vault are uploaded into `MyVault`.
9. Run *Remotely Save: start sync* and be patient. The first run is the slow one.
10. Set **Schedule For Auto Run** (for example every 10 minutes) and **Run Once On Start Up Automatically**.
    Auto sync only runs while Obsidian is open.

## Check it on the Mac

In the BoxSync menu choose *Alle nur prüfen* (check only). Notes written on the iPhone show up as pending
downloads and arrive on the next sync. If a note changed on both sides, BoxSync keeps the newer one in place
and stores the other as `Name (Konfliktkopie YYYY-MM-DD HHMM).md`. Remotely Save keeps the newer version
by default.

## Cleaning up

When the iPhone and the Mac show the same notes, you can delete the old vault folder from the Box by hand.
Nothing in BoxSync or Remotely Save does that for you.
