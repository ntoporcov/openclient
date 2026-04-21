#!/bin/zsh

set -euo pipefail

base_url="${OPENCODE_BASE_URL:-http://127.0.0.1:4096}"
tmp_file="$(mktemp -t opencode-streaming.XXXXXX)"

cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

session_json="$(curl --silent --fail -X POST -H "Content-Type: application/json" "$base_url/session" -d '{"title":"Streaming Integration Probe"}')"
session_id="$(printf '%s' "$session_json" | jq -r '.id')"

if [[ -z "$session_id" || "$session_id" == "null" ]]; then
  print -u2 "Failed to create session"
  exit 1
fi

(curl -N --silent --max-time 15 "$base_url/event" > "$tmp_file") &
stream_pid=$!

sleep 1

curl --silent --fail -X POST -H "Content-Type: application/json" \
  "$base_url/session/$session_id/prompt_async" \
  -d '{"parts":[{"type":"text","text":"Reply with exactly: streaming integration ok"}]}' > /dev/null

wait "$stream_pid" || true

if ! /usr/bin/grep -q '"type":"message.part.delta"' "$tmp_file"; then
  print -u2 "Missing message.part.delta event"
  exit 1
fi

if ! /usr/bin/grep -q 'streaming integration ok' "$tmp_file"; then
  print -u2 "Missing final streamed text"
  exit 1
fi

if ! /usr/bin/grep -q '"type":"session.idle"' "$tmp_file"; then
  print -u2 "Missing session.idle event"
  exit 1
fi

print "Streaming integration passed for $session_id"
