#!/bin/zsh
# Hushh's link to Codex, for Catch Up, Draft a Reply, Polish and Translate.
#
# Hushh runs in the macOS app sandbox, so it can't start other programs itself. Scripts you put
# in its Application Scripts folder (~/Library/Application Scripts/com.macneil.Hush) are the
# exception: macOS runs them for it, as you, outside the sandbox. scripts/install.sh puts this
# one there; so does Hushh → Settings → AI → Set Up Codex.
#
#   codex-bridge.sh --session [model]
#       Keeps Codex ready for Hushh: starts Codex's app server and a fresh chat, which connects
#       to OpenAI without sending anything, then waits. Each line Hushh writes to standard input
#       is a request, {"prompt", "answer", "errors", "effort", "images"} (file paths, a reasoning
#       effort, picture paths), answered in that chat; then a fresh one is started for the next.
#       Twenty idle minutes, or Hushh closing standard input, ends the session.
#   codex-bridge.sh prompt answer errors [effort] [model] [pictures…]
#       Answers one request and exits (the way Hushh worked before sessions).
#
# Standard output gets the answer as Codex writes it, as Codex's item/agentMessage/delta lines,
# and Hushh's own status lines: {"hushh":"ready"}, {"hushh":"done","status":…} after each
# request, {"hushh":"failed","message":…} when the session can't go on. The whole answer goes in
# the answer file, what went wrong in the errors file.
#
# This script, not Hushh, decides how Codex runs: in an empty folder, unable to change files
# (read-only sandbox), never asking to run anything, keeping no history (ephemeral), with short
# instructions for chat instead of Codex's coding ones, and without its tools (web search,
# plugins, apps, MCP servers): a chat request needs none, and they make every request bigger.
set -u

if [[ ${1:-} == --session ]]; then
    session=true model=${2:-}
