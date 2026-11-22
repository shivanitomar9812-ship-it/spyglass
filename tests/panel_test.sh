#!/bin/bash
# The panel's row logic, via `Spyglass --selftest` on fixtures; also renders tests/out/panel.png to look at.
source "$(dirname "$0")/lib.sh"
BIN="${SPYGLASS_BIN:-$ROOT/plugin/bin/Spyglass}"
# Never test a stale binary (it once read the real ~/.claude state because it predated a rename).
if [ -z "${SPYGLASS_BIN:-}" ] && [ "$ROOT/plugin/app/Spyglass.swift" -nt "$BIN" ]; then
  bash "$ROOT/plugin/app/build.sh" "$BIN" >/dev/null 2>&1 || { echo "build failed"; exit 1; }
fi
export SPYGLASS_HOME="$TMP/spyglass"; mkdir -p "$SPYGLASS_HOME"/{sessions,stats,terminals,ended}
export SPYGLASS_CLAUDE_DIR="$TMP/claude"; mkdir -p "$SPYGLASS_CLAUDE_DIR/projects/-tmp-repo"
now=$(date +%s)
# Each fake session is a sleep under its own subshell, so it has a distinct parent "shell" pid for tab names.
spawn() { ( sleep 120 & echo $! > "$TMP/$1.pid"; wait ) 2>/dev/null & for _ in $(seq 1 20); do [ -s "$TMP/$1.pid" ] && break; sleep 0.05; done; }
pids=()
session() {   # session <id> <json fields...>
  spawn "$1"; local pid; pid=$(cat "$TMP/$1.pid"); pids+=("$pid")
  jq -n --arg id "$1" --argjson pid "$pid" --argjson now "$now" --argjson extra "$2" \
    '{id: $id, pid: $pid, cwd: "/tmp/repo", started: $now, updated: $now, term: "vscode"} + $extra' > "$SPYGLASS_HOME/sessions/$1.json"
}
shell_of() { ps -o ppid= -p "$(cat "$TMP/$1.pid")" | tr -d ' '; }

session idle   '{"title":"Idle one","titleSource":"ai","status":"waiting","activity":"Claude is waiting for your input"}'
session tab    '{"title":"Resume session","titleSource":"ai","status":"done"}'
session custom '{"title":"My rename","titleSource":"custom","status":"done","cwd":"/tmp/k8s-apps"}'
session ver    '{"title":"Platform listing famous repositories","titleSource":"ai","status":"done","cwd":"/tmp/k8s-apps"}'
session ctx    '{"title":"Big context","titleSource":"ai","status":"working","activity":"Reading"}'
session ask    '{"title":"Asks a question","titleSource":"ai","status":"waiting","activity":"Asking you a question","question":{"text":"Which fruit would you like?","options":["Apple","Banana","Cherry"],"at":5}}'
# Old hooks recorded questions as permission prompts: never show Allow/Deny for them.
session oldask '{"title":"Old hook question","titleSource":"ai","status":"waiting","permission":{"tool":"AskUserQuestion","detail":"","at":2}}'
session asked  '{"title":"Asked in text","titleSource":"ai","status":"waiting","activity":"Asked you: Shall I continue?","asked":{"text":"Shall I continue with the welcome card?","at":6}}'
session perm   '{"title":"Needs approval","titleSource":"ai","status":"waiting","activity":"Wants to use Bash","permission":{"tool":"Bash","detail":"rm -rf build","at":1}}'
lim="{\"five_hour\":{\"pct\":17,\"resets\":$((now + 3600))},\"seven_day\":{\"pct\":93,\"resets\":$((now + 400000))}}"
echo "{\"model\":\"Opus 5.5\",\"ctx\":91,\"ctxTokens\":910000,\"ctxSize\":1000000,\"cost\":3300.79,\"limits\":$lim,\"updated\":$now}" > "$SPYGLASS_HOME/stats/ctx.json"
echo "{\"model\":\"Haiku 5.5\",\"ctx\":6,\"cost\":0.4,\"limits\":$lim,\"updated\":$((now - 5))}" > "$SPYGLASS_HOME/stats/tab.json"
# Transcript: one response written as two lines (same message id) must count once; cache reads stay out of "used".
u='"usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":2000,"cache_read_input_tokens":900000}'
{ echo "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",$u}}"
  echo "{\"type\":\"assistant\",\"message\":{\"id\":\"m1\",$u}}"
  echo "{\"type\":\"assistant\",\"message\":{\"id\":\"m2\",$u}}"
  echo '{"type":"user","message":{"content":"no usage here"}}'; } > "$SPYGLASS_CLAUDE_DIR/projects/-tmp-repo/ctx.jsonl"
