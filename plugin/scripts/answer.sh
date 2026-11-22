#!/bin/bash
# PermissionRequest hook: lets the Spyglass panel answer a permission prompt (Allow once / Deny) in any host where hooks
# run - iTerm2, Terminal.app, Cursor / VS Code (terminal or Claude panel), JetBrains, cmux - without typing keys.
#
# Claude Code shows its own prompt while this waits, and the first answer wins: answer in the terminal and this hook's
# answer is ignored; answer in Spyglass and the terminal prompt closes. So this never blocks you.
# It waits only while the panel is running, and exits as soon as the prompt is resolved anywhere.
# No output = no decision (the normal prompt carries on).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
in=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
tool=$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null)
[ -n "$sid" ] || exit 0
# Questions are answered by key (their answer format through a hook isn't documented); only tool permissions here.
[ "$tool" = "AskUserQuestion" ] && exit 0
# Only while the panel is running (tests set SPYGLASS_ASSUME_PANEL=1).
[ "${SPYGLASS_ASSUME_PANEL:-}" = 1 ] || pgrep -f "^$home/Spyglass$" >/dev/null || exit 0

# Fingerprint of this exact tool call; record.sh stores the same one, and Spyglass's answer must carry it.
key=$(jq -cS '.tool_input // {}' <<<"$in" | shasum -a 256 | cut -c1-16)
answer="$home/answers/$sid.json"
session="$home/sessions/$sid.json"
mkdir -p "$home/answers"

poll="${SPYGLASS_ANSWER_POLL:-0.25}"
seen=0; waited=0
while :; do
  if [ -f "$answer" ] && [ "$(jq -r '.key // empty' "$answer" 2>/dev/null)" = "$key" ]; then
    behavior=$(jq -r '.behavior // empty' "$answer" 2>/dev/null)
    rm -f "$answer"
    f="$session"
    if [ "$behavior" = allow ]; then
      jq --arg k "$key" 'if .permission.key == $k then del(.permission) | .status = "working" | .activity = "Approved from Spyglass" else . end' \
        "$f" > "$f.answer.tmp" 2>/dev/null && mv "$f.answer.tmp" "$f" || rm -f "$f.answer.tmp"
      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    elif [ "$behavior" = deny ]; then
      jq --arg k "$key" 'if .permission.key == $k then del(.permission) | .status = "idle" | .activity = "Denied from Spyglass" else . end' \
        "$f" > "$f.answer.tmp" 2>/dev/null && mv "$f.answer.tmp" "$f" || rm -f "$f.answer.tmp"
      # interrupt: stop the turn and wait for you, the same as pressing Esc.
      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Spyglass","interrupt":true}}}'
    fi
    exit 0
  fi
  # Resolved elsewhere (answered in the terminal, auto-approved, a new prompt, session gone): stop waiting.
  pending=$(jq -r '.permission.key // empty' "$session" 2>/dev/null)
  if [ "$pending" = "$key" ]; then seen=1
  elif [ $seen = 1 ] || [ ! -f "$session" ]; then exit 0
  elif awk "BEGIN { exit !($waited > 10) }"; then exit 0   # record.sh never marked it pending
  fi
  sleep "$poll"; waited=$(awk "BEGIN { print $waited + $poll }")
done
