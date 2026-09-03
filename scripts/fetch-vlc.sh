#!/usr/bin/env bash
# Fetches the two prebuilt frameworks (both gitignored, ~1.4 GB total):
#   - MobileVLCKit.xcframework (VideoLAN) — native player
#   - NodeMobile.xcframework (nodejs-mobile) — runs Stremio's server.js on-device
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Frameworks && cd Frameworks

VLC="3.7.3-319ed2c0-79128878"
if [ ! -d MobileVLCKit.xcframework ]; then
  echo "Downloading MobileVLCKit $VLC (~250 MB)..."
  curl -fL -o vlc.tar.xz "https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-$VLC.tar.xz"
  tar -xf vlc.tar.xz && mv MobileVLCKit-binary/MobileVLCKit.xcframework . && rm -rf MobileVLCKit-binary vlc.tar.xz
fi

NODE="v18.20.4"
if [ ! -d nodejs-mobile/NodeMobile.xcframework ]; then
  echo "Downloading nodejs-mobile $NODE (~49 MB)..."
  curl -fL -o node.zip "https://github.com/nodejs-mobile/nodejs-mobile/releases/download/$NODE/nodejs-mobile-$NODE-ios.zip"
  rm -rf nodejs-mobile && unzip -q node.zip -d nodejs-mobile && rm node.zip
fi
echo "Done. Frameworks/ ready."