else
    session=false
    prompt=$1 answer=$2 errors=$3 effort=${4:-low} model=${5:-}
    shift $(( $# < 5 ? $# : 5 ))
    images=("$@")
fi

# Started for a sandboxed app, whose HOME is its container: Codex and its sign-in live in your
# real home folder, and the usual places Codex is installed aren't on the PATH.
export HOME=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2> /dev/null | awk '{print $2}')
[[ -d $HOME ]] || export HOME="/Users/$(id -un)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Says why Codex can't help, and stops.
give_up() {
    if $session; then
        jq -nc --arg message "$1" '{hushh: "failed", message: $message}'
    else
        print -r -- "$1" >> "$errors"
    fi
    exit 1
}

if ! command -v jq > /dev/null; then
    message="Hushh's Codex script needs jq, which comes with macOS 15 and later."
    if $session; then print -r -- "{\"hushh\":\"failed\",\"message\":\"$message\"}"; else print -r -- "$message" > "$errors"; fi
    exit 1
fi
command -v codex > /dev/null || give_up "Codex isn't installed. Install it (developers.openai.com/codex), then sign in with “codex login” in Terminal."

instructions="You help someone read and write their Telegram chats on their Mac. Do exactly what \
each request asks and answer with the requested text only. Never run commands, open files or use \
tools: everything you need is in the request."
codex_args=(-c web_search=disabled)
# Unknown names are ignored, so features a Codex version doesn't have do no harm.
for feature in apps plugins plugin_discovery_prefetch computer_use browser_use in_app_browser \
    image_generation multi_agent goals hooks shell_tool unified_exec skill_search tool_suggest sleep_tool; do
    codex_args+=(-c "features.$feature=false")
done
# Then the MCP servers still on, which are the ones in your config.toml (naming one that isn't,
# such as a plugin's, would break Codex's config).
for name in ${(f)"$(codex "${codex_args[@]}" mcp list --json 2> /dev/null | jq -r '.[] | select(.enabled == true) | .name' 2> /dev/null)"}; do
    [[ $name == *.* ]] || codex_args+=(-c "mcp_servers.$name.enabled=false")
done

workdir=$(mktemp -d -t hushh-codex) || exit 1
coproc codex app-server "${codex_args[@]}" 2> "$workdir/codex.log"
server=$!
trap 'kill $server 2> /dev/null; rm -rf "$workdir"' EXIT

send() { print -p -r -- "$1" }

# Reads Codex's next line into $line, with its $id, $method and error $message. Refuses Codex's
# own requests (approvals, questions): nothing Hushh asks needs them. Gives up when Codex stops,
# or is silent for three minutes.
receive() {
    while true; do
        if ! read -p -t 180 -r line; then
            kill -0 $server 2> /dev/null && give_up "Codex took too long to answer. Try again."
            give_up "$(grep -v '^[[:space:]]*$' "$workdir/codex.log" | tail -n 1 || true)"
        fi
        if [[ $line == *'"method":"item/agentMessage/delta"'* ]]; then
            id= method=item/agentMessage/delta message=
            return 0
        fi
        fields=$(jq -r '[(.id // "" | tostring), (.method // ""),
            (.error.message // .params.error.message // .params.turn.error.message // "")]
            | map(gsub("[\\t\\n\\r]"; " ")) | join("\u001f")' <<< "$line" 2> /dev/null) || continue
        IFS=$'\x1f' read -r id method message <<< "$fields"
        if [[ -n $id && -n $method ]]; then
            send "$(jq -c '{id, error: {code: -32601, message: "Hushh does not allow this."}}' <<< "$line")"
            continue
        fi
        return 0
    done
}

# Sends a request and waits for Codex's reply to it, in $line (and its error in $message).
last_id=0
call() {
    local mine=$(( ++last_id ))
    send "$(jq -c --argjson id $mine '{id: $id} + .' <<< "$1")"
    while receive; do
        [[ $method == item/agentMessage/delta ]] && print -r -- "$line"
        [[ $id == "$mine" ]] && return 0
    done
}

# A fresh chat, in $thread: Codex connects to OpenAI for it right away.
start_thread() {
    call "$(jq -nc --arg cwd "$workdir" --arg model "$model" --arg base "$instructions" '{method: "thread/start", params: (
        {ephemeral: true, cwd: $cwd, sandbox: "read-only", approvalPolicy: "never", baseInstructions: $base}
        + (if $model == "" then {} else {model: $model} end))}')"
    thread=$(jq -r '.result.thread.id // empty' <<< "$line")
    [[ -n $thread ]] || give_up "Codex: ${message:-it couldn't start.}"
}

# Codex answers $prompt (with $images) in $thread: pieces to standard output as they come, the
# answer to $answer, what went wrong to $errors.
respond() {
    : > "$answer"
    call "$(jq -nc --arg thread "$thread" --arg effort "$effort" --rawfile text "$prompt" '{method: "turn/start", params: {
        threadId: $thread, effort: $effort,
        input: ([{type: "text", text: $text}] + ($ARGS.positional | map({type: "localImage", path: .})))}}' --args "${images[@]}")"
    if [[ -n $message ]]; then
        print -r -- "Codex: $message" >> "$errors"
        return 1
    fi
    while receive; do
        case $method in
            item/agentMessage/delta)
                print -r -- "$line"
                ;;
            item/completed)
                if jq -e '.params.item.type == "agentMessage"' <<< "$line" > /dev/null; then
                    jq -j '.params.item.text' <<< "$line" > "$answer"
                fi
                ;;
            error)
                [[ -n $message ]] && print -r -- "Codex: $message" >> "$errors"
                ;;
            turn/completed)
                [[ $(jq -r '.params.turn.status' <<< "$line") == completed ]] && return 0
                print -r -- "Codex: ${message:-it stopped before answering.}" >> "$errors"
                return 1
                ;;
        esac
    done
}

call '{"method": "initialize", "params": {"clientInfo": {"name": "hushh", "title": "Hushh", "version": "2"}}}'
[[ -n $message ]] && give_up "Codex: $message"
send '{"method": "initialized"}'
start_thread

if ! $session; then
    respond
    exit $?
fi

print -r -- '{"hushh":"ready"}'
while read -t 1200 -r request; do
    prompt=$(jq -r '.prompt' <<< "$request")
    answer=$(jq -r '.answer' <<< "$request")
    errors=$(jq -r '.errors' <<< "$request")
    effort=$(jq -r '.effort // "low"' <<< "$request")
    images=(${(f)"$(jq -r '.images[]?' <<< "$request")"})
    if respond; then outcome=completed; else outcome=failed; fi
    jq -nc --arg status "$outcome" '{hushh: "done", status: $status}'
    start_thread
    print -r -- '{"hushh":"ready"}'
done
