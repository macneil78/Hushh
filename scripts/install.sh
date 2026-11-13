#!/bin/zsh
# Builds Hushh in Release mode and installs it as /Applications/Hushh.app.
# Run from anywhere: scripts/install.sh   (or scripts/install.sh --build-only to skip installing)
# INSTALL_DIR=<folder> installs into another folder than /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

build_only=false
if [[ "${1:-}" == "--build-only" ]]; then
    build_only=true
fi
install_dir=${INSTALL_DIR:-/Applications}

if ! command -v xcodegen > /dev/null; then
    echo "XcodeGen is missing. Install it with: brew install xcodegen"
    exit 1
fi
if ! xcodebuild -version > /dev/null 2>&1; then
    echo "xcodebuild needs Xcode 26. Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app"
    exit 1
fi

# Two copies can't share the Telegram database, and quitting normally lets it close cleanly.
# Checked before the build, which takes minutes.
if ! $build_only && pgrep -xq Hushh; then
    echo "Hushh is running (maybe from Xcode, or the demo from scripts/demo.sh). Quit it with ⌘Q, then run this again."
    exit 1
fi

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
if $build_only; then
    exit 0
fi

# Again, in case Hushh was opened during the build.
if pgrep -xq Hushh; then
    echo "Hushh is running. Quit it with ⌘Q, then run this again."
    exit 1
fi

# Copy next to the installed app first, and swap only when the copy is complete, so a failed
# copy leaves the installed app as it was.
installed="$install_dir/Hushh.app"
incoming="$install_dir/.Hushh-incoming.app"
outgoing="$install_dir/.Hushh-outgoing.app"
rm -rf "$incoming" "$outgoing"
if ! cp -R "$app" "$incoming"; then
    rm -rf "$incoming"
    echo "Couldn't copy the app to $install_dir. The installed app is unchanged."
    exit 1
fi
if [[ -e "$installed" ]]; then
    mv "$installed" "$outgoing"
fi
if ! mv "$incoming" "$installed"; then
    [[ -e "$outgoing" ]] && mv "$outgoing" "$installed"
    rm -rf "$incoming"
    echo "Couldn't install the app in $install_dir. The installed app is unchanged."
    exit 1
fi
rm -rf "$outgoing"
echo "Installed $installed"

# Codex features (Catch Up, Draft, Polish, Translate) go through this script, which macOS runs
# for Hushh outside its sandbox. Harmless without Codex: Hushh then just doesn't offer them.
scripts_dir="$HOME/Library/Application Scripts/com.macneil.Hush"
mkdir -p "$scripts_dir"
cp scripts/codex-bridge.sh "$scripts_dir/"
chmod +x "$scripts_dir/codex-bridge.sh"
open "$installed"