jq -n --argjson now "$now" --argjson a "$(shell_of tab)" --argjson b "$(shell_of custom)" --argjson c "$(shell_of ver)" \
  '{ts: $now, rows: [{pid: $a, name: "✳ Seg Lifecycle"}, {pid: $b, name: "Some tab"}, {pid: $c, name: "2.1.330"}]}' > "$SPYGLASS_HOME/terminals/1.json"
# A session whose process is gone goes to Recently ended.
echo "{\"id\":\"gone\",\"pid\":999999,\"cwd\":\"/tmp\",\"title\":\"Gone one\",\"prompt\":\"hi\",\"status\":\"done\",\"updated\":$now}" > "$SPYGLASS_HOME/sessions/gone.json"

out=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest 2>/dev/null)
row() { echo "$out" | jq -r --arg id "$1" "select(.id == \$id) | $2"; }
# Escaped bug (0.9.0): the idle reminder showed as "Needs you" (older hooks recorded it as waiting).
eq "idle reminder shows done" "done" "$(row idle .state)"
# Escaped bug (0.16.0): Claude Code's status symbol in tab titles ("✳ Seg Lifecycle") showed in names.
eq "Cursor tab name used, status symbol stripped" "Seg Lifecycle" "$(row tab .name)"
eq "/rename beats tab name" "My rename" "$(row custom .name)"
# Escaped bug (0.9.0): "2.1.330" (Claude Code's process title) was taken as a name you gave the tab.
eq "version tab name ignored" "Platform listing famous repositories" "$(row ver .name)"
eq "context warning at 91%" "true" "$(row ctx .contextFull)"
eq "no warning at 6%" "false" "$(row tab .contextFull)"
eq "permission card" "waiting|rm -rf build" "$(row perm '"\(.state)|\(.permission)"')"
eq "asked in plain text: waiting, question shown" "waiting|Shall I continue with the welcome card?" "$(row asked '"\(.state)|\(.asked)"')"
eq "asked: hover says so" 1 "$(row asked .hover | grep -cF 'Claude asked "Shall I continue')"
eq "question card" "Which fruit would you like?|Apple,Banana,Cherry" "$(row ask .question)"
# Escaped bug (0.12.0): .help tooltips never show on Spyglass's non-activating panel; hover text must use .tip.
eq "no .help tooltips in the panel" 0 "$(grep -c '\.help(' "$ROOT/plugin/app/Spyglass.swift")"
# Escaped bug (0.12.1 local): the hover card was measured without a width, wrapped word by word into a very tall
# window, and showed far from the pointer. Cards must be card-sized.
tip() { echo "$out" | jq -r --arg n "$1" "select(.tip == \$n) | $2"; }
eq "short card is small" "true" "$(tip short '.w < 200 and .h < 60')"
eq "long card wraps at max width" "true" "$(tip long '.w <= 380 and .h < 200 and .h > 40')"
eq "usage card fits two lines" "true" "$(tip usage '.h < 80')"
# Hover text: the facts in one place.
hover() { row "$1" .hover | grep -cF "$2"; }
eq "hover: state with time" 1 "$(hover tab 'Done ')"
eq "hover: folder" 1 "$(hover tab 'Folder: /tmp/repo')"
eq "hover: model and context" 1 "$(hover tab 'Model: Haiku 5.5 · context 6%')"
eq "hover: exact tab" 1 "$(hover tab 'Cursor / VS Code tab “Seg Lifecycle”')"
eq "hover: working for" 1 "$(hover ctx 'Working for')"
eq "hover: question text" 1 "$(hover ask 'Needs you: Claude asks "Which fruit would you like?"')"
eq "context hover: tokens and advice" "1|1" "$(row ctx .ctxHover | grep -cF '91% used (910k of 1.0M tokens)')|$(row ctx .ctxHover | grep -cF 'run /compact')"
eq "rename only when idle/done" "true|false" "$(row tab .canRename)|$(row ctx .canRename)"
eq "tokens: each response once, cache reads excluded" "7000|7k tok" "$(row ctx '"\(.tokens)|\(.usage)"')"
eq "header: limits left" '[{"key":"five_hour","left":83},{"key":"seven_day","left":7}]' "$(echo "$out" | jq -c 'select(.limits) | .limits')"
eq "subscription: no \$ on rows" "" "$(row tab .usage | grep -F '$')"
eq "dead session moved to ended" "Gone one" "$(echo "$out" | jq -r 'select(.ended == "gone") | .name')"
eq "dead session file removed" "no" "$([ -f "$SPYGLASS_HOME/sessions/gone.json" ] && echo yes || echo no)"

