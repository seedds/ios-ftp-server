# FTP Server for iOS

An iPhone/iPad app that turns the device into an FTP server, so any computer on the same
Wi-Fi can upload, download, resume, rename and delete files with an ordinary FTP client.

## Features

- **Upload & download**: `STOR`, `RETR`, `APPE`, `STOU`, streamed in 256 KB chunks, so large
  files use little memory.
- **Resume both ways**: `REST` + `RETR` resumes downloads, and `REST` + `STOR` or `APPE` resumes
  uploads. Interrupted uploads are kept on disk so the client can continue them (`SIZE`
  reports how much arrived).
- **Passive and active modes**: `PASV`, `EPSV` (IPv6-ready), `PORT`, `EPRT`.
- **Modern listings**: `MLSD`/`MLST` (RFC 3659), plus classic `LIST`/`NLST` in `ls -l` format.
- **File management**: `MKD`, `RMD`, `DELE`, `RNFR`/`RNTO`, `MDTM`, `MFMT` (preserves timestamps), `SIZE`, `STAT`.
- **Cancel**: `ABOR`, including the Telnet IP/DM prefix clients send.
- **Security**:
  - Clients are confined to the shared folder (`..` and symlink escapes are rejected).
  - Data connections only go to or come from the logged-in client's own IP, which blocks FTP bounce and data-port hijacking.
  - Failed logins are answered slowly, and the client is disconnected after 5 failures.
  - Idle sessions time out.
  - The password is stored in the Keychain, and a random one is generated on first launch.
- **Options**: username/password, anonymous login, read-only mode, port, Bonjour (`_ftp._tcp`), keep screen awake, start on launch.
- **In-app UI**:
  - Live transfers with progress and speed.
  - Connected clients and an activity log.
  - A file browser for the shared folder: preview, share, rename, delete, new folder, and import from Files.
- **Files app access**: the shared folder (the app's Documents directory) also appears in the
  Files app under *On My iPhone › FTP Server*.

## Project layout

```
project.yml                  XcodeGen spec (FTPServer.xcodeproj is generated from it)
FTPServer/                   SwiftUI app
  FTPServerApp.swift         App entry + tab view
  ServerController.swift     Owns the server, turns events into UI state, lifecycle handling
  ServerSettings.swift       Persisted settings + Keychain password
  Views/                     Server, Files, Activity, Settings tabs
FTPServerKit/                Swift package: the FTP engine (Network.framework, no dependencies)
  Sources/FTPServerKit/
    FTPServer.swift          Control listener, session management, events
    FTPSession.swift         Per-client protocol state machine (all commands)
    DataConnection.swift     PASV/EPSV listener or PORT/EPRT dialer
    DataTransfer.swift       Back-pressured streaming of files/listings
    VirtualFileSystem.swift  Path sandboxing + LIST/MLSD formatting
  Sources/ftpserverd/        Command-line runner for macOS (handy for testing)
  Tests/                     22 integration + unit tests (real sockets)
```

## Build & run

1. Open `FTPServer.xcodeproj` in Xcode (or regenerate it with `xcodegen generate`).
2. Select the **FTPServer** target, then under *Signing & Capabilities* choose your team and
   change the bundle identifier from `com.example.ftpserver` to your own.
3. Run on a device. The Simulator works too: its server is reachable from the Mac at
   `ftp://127.0.0.1:2121`.
4. Tap the power button. The Server tab shows the address (e.g. `ftp://192.168.1.23:2121`)
   and the login.

The first time, iOS asks for **Local Network** access. Allow it, or other devices can't connect
(*Settings › Privacy & Security › Local Network*).

### Connecting

Use plain FTP (no TLS) from FileZilla, Cyberduck, Transmit, WinSCP, `curl`, `lftp`, or Finder
(*Go › Connect to Server*; Finder mounts FTP read-only).

```sh
curl -T movie.mp4 ftp://ftp:PASSWORD@192.168.1.23:2121/            # upload
curl -C - -T movie.mp4 ftp://ftp:PASSWORD@192.168.1.23:2121/       # resume upload
curl -C - -O ftp://ftp:PASSWORD@192.168.1.23:2121/movie.mp4        # resume download
```

### Unsigned IPA

```sh
scripts/build-unsigned-ipa.sh            # → build/FTPServer-<version>-<build>-unsigned.ipa
scripts/build-unsigned-ipa.sh --help     # configuration, output dir, --version, --build, --regenerate
```

The IPA isn't signed, so sign it before installing: use Sideloadly, AltStore or TrollStore, or
re-sign it with your own certificate and provisioning profile.

### Automatic releases

`.github/workflows/release.yml` runs on every push to `main` (README-only changes are skipped).
It runs the engine tests, builds the unsigned IPA and publishes it as a GitHub release.

- Version: `MARKETING_VERSION` from `project.yml` plus the next free patch number
  (`v1.0.0`, `v1.0.1`, …). Bump `MARKETING_VERSION` to start a new series (`1.1` → `v1.1.0`).
- Build number: the workflow run number.

Pull requests are built and tested too, and the IPA is attached to the run as an artifact instead
of a release. *Actions › Release unsigned IPA › Run workflow* releases on demand.

## Testing

```sh
cd FTPServerKit
swift test                                   # 22 tests: login, transfers, resume, ABOR, PORT, sandbox…
swift run ftpserverd ~/Downloads 2121 me pw  # run the engine on your Mac
```

## Limitations

- **Background**: iOS suspends apps shortly after they leave the foreground, which stops the
  server. The app asks for about 30 extra seconds so running transfers can finish, keeps the
  screen awake while serving (configurable), and restarts the server automatically when you
  return.
- **No FTPS/TLS**: credentials and data travel unencrypted, so use it on networks you trust.
- `TYPE A` is accepted, but files are always transferred byte-for-byte (like vsftpd's default).
