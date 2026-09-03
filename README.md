# Stremio iOS App (unofficial)

A native iPhone/iPad app for [Stremio](https://www.stremio.com), built around the **real Stremio
web app** with a **VLC player** underneath — so streams that Safari can't play (MKV, x265/HEVC,
AC3/EAC3/DTS, multi-audio) just work. Because it's the official web UI, it stays current whenever
Stremio ships updates; only playback is native.

> Unofficial. Not affiliated with or endorsed by Stremio. Bring your own streams/addons.

## Features

- Official Stremio web UI (`web.stremio.com`) or your own self-hosted instance
- Native VLC playback: MKV, HEVC/x265 (hardware-decoded on device), AC3/DTS/EAC3, any container
- **Audio & subtitle track pickers** for multi-audio releases
- Tap to show/hide controls · double-tap or ⤢ for Fit / Fill · pinch to zoom · ±10 s · scrub
- Cold torrents don't error out: the app holds the connection and shows live buffering
  ("Buffering from 23 sources · 2.1 MB/s") until data flows
- Skips the server-side ffmpeg transcode entirely — VLC plays the raw file, keeping your
  streaming server's CPU free
- Works behind cookie-based SSO in front of a self-hosted instance (the app forwards your login)
- Close works instantly, even mid-buffer

## How it works

```
Stremio web app (WKWebView)
   └─ Play → injected JS grabs the raw file URL from the /hlsv2 request and cancels the transcode
        └─ loopback proxy (127.0.0.1) forwards to your server with your cookie, relays Range/206
             └─ MobileVLCKit decodes natively → full-screen player
```

VLC can't carry site cookies itself in this build, so it fetches from localhost and the app
adds them. Streams from direct-link addons (debrid, HTTP) go straight to VLC.

## Setup

On first launch the app asks where to connect: **your own Stremio instance** (enter its URL —
torrents play via its bundled streaming server) or the **official web.stremio.com** (torrents
need a debrid addon or a streaming server URL set in Stremio's settings). Change it any time in
iOS Settings → Stremio, or flip "Show setup on next launch".

1. **Streaming server.** Torrent playback needs a Stremio streaming server. Point the web app at
   yours: Stremio → Settings → *Streaming server URL* (e.g. `http://your-server:11470` or an
   `https://` reverse-proxied URL). Direct-link addons work without one.
2. **Web URL (optional).** iOS Settings → **Stremio** → *Web URL* to use a self-hosted instance
   instead of `web.stremio.com`. Relaunch after changing.

## Build & install

```bash
brew install xcodegen
scripts/fetch-vlc.sh          # downloads MobileVLCKit.xcframework (~1.3 GB, gitignored)
xcodegen generate
open Stremio.xcodeproj        # Signing & Capabilities → pick your Team → Run on your iPhone
```

Or from the command line:

```bash
xcodebuild -project Stremio.xcodeproj -scheme Stremio -destination "id=<device-udid>" \
  -derivedDataPath build-device DEVELOPMENT_TEAM=<TEAM_ID> CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> \
  build-device/Build/Products/Debug-iphoneos/Stremio.app
```

Change `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` to your own. A free Apple ID signs for
7 days; a paid developer team for a year.

`VLC_SELFTEST` (Swift compilation condition) auto-plays a stream through the same
proxy/VLC path — handy for iterating on the player without the UI.

## Notes

- The iOS Simulator has no hardware HEVC decoder, so 4K x265 stutters there. Real devices decode it in hardware.
- If your streaming server sits on a small box, keep transcoding off — every web-player play
  used to spawn an ffmpeg job that starved the torrent engine. This app never triggers it.

## License

MIT
