#!/bin/zsh
# Opens Hushh with made-up chats, for screenshots. This copy never logs in to Telegram, so it
# shows nothing private, and it runs alongside your normal Hushh.
#
#   scripts/demo.sh           the system's appearance, like the app
#   scripts/demo.sh --dark    dark mode
#   scripts/demo.sh --light   light mode
#
# Then press ⌘⇧4, Space, and click the window (hold ⌥ while clicking to leave out the shadow).
set -e
args=(-HushhDemo YES)
[[ "$1" == "--dark" ]] && args+=(-HushhDemoDark YES)
[[ "$1" == "--light" ]] && args+=(-HushhDemoLight YES)
open -n -a /Applications/Hushh.app --args "${args[@]}"