# API-key plan (no limits reported): the $ is the real bill, so rows show it.
for f in "$SPYGLASS_HOME"/stats/*.json; do jq 'del(.limits)' "$f" > "$f.t" && mv "$f.t" "$f"; done
out2=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest 2>/dev/null)
eq "API plan shows \$" '$0.40' "$(echo "$out2" | jq -r 'select(.id == "tab") | .usage')"
eq "API plan: no limits line" "[]" "$(echo "$out2" | jq -c 'select(.limits) | .limits')"
for f in "$SPYGLASS_HOME"/stats/*.json; do jq --argjson l "$lim" '. + {limits: $l}' "$f" > "$f.t" && mv "$f.t" "$f"; done

# A hidden panel comes back when a session newly needs you; sessions already waiting don't re-trigger it.
session later '{"title":"Later one","titleSource":"ai","status":"done"}'
( sleep 0.5; f="$SPYGLASS_HOME/sessions/later.json"
  jq '.status = "waiting" | .permission = {tool: "Bash", detail: "make deploy", at: 9}' "$f" > "$f.t" && mv "$f.t" "$f" ) &
flip=$!
wakes=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest --twice 2>/dev/null | jq -c 'select(.wakes) | .wakes'); wait "$flip"
eq "wake on startup (one already waiting) and on the new one only" "2|later" "$(echo "$wakes" | jq -r 'length')|$(echo "$wakes" | jq -r 'last')"
rm -f "$SPYGLASS_HOME/sessions/later.json"

# Past a plan limit: rows show only the $ added since crossing it (extra usage bills at API prices if it's on).
over="{\"five_hour\":{\"pct\":100,\"resets\":$((now + 3600))},\"seven_day\":{\"pct\":40,\"resets\":$((now + 400000))}}"
for f in "$SPYGLASS_HOME"/stats/*.json; do jq --argjson l "$over" '.limits = $l' "$f" > "$f.t" && mv "$f.t" "$f"; done
( sleep 0.5; f="$SPYGLASS_HOME/stats/tab.json"; jq '.cost = 2.5' "$f" > "$f.t" && mv "$f.t" "$f" ) &
flip=$!
out4=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest --twice 2>/dev/null); wait "$flip"
eq "over limit flagged" "true" "$(echo "$out4" | jq -r 'select(.overLimit != null) | .overLimit')"
eq "over limit: \$ added since crossing" '$2.10 extra' "$(echo "$out4" | jq -r 'select(.id == "tab") | .usage')"
eq "over limit: nothing added yet -> still tokens" '7k tok' "$(echo "$out4" | jq -r 'select(.id == "ctx") | .usage')"
mkdir -p "$ROOT/tests/out"
SPYGLASS_NO_REGISTRY=1 "$BIN" --snapshot "$ROOT/tests/out/panel-over-limit.png" --state '{"compact":"true"}' 2>/dev/null
rm -f "$SPYGLASS_HOME/extra.json"; f="$SPYGLASS_HOME/stats/tab.json"; jq '.cost = 0.4' "$f" > "$f.t" && mv "$f.t" "$f"

# Behind a Claude gateway with a spend cap: header shows the spend, rows show $.
gw="{\"spend_limit\":{\"pct\":25,\"resets\":$((now + 86400)),\"usd\":12.5,\"limitUsd\":50}}"
for f in "$SPYGLASS_HOME"/stats/*.json; do jq --argjson l "$gw" '.limits = $l' "$f" > "$f.t" && mv "$f.t" "$f"; done
out5=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest 2>/dev/null)
eq "gateway: spend in header" "12.5" "$(echo "$out5" | jq -r 'select(.spend != null) | .spend')"
eq "gateway: rows show \$" '$0.40' "$(echo "$out5" | jq -r 'select(.id == "tab") | .usage')"
for f in "$SPYGLASS_HOME"/stats/*.json; do jq --argjson l "$lim" '.limits = $l' "$f" > "$f.t" && mv "$f.t" "$f"; done

# Compact view: rows that need you (or are mid-action) stay full; the rest are one line, grouped by repo (6+ sessions).
out3=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest --state '{"confirming:tab":"sonnet","compact":"true"}' 2>/dev/null)
eq "compact: full rows" '["ask","asked","ctx","oldask","perm","tab"]' "$(echo "$out3" | jq -c 'select(.compact) | .compact.full | sort')"
eq "compact: groups by repo" '[{"name":"k8s-apps","rows":["custom","ver"]},{"name":"repo","rows":["idle"]}]' \
  "$(echo "$out3" | jq -c 'select(.compact) | .compact.groups | map(.rows |= sort)')"

# Every place Claude runs: what Spyglass offers there (app | can type text | can press keys).
export SPYGLASS_HOME="$TMP/hosts"; mkdir -p "$SPYGLASS_HOME"/sessions
host() { session "$1" "{\"title\":\"$1\",\"titleSource\":\"ai\",\"status\":\"done\"$2}"; }
host h-iterm    ',"term":"iTerm.app"'
host h-cursor   ',"term":"vscode"'
host h-terminal ',"term":"Apple_Terminal"'
host h-panel    ',"term":"vscode","entrypoint":"claude-vscode","bundle":"com.todesktop.230313mzl4w4u92"'
host h-desktop  ',"entrypoint":"claude-desktop","bundle":"com.anthropic.claudefordesktop"'
host h-jb       ',"term":"JetBrains-JediTerm","entrypoint":"claude-code-jetbrains-plugin"'
host h-cmux     ',"term":"ghostty","cmuxWorkspace":"w1","bundle":"com.cmuxterm.app"'
outh=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest 2>/dev/null)
capsof() { echo "$outh" | jq -r --arg id "$1" 'select(.id == $id) | .caps'; }
eq "iTerm2: everything"        "iTerm2|type|keys"       "$(capsof h-iterm)"
eq "Cursor terminal: everything" "Cursor / VS Code|type|keys" "$(capsof h-cursor)"
eq "Terminal: text, no keys"   "Terminal|type|-"        "$(capsof h-terminal)"
eq "Claude panel: jump only"   "Cursor|-|-"             "$(capsof h-panel)"
eq "Claude desktop: jump only" "Claude|-|-"             "$(capsof h-desktop)"
eq "JetBrains: jump only"      "-|-"                    "$(capsof h-jb | cut -d'|' -f2-)"
eq "cmux: jump only"           "cmux|-|-"               "$(capsof h-cmux)"
eq "no rename where Spyglass can't type" "false" "$(echo "$outh" | jq -r 'select(.id == "h-panel") | .canRename')"
eq "panel hover names the panel" 1 "$(echo "$outh" | jq -r 'select(.id == "h-panel") | .hover' | grep -cF 'the Claude panel in Cursor')"
# Permission prompts answered through the hook (answer.sh) work in hosts where Spyglass can't press keys.
for id in h-panel h-cmux; do
  jq '.status = "waiting" | .permission = {tool: "Bash", detail: "make test", at: 4, key: "abcdef0123456789"}' "$SPYGLASS_HOME/sessions/$id.json" > "$TMP/t.json" && mv "$TMP/t.json" "$SPYGLASS_HOME/sessions/$id.json"
done
outk=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest 2>/dev/null)
eq "Claude panel: Allow/Deny through the hook" "true" "$(echo "$outk" | jq -r 'select(.id == "h-panel") | .canAnswer')"
eq "cmux: Allow/Deny through the hook" "true" "$(echo "$outk" | jq -r 'select(.id == "h-cmux") | .canAnswer')"
SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest --reply h-panel:allow >/dev/null 2>&1
eq "Allow writes the hook's answer" '{"behavior":"allow","key":"abcdef0123456789"}' "$(jq -cS . "$SPYGLASS_HOME/answers/h-panel.json" 2>/dev/null)"
SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest --reply h-cmux:deny >/dev/null 2>&1
eq "Deny writes the hook's answer" "deny" "$(jq -r .behavior "$SPYGLASS_HOME/answers/h-cmux.json" 2>/dev/null)"
for id in h-panel h-cmux; do jq '.status = "done" | del(.permission)' "$SPYGLASS_HOME/sessions/$id.json" > "$TMP/t.json" && mv "$TMP/t.json" "$SPYGLASS_HOME/sessions/$id.json"; done

# A Terminal.app prompt without a fingerprint (older hooks): no keys there, so the snapshot shows "Answer in Terminal".
jq '.status = "waiting" | .permission = {tool: "Bash", detail: "make deploy", at: 3}' "$SPYGLASS_HOME/sessions/h-terminal.json" > "$TMP/t.json" && mv "$TMP/t.json" "$SPYGLASS_HOME/sessions/h-terminal.json"
mkdir -p "$ROOT/tests/out"
eq "old-hook Terminal prompt: jump only" "false" "$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest 2>/dev/null | jq -r 'select(.id == "h-terminal") | .canAnswer')"
SPYGLASS_NO_REGISTRY=1 "$BIN" --snapshot "$ROOT/tests/out/panel-hosts.png" 2>/dev/null
export SPYGLASS_HOME="$TMP/spyglass"

# Collapsed panel: a session that just finished (the chime) shows under the header, after the ones that need you.
# Escaped (0.18.0): collapsed, the chime played but nothing showed which session it was.
export SPYGLASS_HOME="$TMP/peek"; mkdir -p "$SPYGLASS_HOME/sessions"
session p-work '{"title":"Finishing soon","titleSource":"ai","status":"working","activity":"Running tests"}'
session p-wait '{"title":"Needs approval","titleSource":"ai","status":"waiting","permission":{"tool":"Bash","detail":"make","at":1,"key":"k"}}'
session p-old  '{"title":"Done long ago","titleSource":"ai","status":"done"}'
( sleep 0.5; f="$SPYGLASS_HOME/sessions/p-work.json"; jq '.status = "done" | .activity = "Finished — ready for you"' "$f" > "$f.t" && mv "$f.t" "$f" ) &
flip=$!
outp=$(SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest --twice --state '{"collapsed":"true"}' --snapshot "$ROOT/tests/out/panel-collapsed.png" 2>/dev/null); wait "$flip"
eq "collapsed: needs-you first, then what just finished; older done rows stay hidden" '["p-wait","p-work"]' "$(echo "$outp" | jq -c 'select(.peek) | .peek')"
export SPYGLASS_HOME="$TMP/tower"

# Welcome card checklist ticks itself off (fake home; which editors are installed is machine-specific, so not asserted).
WH="$TMP/welcome-home"; mkdir -p "$WH/.claude"
setup_of() { HOME="$WH" SPYGLASS_HOME="$WH/.claude/spyglass" SPYGLASS_NO_REGISTRY=1 "$BIN" --selftest 2>/dev/null | jq -c 'select(.setup) | .setup | {stats, extension}'; }
eq "fresh install: nothing set up" '{"stats":false,"extension":false}' "$(setup_of)"
mkdir -p "$WH/.claude/spyglass/stats" "$WH/.cursor/extensions/local.spyglass-focus-0.5.0"; echo "{\"updated\":$(date +%s)}" > "$WH/.claude/spyglass/stats/x.json"
eq "after setup and the editor extension: ticked" '{"stats":true,"extension":true}' "$(setup_of)"
rm -rf "$WH/.claude/spyglass/stats"; printf '#!/bin/bash\nin=$(cat)\n~/.claude/spyglass/stats.sh <<<"$in"\n' > "$WH/sl.sh"
echo '{"statusLine":{"type":"command","command":"~/sl.sh"}}' > "$WH/.claude/settings.json"
eq "a statusline that feeds Spyglass counts before any stats arrive" "true" "$(setup_of | jq -r .stats)"

# Snapshots to look at (not compared): full rows with a model confirm card, and compact view.
mkdir -p "$ROOT/tests/out"
SPYGLASS_NO_REGISTRY=1 "$BIN" --snapshot "$ROOT/tests/out/panel.png" --state '{"confirming:tab":"sonnet"}' 2>/dev/null
HOME="$WH" SPYGLASS_NO_REGISTRY=1 "$BIN" --snapshot "$ROOT/tests/out/panel-welcome.png" --state '{"welcome":"true","compact":"true"}' 2>/dev/null
SPYGLASS_NO_REGISTRY=1 "$BIN" --snapshot "$ROOT/tests/out/panel-compact.png" --state '{"compact":"true"}' 2>/dev/null
eq "snapshots rendered" "yes|yes" "$([ -s "$ROOT/tests/out/panel.png" ] && echo yes || echo no)|$([ -s "$ROOT/tests/out/panel-compact.png" ] && echo yes || echo no)"
kill "${pids[@]}" 2>/dev/null
finish
