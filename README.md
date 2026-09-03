# Stremio for iPhone

A native iOS shell for a self-hosted [Stremio](https://www.stremio.com) web instance, with a
real VLC player underneath so torrent streams (MKV, x265/HEVC, AC3/DTS/EAC3, multi-audio)
actually play on iOS — which Safari/WebKit can't do.

## How it works

```
Stremio web UI (WKWebView)
   └─ Play → injected JS grabs the RAW file URL from the /hlsv2 transcode request
              and cancels the transcode (keeps the server's CPU free)
        └─ loopback proxy (127.0.0.1) adds the SSO cookie + relays Range/206
             └─ MobileVLCKit decodes natively → full-screen player
```

- **Why a proxy:** libvlc in this build cannot send cookies itself (per-media
  `:http-cookies` is ignored; instance-level `--http-cookies` crashes libvlc), so
  VLC fetches from localhost and the app forwards each request with the cookie.
- **Cold torrents:** the proxy holds VLC's connection and re-asks the server until
  data flows, with a live "Buffering from N sources · MB/s" readout, instead of
  surfacing the edge's 504.
- **Player:** tap to show/hide controls · double-tap or ⤢ for Fit/Fill · pinch to zoom ·
  ±10s · scrub · audio & subtitle track pickers · non-blocking close (safe mid-buffer).

## Build

```bash
brew install xcodegen
scripts/fetch-vlc.sh          # pulls MobileVLCKit.xcframework (gitignored)
xcodegen generate
open Stremio.xcodeproj        # set your Team under Signing, then Run on a device
```

Point the app at your instance in `Sources/ContentView.swift` (`stremio.woolston.dev`).

Command-line device install:

```bash
xcodebuild -project Stremio.xcodeproj -scheme Stremio -destination "id=<device-udid>" \
  -derivedDataPath build-device DEVELOPMENT_TEAM=<TEAM> CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-udid> build-device/Build/Products/Debug-iphoneos/Stremio.app
```

`-DVLC_SELFTEST` (Swift active compilation condition) auto-plays a known stream through
the same cookie/proxy path for iterating without the UI.

## Notes

- The simulator has no hardware HEVC decoder, so 4K x265 stutters there; a real iPhone
  hardware-decodes it.
- Stremio's streaming server needs headroom: every web-player play used to spawn an
  ffmpeg transcode that starved the torrent engine. The app now blocks that.
