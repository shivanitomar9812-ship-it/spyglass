#!/bin/bash
# send.sh: allow-lists, stale-prompt guards, and the /model flow (with and without Claude Code's "Switch model?" dialog),
# run as the panel runs it (launchd PATH). A fake HOME keeps the real settings.json out of it.
source "$(dirname "$0")/lib.sh"
export FAKE_HOME="$TMP/home" SPYGLASS_HOME="$TMP/spyglass" SPYGLASS_SEND_LOG="$TMP/typed.log"
mkdir -p "$FAKE_HOME/.claude/projects/p" "$SPYGLASS_HOME/sessions"
settings="$FAKE_HOME/.claude/settings.json"
send() { launchd bash "$SCRIPTS/send.sh" vscode "" "" "" "" 1 "$@"; }
typed() { tr '\n' '|' < "$SPYGLASS_SEND_LOG" 2>/dev/null; }

# Allow-lists: nothing outside them is typed.
: > "$SPYGLASS_SEND_LOG"
for bad in "rm -rf ~" "/model gpt" "key:other" "constructor" "rename:$(printf 'a\nb')" "rename:$(printf 'x\033[2J')" "rename:" "rename: lead"; do
  send "$bad" sid >/dev/null 2>&1; rc=$?; eq "refused: $(printf %q "$bad" | cut -c1-20)" 3 $rc
done
eq "nothing typed for refused input" "" "$(typed)"

# Permission answers only while the same prompt is pending (a stale Esc would interrupt a working session).
echo '{"status":"waiting","permission":{"at":100}}' > "$SPYGLASS_HOME/sessions/s1.json"
send key:deny s1 99 >/dev/null 2>&1; eq "stale prompt refused" 4 $?
send key:deny s1 >/dev/null 2>&1; eq "deny without timestamp refused" 3 $?
send key:approve s1 100; eq "pending prompt answered" 0 $?
eq "approve types 1" "key:approve|" "$(typed)"
eq "answered prompt cleared" "null|working" "$(jq -r '"\(.permission)|\(.status)"' "$SPYGLASS_HOME/sessions/s1.json")"
: > "$SPYGLASS_SEND_LOG"; send key:deny s1 100 >/dev/null 2>&1; eq "replay after answer refused" 4 $?

# Answers: only for the pending question, only existing options.
echo '{"status":"waiting","question":{"text":"Which?","options":["Apple","Banana"],"at":200}}' > "$SPYGLASS_HOME/sessions/q1.json"
: > "$SPYGLASS_SEND_LOG"
send answer:3 q1 200 >/dev/null 2>&1; eq "answer beyond options refused" 4 $?
send answer:2 q1 199 >/dev/null 2>&1; eq "stale question refused" 4 $?
send answer:5 q1 200 >/dev/null 2>&1; eq "answer:5 not allowed" 3 $?
send answer:2 q1 200; eq "answer sent" 0 $?
eq "answer types its number" "key:2|" "$(typed)"
eq "question cleared" "null|working" "$(jq -r '"\(.question)|\(.status)"' "$SPYGLASS_HOME/sessions/q1.json")"

