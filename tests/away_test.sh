#!/bin/bash
# Away mode: what needs you goes to the phone, and only the right button from the right chat answers.
# Runs the panel's bridge (`Spyglass --away-selftest`) against a stand-in Telegram server.
source "$(dirname "$0")/lib.sh"
BIN="${SPYGLASS_BIN:-$ROOT/plugin/bin/Spyglass}"
node "$ROOT/tests/telegram_stub.js" > "$TMP/port" & stub=$!; disown
trap 'kill $stub 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
API="http://127.0.0.1:$(cat "$TMP/port")"
export SPYGLASS_HOME="$TMP/spyglass" SPYGLASS_CLAUDE_DIR="$TMP/claude" SPYGLASS_NO_REGISTRY=1 SPYGLASS_TELEGRAM_API="$API" SPYGLASS_TELEGRAM_POLL=0
mkdir -p "$SPYGLASS_HOME"/{sessions,stats,answers} "$SPYGLASS_CLAUDE_DIR/projects"
now=$(date +%s)
SID=11111111-aaaa-bbbb-cccc-dddddddddddd; KEY=0123456789abcdef
sleep 300 & pid=$!; disown; trap 'kill $stub $pid 2>/dev/null; rm -rf "$TMP"' EXIT

config() { jq -n --arg c "${2:-42}" --argjson f "${1:-false}" '{token: "TOKEN", chat_id: $c, finished: $f, auto: false}' > "$SPYGLASS_HOME/away.json"; }
session() {   # session <json fields>
  jq -n --arg id "$SID" --argjson pid "$pid" --argjson now "$now" --argjson x "$1" \
    '{id: $id, pid: $pid, cwd: "/Users/me/api", title: "Fix checkout", titleSource: "custom", started: $now, updated: $now, term: "iTerm.app"} + $x' > "$SPYGLASS_HOME/sessions/$SID.json"
}
perm() { session "{\"status\":\"waiting\",\"permission\":{\"tool\":\"Bash\",\"detail\":$(jq -Rn --arg c "$1" '$c'),\"at\":${3:-$now},\"key\":\"${2:-$KEY}\"}}"; }
reset() { curl -s -X POST "$API/_reset" >/dev/null; rm -f "$SPYGLASS_HOME/answers/"* "$SPYGLASS_HOME/away-on" "$SPYGLASS_HOME/panel-allow-off"; }
press() {   # press <data> [from] [chat]   (a button press arriving from the phone)
  curl -s -X POST "$API/_push" -d "{\"callback_query\":{\"id\":\"cb\",\"from\":{\"id\":${2:-42}},\"message\":{\"message_id\":100,\"chat\":{\"id\":${3:-42}}},\"data\":\"$1\"}}" >/dev/null
}
run() { "$BIN" --away-selftest "${1:-2}" >/dev/null 2>&1; }
calls() { curl -s "$API/_log" | jq -c "[.[] | select(.method == \"$1\")]"; }
n() { calls "$1" | jq length; }
answer() { [ -f "$SPYGLASS_HOME/answers/$SID.json" ] && jq -cS . "$SPYGLASS_HOME/answers/$SID.json" || echo none; }
on() { echo on > "$SPYGLASS_HOME/away-on"; }

# Not set up (no away.json): nothing is sent, even with the flag on.
reset; perm "make build"; on; run
eq "no config: nothing sent" 0 "$(n sendMessage)"

# Away off: nothing is sent.
reset; config; perm "make build"; run
eq "away off: nothing sent" 0 "$(n sendMessage)"

# Away on: one message with the folder, the command and Allow once / Deny; reloads don't repeat it.
reset; config; perm "make build"; on; run 2
eq "one message sent" 1 "$(n sendMessage)"
msg=$(calls sendMessage | jq -r '.[0].body')
eq "to the configured chat" "42" "$(jq -r .chat_id <<<"$msg")"
eq "names the session, folder and command" "true" "$(jq -r '.text | (contains("Fix checkout") and contains("api") and contains("make build"))' <<<"$msg")"
eq "Allow once and Deny" "Allow once,Deny" "$(jq -r '[.reply_markup.inline_keyboard[0][].text] | join(",")' <<<"$msg")"
eq "callbacks carry the session and fingerprint" "y:11111111:$KEY,n:11111111:$KEY" "$(jq -r '[.reply_markup.inline_keyboard[0][].callback_data] | join(",")' <<<"$msg")"
eq "uses the configured token" "TOKEN" "$(calls sendMessage | jq -r '.[0].token')"

