#!/bin/bash
# answer.sh: Spyglass answers permission prompts through the PermissionRequest hook (any host, no keystrokes).
source "$(dirname "$0")/lib.sh"
export SPYGLASS_HOME="$TMP/spyglass"; mkdir -p "$SPYGLASS_HOME/sessions"
export SPYGLASS_ANSWER_POLL=0.05
req='{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"x"}}'
record() { launchd bash "$SCRIPTS/record.sh" <<<"$1"; }
hook() { launchd env SPYGLASS_ASSUME_PANEL="${PANEL:-1}" SPYGLASS_ANSWER_POLL=0.05 bash "$SCRIPTS/answer.sh" <<<"$1"; }
key() { jq -r '.permission.key' "$SPYGLASS_HOME/sessions/s.json"; }
answer() { echo "{\"key\":\"$1\",\"behavior\":\"$2\"}" > "$SPYGLASS_HOME/answers/s.json"; }
mkdir -p "$SPYGLASS_HOME/answers"

# No panel running: no waiting, no decision.
out=$(PANEL=0 hook "$req"); eq "no panel: no decision" "" "$out"
# Questions stay on keys.
out=$(hook '{"session_id":"s","tool_name":"AskUserQuestion","tool_input":{}}'); eq "questions skipped" "" "$out"

# Allow: record.sh and answer.sh agree on the fingerprint; the terminal prompt closes with allow.
record "$req"; k=$(key)
eq "fingerprint stored" 16 "${#k}"
( sleep 0.3; answer "$k" allow ) & a=$!
out=$(hook "$req"); wait $a
eq "allow decision" "allow" "$(jq -r '.hookSpecificOutput.decision.behavior' <<<"$out")"
eq "answer file consumed" "no" "$([ -f "$SPYGLASS_HOME/answers/s.json" ] && echo yes || echo no)"
eq "row cleared" "null|working" "$(jq -r '"\(.permission)|\(.status)"' "$SPYGLASS_HOME/sessions/s.json")"

# Deny stops the turn like Esc.
record "$req"; k=$(key)
( sleep 0.3; answer "$k" deny ) & a=$!
out=$(hook "$req"); wait $a
eq "deny decision interrupts" "deny|true" "$(jq -r '.hookSpecificOutput.decision | "\(.behavior)|\(.interrupt)"' <<<"$out")"

# An answer for another prompt is ignored; answering in the terminal (PostToolUse clears it) ends the wait silently.
record "$req"
( sleep 0.3; answer "0000000000000000" allow; sleep 0.3
  record '{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}' ) & a=$!
start=$(date +%s); out=$(hook "$req"); wait $a
eq "wrong fingerprint ignored, exits when resolved elsewhere" "" "$out"
eq "exited promptly" "true" "$([ $(( $(date +%s) - start )) -le 3 ] && echo true || echo false)"
rm -f "$SPYGLASS_HOME/answers/s.json"
finish