# /model: fake Claude applies it (writes the transcript and saves the default, like the real one).
# dialog=1: it first waits for Enter, like "Switch model?" on a cached conversation.
fake_claude() {   # fake_claude <transcript> <dialog 0|1> <model>
  local tp="$1" dialog="$2" m="$3"
  for _ in $(seq 1 50); do grep -q "^/model $m" "$SPYGLASS_SEND_LOG" 2>/dev/null && break; sleep 0.1; done
  if [ "$dialog" = 1 ]; then for _ in $(seq 1 60); do grep -q '^key:enter' "$SPYGLASS_SEND_LOG" && break; sleep 0.1; done
    grep -q '^key:enter' "$SPYGLASS_SEND_LOG" || return; fi
  echo "{\"message\":{\"content\":\"<local-command-stdout>Set model to $m</local-command-stdout>\"}}" >> "$tp"
  sleep 0.3; echo "{\"model\":\"$m\",\"theme\":\"dark\"}" > "$settings"
}
for dialog in 0 1; do
  tp="$FAKE_HOME/.claude/projects/p/m$dialog.jsonl"; echo '{}' > "$tp"
  echo '{"theme":"dark"}' > "$settings"; : > "$SPYGLASS_SEND_LOG"
  fake_claude "$tp" $dialog sonnet &
  send "/model sonnet" "m$dialog"; rc=$?; wait
  eq "model dialog=$dialog exit" 0 $rc
  [ $dialog = 0 ] && eq "no dialog: no Enter sent" "/model sonnet|" "$(typed)"
  [ $dialog = 1 ] && eq "dialog: confirmed with Enter" "/model sonnet|key:enter|" "$(typed)"
  # Escaped bug (0.8.0): the default was restored before the dialog was confirmed, then Claude saved over it.
  eq "default model left unset (dialog=$dialog)" "null|dark" "$(jq -r '"\(.model)|\(.theme)"' "$settings")"
done
# Never applied: report failure, don't touch settings.
tp="$FAKE_HOME/.claude/projects/p/m9.jsonl"; echo '{}' > "$tp"; echo '{"model":"opus"}' > "$settings"
send "/model haiku" m9 >/dev/null 2>&1; eq "not applied -> exit 1" 1 $?
eq "settings untouched on failure" "opus" "$(jq -r .model "$settings")"

# Rename: /rename, then the tab; the row shows the custom name at once.
tp="$FAKE_HOME/.claude/projects/p/r1.jsonl"; echo '{}' > "$tp"; echo '{"title":"Auto","titleSource":"ai"}' > "$SPYGLASS_HOME/sessions/r1.json"
: > "$SPYGLASS_SEND_LOG"
( for _ in $(seq 1 50); do grep -q '^/rename' "$SPYGLASS_SEND_LOG" && break; sleep 0.1; done
  echo '{"type":"custom-title","customTitle":"Seg Lifecycle ✓"}' >> "$tp" ) &
send "rename:Seg Lifecycle ✓" r1; rc=$?; wait
eq "rename exit" 0 $rc
eq "rename typed then tab" "/rename Seg Lifecycle ✓|tabname:Seg Lifecycle ✓|" "$(typed)"
eq "row shows custom name" "Seg Lifecycle ✓|custom" "$(jq -r '"\(.title)|\(.titleSource)"' "$SPYGLASS_HOME/sessions/r1.json")"

# Routing: each terminal gets only what it can take. Terminal.app's `do script` adds Enter, so no single keys there.
export SPYGLASS_SEND_ROUTE=1
pending() { echo '{"status":"waiting","permission":{"at":1},"question":{"text":"Q","options":["A","B"],"at":1}}' > "$SPYGLASS_HOME/sessions/rt.json"; }
r() { pending; out=$(launchd bash "$SCRIPTS/send.sh" "$1" /dev/ttys001 "" "" "" 123 "$2" rt 1 2>/dev/null); rc=$?; echo "${out%%$'\n'*}|$rc"; }
eq "iTerm: answer key"          "iterm key:2|0"          "$(r iTerm.app answer:2)"
eq "Cursor: model text"         "vscode /model opus|0"   "$(r vscode '/model opus')"
eq "Terminal: model text"       "terminal /model opus|0" "$(r Apple_Terminal '/model opus')"
eq "Terminal: no Deny key"      "none key:deny|2"        "$(r Apple_Terminal key:deny)"
eq "Terminal: no answer key"    "none key:1|2"           "$(r Apple_Terminal answer:1)"
eq "cmux: not possible"         "none /model opus|2"     "$(r cmux '/model opus')"
unset SPYGLASS_SEND_ROUTE

# Escaped bug (0.6.1): under launchd, jq was not on PATH and nothing reached Cursor.
eq "send.sh finds jq under launchd" "ok" "$(launchd bash -c "eval \"\$(grep '^export PATH' '$SCRIPTS/send.sh')\"; command -v jq >/dev/null && echo ok")"
finish
