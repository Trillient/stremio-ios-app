# Stremio iOS App (unofficial)

A native iPhone/iPad app for [Stremio](https://www.stremio.com), built around the **real Stremio
web app** with a **VLC player** underneath — so streams Safari can't play (MKV, x265/HEVC,
AC3/EAC3/DTS, multi-audio) just work. It can also run Stremio's **streaming server on the device
itself**, so torrents play with no home server and no debrid. Because it's the official web UI, it
stays current whenever Stremio ships updates; only the server + playback are native.

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
Built-in mode:  Stremio web app (served from 127.0.0.1 by the app) → in-app server.js → VLC
Own-server mode:
   └─ Play → injected JS grabs the raw file URL from the /hlsv2 request and cancels the transcode
        └─ loopback proxy (127.0.0.1) forwards to your server with your cookie, relays Range/206
             └─ MobileVLCKit decodes natively → full-screen player
```

VLC can't carry site cookies itself in this build, so it fetches from localhost and the app
adds them. Streams from direct-link addons (debrid, HTTP) go straight to VLC.

## Setup

On first launch, pick one:

- **Built-in streaming (recommended)** — the app runs Stremio's streaming server on your phone
  (via `nodejs-mobile`, downloaded once ~7 MB). Torrents play on-device; nothing to host. Costs
  battery/data while watching, and downloads pause when the app is backgrounded (iOS limit).
- **My own Stremio server** — point it at an instance you already run; it fetches torrents, saving
  your phone's battery and data. Cookie-based SSO in front of it is supported.

Change it any time in iOS Settings → Stremio, or flip "Show setup on next launch".

## Play on a TV

- **AirPlay / HDMI (any file, any codec):** Control Center -> Screen Mirroring -> your Apple TV or
  AirPlay TV (or plug in a USB-C/Lightning->HDMI adapter). The phone keeps decoding with VLC and
  renders full-quality video onto the TV as an external display; you keep the controls. Works for
  MKV / x265 / AC3 / DTS because the TV never decodes anything.
- **Chromecast / Google TV:** the Cast button. The TV fetches and decodes the stream itself, so it
  only works for formats a Chromecast supports (MP4/H.264, HLS, WebM). MKV/x265/AC3 torrents can't
  be cast directly and the app says so; use AirPlay/HDMI for those.

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
