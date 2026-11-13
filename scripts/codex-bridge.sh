#!/bin/zsh
# Hushh's link to Codex, for Catch Up, Draft a Reply, Polish and Translate.
#
# Hushh runs in the macOS app sandbox, so it can't start other programs itself. Scripts you put
# in its Application Scripts folder (~/Library/Application Scripts/com.macneil.Hush) are the
# exception: macOS runs them for it, as you, outside the sandbox. scripts/install.sh puts this
# one there; so does Hushh → Settings → AI → Set Up Codex.
#
# Arguments: the prompt file, where to write the answer, where to write errors, how hard Codex
# should think (low, medium…), the model (empty for your Codex default), then any pictures to
# show it. Codex answers with your ChatGPT account. It runs in an empty folder, can't change
# files (--sandbox read-only), and keeps no session (--ephemeral).
set -u
prompt=$1 answer=$2 errors=$3 effort=${4:-low} model=${5:-}
shift $(( $# < 5 ? $# : 5 ))
codex_args=(-c model_reasoning_effort="$effort")
[[ -n $model ]] && codex_args+=(--model "$model")
for image in "$@"; do codex_args+=(--image "$image"); done

# Started for a sandboxed app, whose HOME is its container: Codex and its sign-in live in your
# real home folder, and the usual places Codex is installed aren't on the PATH.
export HOME=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2> /dev/null | awk '{print $2}')
[[ -d $HOME ]] || export HOME="/Users/$(id -un)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if ! command -v codex > /dev/null; then
    print "Codex isn't installed. Install it (developers.openai.com/codex), then sign in with “codex login” in Terminal." > "$errors"
    exit 1
fi

workdir=$(mktemp -d -t hushh-codex) || exit 1
trap 'rm -rf "$workdir"' EXIT
codex exec --ephemeral --skip-git-repo-check --sandbox read-only --color never \
    --cd "$workdir" "${codex_args[@]}" \
    --output-last-message "$answer" -- - < "$prompt" > /dev/null 2> "$errors"
