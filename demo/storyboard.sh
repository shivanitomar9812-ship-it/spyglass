#!/bin/bash
# Renders the README GIF from scripted, fake sessions with the panel's own snapshot mode: no screen recording, no real
# data, same result every time. Usage: demo/storyboard.sh [out.gif]   (needs ffmpeg)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/plugin/bin/Spyglass"
out="${1:-$root/demo/spyglass-demo.gif}"
tmp="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$tmp"' EXIT
export SPYGLASS_HOME="$tmp/home" SPYGLASS_CLAUDE_DIR="$tmp/claude" SPYGLASS_NO_REGISTRY=1 HOME="$tmp/user"
mkdir -p "$SPYGLASS_HOME/sessions" "$SPYGLASS_HOME/stats" "$SPYGLASS_CLAUDE_DIR/projects" "$HOME"
now=$(date +%s)

# session <id> <repo> <started minutes ago> <json fields>
session() {
  sleep 600 & local pid=$!
  jq -n --arg id "$1" --arg cwd "/Users/demo/code/$2" --argjson pid "$pid" --argjson s "$((now - $3 * 60))" --argjson x "$4" \
    '{id: $id, pid: $pid, cwd: $cwd, started: $s, updated: $s, turnStarted: $s, term: "iTerm.app"} + $x' \
    > "$SPYGLASS_HOME/sessions/$1.json"
}
set_() { local f="$SPYGLASS_HOME/sessions/$1.json"; jq "$2" "$f" > "$f.t" && mv "$f.t" "$f"; }
stats() {   # stats <id> <model> <ctx %>
  jq -n --arg m "$2" --argjson c "$3" --argjson now "$now" \
    '{model: $m, ctx: $c, updated: $now, limits: {five_hour: {pct: 38, resets: ($now + 7200)}, seven_day: {pct: 21, resets: ($now + 300000)}}}' \
    > "$SPYGLASS_HOME/stats/$1.json"
}
n=0
frame() {   # frame <seconds> [--state json]
  local secs="$1"; shift
  n=$((n + 1)); local f; f=$(printf '%s/f%02d.png' "$tmp" "$n")
  "$bin" --snapshot "$f" "$@" 2>/dev/null
  echo "file '$f'" >> "$tmp/list.txt"; echo "duration $secs" >> "$tmp/list.txt"
}

session auth   api  12 '{"title":"Refactor auth middleware","titleSource":"custom","status":"working","activity":"Editing src/middleware/auth.ts","done":2,"total":5}'
session flaky  web   7 '{"title":"Fix flaky checkout test","titleSource":"custom","status":"working","activity":"Running npm test -- checkout"}'
session docs   docs 21 '{"title":"Write API docs for /orders","titleSource":"custom","status":"working","activity":"Writing docs/api/orders.md"}'
stats auth "Opus 5.5" 34; stats flaky "Sonnet 5.5" 18; stats docs "Haiku 5.5" 9

frame 1.8
set_ flaky '.status = "waiting" | .activity = "Wants to use Bash" | .permission = {tool: "Bash", detail: "rm -rf node_modules/.cache && npm test -- checkout --repeat 20", at: 1, key: "demo"}'
frame 2.4
set_ flaky 'del(.permission) | .status = "working" | .activity = "Approved from Spyglass"'
frame 1.2
set_ docs '.status = "waiting" | .activity = "Asked you" | .asked = {text: "The /orders docs are ready. Should I also add examples for /refunds?", at: 1}'
frame 2.4
set_ docs 'del(.asked) | .status = "working" | .activity = "Replied from Spyglass"'
set_ auth '.status = "done" | .done = 5 | .lastLine = "Done: auth moved to middleware, 48 tests pass, no API changes."'
frame 2.0
session dash api 4 '{"title":"Investigate slow dashboard query","titleSource":"custom","status":"working","activity":"postgres · explain_query"}'
stats dash "Opus 5.5" 88
frame 1.8
for i in 1 2 3; do session "more$i" web $((30 + i)) "{\"title\":\"$(sed -n "${i}p" <<<$'Upgrade React to v19\nAdd dark mode toggle\nTidy unused CSS')\",\"titleSource\":\"custom\",\"status\":\"done\"}"; done
frame 2.2 --state '{"compact":"true"}'
set_ flaky '.status = "done" | .lastLine = "Flake fixed: the cart total raced the price fetch; 20/20 runs pass."'
# Collapsed: the session that just finished is listed (simulated: it flips to done while the panel watches).
set_ flaky '.status = "working"'
( sleep 0.4; set_ flaky '.status = "done"' ) &
n=$((n + 1)); f=$(printf '%s/f%02d.png' "$tmp" "$n")
"$bin" --selftest --twice --state '{"collapsed":"true"}' --snapshot "$f" >/dev/null 2>&1
echo "file '$f'" >> "$tmp/list.txt"; echo "duration 2.4" >> "$tmp/list.txt"
echo "file '$f'" >> "$tmp/list.txt"   # concat needs the last frame repeated

# Same canvas for every frame (panel at the top), then a palette-optimised GIF.
w=0; h=0
for p in "$tmp"/f*.png; do
  pw=$(sips -g pixelWidth "$p" | awk '/pixelWidth/ {print $2}'); ph=$(sips -g pixelHeight "$p" | awk '/pixelHeight/ {print $2}')
  [ "$pw" -gt "$w" ] && w=$pw; [ "$ph" -gt "$h" ] && h=$ph
done
w=$((w + 48)); h=$((h + 48))
# Pad each frame on its own first: ffmpeg's palette filters can't follow a stream whose frame size changes.
for p in "$tmp"/f*.png; do
  # Lay the frame over the background (its rounded corners are transparent; a GIF would show them white).
  ffmpeg -v error -y -f lavfi -i "color=0x2b2b2b:s=${w}x${h}" -i "$p" -filter_complex "[0:v][1:v]overlay=24:24,format=rgb24" -frames:v 1 "$p.pad.png" && mv "$p.pad.png" "$p"
done
vf="scale=$((w * 3 / 4 / 2 * 2)):-2:flags=lanczos"
ffmpeg -v error -y -f concat -safe 0 -i "$tmp/list.txt" -vf "$vf,palettegen=stats_mode=diff" "$tmp/pal.png"
ffmpeg -v error -y -f concat -safe 0 -i "$tmp/list.txt" -i "$tmp/pal.png" -lavfi "$vf[x];[x][1:v]paletteuse=dither=none" -loop 0 "$out"
echo "Wrote $out ($(du -h "$out" | cut -f1), $n frames)"
