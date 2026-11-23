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

# Replies to a question asked in text: typed + Enter, only while it waits with nothing else open.
echo '{"status":"waiting","asked":{"text":"Shall I go ahead?","at":1}}' > "$SPYGLASS_HOME/sessions/rp.json"
: > "$SPYGLASS_SEND_LOG"
send "reply:yes, go ahead" rp; eq "reply sent" 0 $?
eq "reply typed as say:" "say:yes, go ahead|" "$(typed)"
eq "row marked replied" "working|null" "$(jq -r '"\(.status)|\(.asked)"' "$SPYGLASS_HOME/sessions/rp.json")"
for bad in "/model opus" "$(printf 'a\nb')" "" " lead"; do
  echo '{"status":"waiting","asked":{"text":"Q?","at":1}}' > "$SPYGLASS_HOME/sessions/rp.json"
  send "reply:$bad" rp >/dev/null 2>&1; rc=$?; eq "reply refused: $(printf %q "$bad" | cut -c1-14)" 3 $rc
done
echo '{"status":"waiting","asked":{"text":"Q?","at":1},"permission":{"at":2}}' > "$SPYGLASS_HOME/sessions/rp.json"
send "reply:yes" rp >/dev/null 2>&1; rc=$?; eq "reply refused while a prompt is open" 4 $rc
echo '{"status":"working"}' > "$SPYGLASS_HOME/sessions/rp.json"
send "reply:yes" rp >/dev/null 2>&1; rc=$?; eq "reply refused while working" 4 $rc

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
echo '{"status":"done","asked":{"text":"Q?","at":1}}' > "$SPYGLASS_HOME/sessions/rt.json"
eq "Terminal: reply typed"      "terminal say:yes|0"     "$(out=$(launchd bash "$SCRIPTS/send.sh" Apple_Terminal /dev/ttys001 "" "" "" 123 "reply:yes" rt 2>/dev/null); rc=$?; echo "${out%%$'\n'*}|$rc")"
unset SPYGLASS_SEND_ROUTE

# Remote Control: /remote-control connects; disconnecting is a menu (Up, Up, Enter), driven only where the menu can be checked.
reg="$FAKE_HOME/.claude/sessions/1.json"; mkdir -p "$(dirname "$reg")"
echo '{"pid":1,"sessionId":"rc1"}' > "$reg"; echo '{"status":"idle"}' > "$SPYGLASS_HOME/sessions/rc1.json"
rc_send() { launchd env SPYGLASS_RC_WAIT=15 bash "$SCRIPTS/send.sh" "${APP:-vscode}" "${TTY_:-}" "" "" "" 1 "$@"; }
connect()    { echo '{"pid":1,"sessionId":"rc1","bridgeSessionId":"session_x"}' > "$reg"; }
disconnect() { echo '{"pid":1,"sessionId":"rc1"}' > "$reg"; }
: > "$SPYGLASS_SEND_LOG"; rc_send rc:maybe rc1 >/dev/null 2>&1; eq "rc:maybe refused" 3 $?
rc_send rc:on >/dev/null 2>&1; eq "rc:on without a session refused" 3 $?
echo '{"status":"working"}' > "$SPYGLASS_HOME/sessions/rc1.json"
rc_send rc:on rc1 >/dev/null 2>&1; eq "rc:on refused while working" 4 $?
echo '{"status":"waiting"}' > "$SPYGLASS_HOME/sessions/rc1.json"
rc_send rc:off rc1 >/dev/null 2>&1; eq "rc:off refused while waiting" 4 $?
eq "nothing typed for refused rc" "" "$(typed)"
echo '{"status":"idle"}' > "$SPYGLASS_HOME/sessions/rc1.json"
# Connect: types /remote-control and waits for Claude Code to record the connection.
disconnect; : > "$SPYGLASS_SEND_LOG"
( sleep 0.4; connect ) & w=$!; rc_send rc:on rc1; rc=$?; wait $w
eq "rc:on exit" 0 $rc; eq "rc:on typed the command" "/remote-control|" "$(typed)"
# Already connected: no second /remote-control (that would open the menu).
: > "$SPYGLASS_SEND_LOG"; rc_send rc:on rc1; eq "rc:on when connected: ok" 0 $?; eq "...types nothing" "" "$(typed)"
# Never connects: reported as failed.
disconnect; : > "$SPYGLASS_SEND_LOG"; rc_send rc:on rc1 >/dev/null 2>&1; eq "rc:on that never connects fails" 1 $?
# Disconnect when it isn't connected: nothing to do, and nothing typed.
disconnect; : > "$SPYGLASS_SEND_LOG"; rc_send rc:off rc1; eq "rc:off when not connected: ok" 0 $?; eq "...types nothing" "" "$(typed)"
# Disconnect in Cursor / VS Code (can't read the screen): opens the menu only, no blind arrow keys. Exit 5.
connect; : > "$SPYGLASS_SEND_LOG"; rc_send rc:off rc1 >/dev/null 2>&1; eq "rc:off in Cursor opens the menu (exit 5)" 5 $?
eq "...and presses no keys" "/remote-control|" "$(typed)"
# Disconnect in Terminal.app: same.
connect; : > "$SPYGLASS_SEND_LOG"; APP=Apple_Terminal TTY_=/dev/ttys001 rc_send rc:off rc1 >/dev/null 2>&1; eq "rc:off in Terminal opens the menu (exit 5)" 5 $?
eq "...and presses no keys" "/remote-control|" "$(typed)"
# Disconnect in iTerm2: the menu, Up, Up, Enter on "Disconnect this session".
connect; : > "$SPYGLASS_SEND_LOG"
( sleep 0.6; disconnect ) & w=$!; APP=iTerm.app TTY_=/dev/ttys001 rc_send rc:off rc1; rc=$?; wait $w
eq "rc:off in iTerm exit" 0 $rc; eq "rc:off in iTerm keys" "/remote-control|key:up|key:up|key:select|" "$(typed)"
# Disconnect that doesn't take: failed.
connect; : > "$SPYGLASS_SEND_LOG"; APP=iTerm.app TTY_=/dev/ttys001 rc_send rc:off rc1 >/dev/null 2>&1; eq "rc:off that doesn't take fails" 1 $?

finish
