#!/bin/bash
# Renders the README GIF from scripted, fake sessions with the panel's own snapshot mode: no screen recording, no real
# data, same result every time. Usage: demo/storyboard.sh [out.gif]   (needs ffmpeg)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
bin="$root/plugin/bin/Spyglass"
out="${1:-$root/demo/spyglass-demo.gif}"
tmp="$(mktemp -d)"; trap 'kill $(jobs -p) 2>/dev/null; [ -n "${KEEP_FRAMES:-}" ] && cp "$tmp"/f*.png "$KEEP_FRAMES"/; rm -rf "$tmp"' EXIT
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

# 1. Every session at a glance: what it's doing, model, context, plan limits.
frame 2.0
# 2. A permission prompt, answered from the panel.
set_ flaky '.status = "waiting" | .activity = "Wants to use Bash" | .permission = {tool: "Bash", detail: "rm -rf node_modules/.cache && npm test -- checkout --repeat 20", at: '$((now - 40))', key: "demo"}'
frame 2.6
set_ flaky 'del(.permission) | .status = "working" | .activity = "Approved from Spyglass"'
frame 1.2
# 2b. A risky command gets no one-click Allow; the lock in the header turns Allow off for every prompt.
set_ flaky '.status = "waiting" | .activity = "Wants to use Bash" | .permission = {tool: "Bash", detail: "git push --force origin main", at: '$((now - 20))', key: "demo2"}'
frame 2.6
: > "$SPYGLASS_HOME/panel-allow-off"
set_ flaky '.permission = {tool: "Bash", detail: "npm test -- checkout --repeat 20", at: '$((now - 15))', key: "demo3"}'
frame 2.6
rm -f "$SPYGLASS_HOME/panel-allow-off"
set_ flaky 'del(.permission) | .status = "working" | .activity = "Running npm test -- checkout"'
# 3. Claude asks a question with choices: pick one from the panel.
set_ docs '.status = "waiting" | .activity = "Asking you a question" | .question = {text: "Which endpoints should get examples?", options: ["Orders", "+ Refunds", "All"], at: 1}'
frame 2.6
set_ docs 'del(.question) | .status = "working" | .activity = "Answered from Spyglass"'
frame 1.2
# 4. Switch a session's model, with a confirm in the panel.
frame 2.4 --state '{"confirming:auth":"sonnet"}'
# 5. Done with its last line; a context warning; a session that ended, ready to resume.
set_ auth '.status = "done" | .done = 5 | .lastLine = "Done: 48 tests pass, no API changes."'
session dash api 4 '{"title":"Investigate slow dashboard query","titleSource":"custom","status":"working","activity":"postgres · explain_query"}'
stats dash "Opus 5.5" 88
jq -n --arg cwd /Users/demo/code/web --argjson s "$((now - 3600))" \
  '{id: "gone", pid: 999999, cwd: $cwd, started: $s, updated: ($s + 1500), title: "Migrate CI to GitHub Actions", titleSource: "custom", status: "done", term: "iTerm.app"}' \
  > "$SPYGLASS_HOME/sessions/gone.json"
frame 2.8
# 6. Many sessions: compact view.
for i in 1 2 3; do session "more$i" web $((30 + i)) "{\"title\":\"$(sed -n "${i}p" <<<$'Upgrade React to v19\nAdd dark mode toggle\nTidy unused CSS')\",\"titleSource\":\"custom\",\"status\":\"done\"}"; done
frame 2.2 --state '{"compact":"true"}'
# 7. Collapsed out of the way: only what needs you, and what just finished, shows.
set_ docs '.status = "waiting" | .activity = "Asked you" | .asked = {text: "The /orders docs are ready. Should I also add examples for /refunds?", at: 1}'
set_ flaky '.status = "working"'
( sleep 0.4; set_ flaky '.status = "done" | .lastLine = "Flake fixed: the cart total raced the price fetch; 20/20 runs pass."' ) &
n=$((n + 1)); f=$(printf '%s/f%02d.png' "$tmp" "$n")
"$bin" --selftest --twice --state '{"collapsed":"true"}' --snapshot "$f" >/dev/null 2>&1
echo "file '$f'" >> "$tmp/list.txt"; echo "duration 2.4" >> "$tmp/list.txt"
# 8. Click the line to answer right there.
frame 2.8 --state '{"collapsed":"true","peekOpen:docs":"true"}'
echo "file '$(printf '%s/f%02d.png' "$tmp" "$n")'" >> "$tmp/list.txt"   # concat needs the last frame repeated
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

# Optional square MP4 (LinkedIn / GitHub): SPYGLASS_MP4=path demo/storyboard.sh
if [ -n "${SPYGLASS_MP4:-}" ]; then
  ffmpeg -v error -y -f concat -safe 0 -i "$tmp/list.txt" -vf "scale=960:960:force_original_aspect_ratio=decrease:flags=lanczos,scale=trunc(iw/2)*2:trunc(ih/2)*2,pad=1080:1080:(ow-iw)/2:(oh-ih)/2:0x2b2b2b,fps=30,format=yuv420p" -c:v libx264 -crf 20 -movflags +faststart "$SPYGLASS_MP4"
  echo "Wrote $SPYGLASS_MP4 ($(du -h "$SPYGLASS_MP4" | cut -f1))"
fi
