#!/bin/zsh
# Opens Hushh with made-up chats, for screenshots. This copy does not log in to Telegram, so it
# shows nothing private, and it runs alongside your normal Hushh.
#
#   scripts/demo.sh                    the system's appearance, like the app
#   scripts/demo.sh --dark             dark mode
#   scripts/demo.sh --light            light mode
#   scripts/demo.sh path/to/Hushh.app  a particular build
#
# Without a path it opens /Applications/Hushh.app, else the build from scripts/install.sh, else
# the Debug build Xcode made from this folder.
#
# Then press ⌘⇧4, Space, and click the window (hold ⌥ while clicking to leave out the shadow).
set -eu
repo=${0:A:h:h}
args=(-HushhDemo YES)
appearance=
app=
for arg in "$@"; do
    case $arg in
        --dark | --light)
            if [[ -n $appearance && $appearance != $arg ]]; then
                echo "Use --dark or --light, not both."
                exit 1
            fi
            appearance=$arg
            ;;
        -*)
            echo "Unknown option $arg. Use --dark, --light, or the path of a Hushh.app."
            exit 1
            ;;
        *)
            app=$arg
            ;;
    esac
done
[[ $appearance == --dark ]] && args+=(-HushhDemoDark YES)
[[ $appearance == --light ]] && args+=(-HushhDemoLight YES)

if [[ -z $app ]]; then
    candidates=(/Applications/Hushh.app "$repo/build/DerivedData/Build/Products/Release/Hushh.app")
    # Xcode's own build folder for this checkout's project (another clone has another folder).
    for folder in ~/Library/Developer/Xcode/DerivedData/Hush-*(N/); do
        workspace=$(plutil -extract WorkspacePath raw "$folder/info.plist" 2>/dev/null || true)
        if [[ -n $workspace && ${workspace:A} == "$repo/Hush.xcodeproj" ]]; then
            candidates+=("$folder/Build/Products/Debug/Hushh.app")
        fi
    done
    for candidate in $candidates; do
        if [[ -d $candidate ]]; then
            app=$candidate
            break
        fi
    done
fi
if [[ -z $app ]]; then
    echo "No Hushh.app found. Build one with scripts/install.sh --build-only, or pass its path."
    exit 1
fi
if [[ ! -d $app ]]; then
    echo "$app is not an app. Pass the path of a Hushh.app."
    exit 1
fi
open -n -a "$app" --args "${args[@]}"
