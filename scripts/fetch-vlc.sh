#!/usr/bin/env bash
# Downloads VideoLAN's prebuilt MobileVLCKit xcframework (device + arm64 simulator)
# into Frameworks/. Run once after cloning; the framework is gitignored (1.3 GB).
set -euo pipefail
VER="3.7.3-319ed2c0-79128878"
cd "$(dirname "$0")/.."
mkdir -p Frameworks && cd Frameworks
if [ -d MobileVLCKit.xcframework ]; then echo "MobileVLCKit.xcframework already present"; exit 0; fi
echo "Downloading MobileVLCKit $VER (~250 MB)..."
curl -fL -o vlc.tar.xz "https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-$VER.tar.xz"
tar -xf vlc.tar.xz
mv MobileVLCKit-binary/MobileVLCKit.xcframework . && rm -rf MobileVLCKit-binary vlc.tar.xz
echo "Done: Frameworks/MobileVLCKit.xcframework"