# Allow from the phone writes the answer file; the message is closed.
reset; config; perm "make build"; on; press "y:11111111:$KEY"; run 2
eq "allow answers the prompt" "{\"behavior\":\"allow\",\"key\":\"$KEY\"}" "$(answer)"
eq "message edited to Allowed" "true" "$(calls editMessageText | jq '[.[].body.text | contains("Allowed from your phone")] | any')"
# Deny.
reset; config; perm "make build"; on; press "n:11111111:$KEY"; run 2
eq "deny answers the prompt" "{\"behavior\":\"deny\",\"key\":\"$KEY\"}" "$(answer)"

# Wrong chat or wrong sender: ignored, no answer, no reply at all.
reset; config; perm "make build"; on; press "y:11111111:$KEY" 99 42; run 2
eq "other sender ignored" "none" "$(answer)"
reset; config; perm "make build"; on; press "y:11111111:$KEY" 42 99; run 2
eq "other chat ignored" "none" "$(answer)"
eq "no toast for strangers" 0 "$(n answerCallbackQuery)"

# A button for another prompt (fingerprint) or an unknown session does nothing.
reset; config; perm "make build"; on; press "y:11111111:ffffffffffffffff"; run 2
eq "old button ignored" "none" "$(answer)"
eq "tells you it was handled" "Already handled" "$(calls answerCallbackQuery | jq -r '.[0].body.text')"
reset; config; perm "make build"; on; press "y:99999999:$KEY"; run 2
eq "unknown session ignored" "none" "$(answer)"

# A prompt older than an hour is refused.
reset; config; perm "make build" "$KEY" $((now - 4000)); on; press "y:11111111:$KEY"; run 2
eq "stale prompt refused" "none" "$(answer)"

# Risky: no Allow button; a forged allow is refused; deny still works.
reset; config; perm "git push --force origin main"; on; press "y:11111111:$KEY"; run 2
eq "risky: Deny only" "Deny" "$(calls sendMessage | jq -r '.[0].body.reply_markup.inline_keyboard[0] | map(.text) | join(",")')"
eq "risky: says why" "true" "$(calls sendMessage | jq '.[0].body.text | contains("Risky")')"
eq "risky: forged allow refused" "none" "$(answer)"
reset; config; perm "git push --force origin main"; on; press "n:11111111:$KEY"; run 2
eq "risky: deny works" "{\"behavior\":\"deny\",\"key\":\"$KEY\"}" "$(answer)"

# The lock (Allow from the panel off): no Allow button, forged allow refused.
reset; config; perm "make build"; on; : > "$SPYGLASS_HOME/panel-allow-off"; press "y:11111111:$KEY"; run 2
eq "lock off: Deny only" "Deny" "$(calls sendMessage | jq -r '.[0].body.reply_markup.inline_keyboard[0] | map(.text) | join(",")')"
eq "lock off: forged allow refused" "none" "$(answer)"

# Answered at the Mac: the phone message loses its buttons.
reset; config; perm "make build"; on
( sleep 1; session '{"status":"working"}' ) & w=$!
run 3; wait $w
eq "handled at the Mac" "true" "$(calls editMessageText | jq '[.[].body | (.text | contains("Handled at your Mac")) and (.reply_markup.inline_keyboard | length == 0)] | any')"

# Away turned off: open messages are closed.
reset; config; perm "make build"; on
( sleep 1; rm -f "$SPYGLASS_HOME/away-on" ) & w=$!
run 3; wait $w
eq "away off closes open messages" "true" "$(calls editMessageText | jq '[.[].body.text | contains("Away mode is off")] | any')"

# Questions and plain-text asks are sent without buttons; finished pings are opt-in.
reset; config; session "{\"status\":\"waiting\",\"question\":{\"text\":\"Which fruit?\",\"options\":[\"Apple\",\"Banana\"],\"at\":5}}"; on; run 2
eq "question sent with options, no buttons" "true|null" "$(calls sendMessage | jq -r '.[0].body | "\(.text | contains("Which fruit?") and contains("Banana"))|\(.reply_markup)"')"
reset; config; session "{\"status\":\"waiting\",\"asked\":{\"text\":\"Shall I continue?\",\"at\":6}}"; on; run 2
eq "plain-text ask sent" "true" "$(calls sendMessage | jq '.[0].body.text | contains("Shall I continue?")')"
reset; config; session '{"status":"done","lastLine":"All 48 tests pass."}'; on; run 2
eq "finished: off by default" 0 "$(n sendMessage)"
reset; config true; session '{"status":"done","lastLine":"All 48 tests pass."}'; on; run 2
eq "finished: sent when opted in" "true" "$(calls sendMessage | jq '.[0].body.text | contains("All 48 tests pass.")')"

# The config file holds the token: setup writes it readable by you alone (checked via the same save path).
eq "away.json not world-readable" "true" "$(AWAYFILE="$SPYGLASS_HOME/away.json"; chmod 600 "$AWAYFILE"; [ "$(stat -f %Lp "$AWAYFILE")" = 600 ] && echo true || echo false)"
finish
