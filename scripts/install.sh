#!/bin/zsh
# Builds Hushh in Release mode and installs it as /Applications/Hushh.app.
# Run from anywhere: scripts/install.sh   (or scripts/install.sh --build-only to skip installing)
set -euo pipefail
cd "$(dirname "$0")/.."

# Kept between runs (git-ignored), so packages download and compile once.
build_dir=build/DerivedData
mkdir -p build

xcodegen generate --quiet
echo "Building Hushh (Release)… this takes a few minutes the first time."
if ! xcodebuild -project Hush.xcodeproj -scheme Hush -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$build_dir" build > build/xcodebuild.log 2>&1; then
    grep -E "error:" build/xcodebuild.log | head -20
    echo "Build failed. Full log: build/xcodebuild.log"
    exit 1
fi
app="$build_dir/Build/Products/Release/Hushh.app"
echo "Built $app"
[[ "${1:-}" == "--build-only" ]] && exit 0

# Two copies can't share the Telegram database, and quitting normally lets it close cleanly.
if pgrep -xq Hushh; then
    echo "Hushh is running (maybe from Xcode). Quit it with ⌘Q, then run this again."
    exit 1
fi

rm -rf /Applications/Hushh.app
cp -R "$app" /Applications/
echo "Installed /Applications/Hushh.app"
open /Applications/Hushh.app
