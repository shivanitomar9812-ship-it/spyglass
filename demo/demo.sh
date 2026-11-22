#!/bin/bash
# Run Spyglass with fake, animated sessions for recording a demo (README GIF, screenshots).
# Uses a throwaway SPYGLASS_HOME and ignores Claude Code's registry, so no real sessions appear.
# Usage: demo/demo.sh [seconds]   (default 120; Ctrl-C to stop early)
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
bin="$repo/plugin/bin/Spyglass"
secs="${1:-120}"
home="$(mktemp -d)"; mkdir -p "$home/sessions"
dir="$home/sessions"
label="dev.spyglass.panel"
dom="gui/$(id -u)"

real_home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
mkdir -p "$real_home"; echo $$ > "$real_home/demo.lock"   # stops new sessions relaunching the real panel

# Pause the real panel so it doesn't overlap; it is restarted on exit.
real_was_running=0
if launchctl print "$dom/$label" 2>/dev/null | grep -q 'state = running'; then
  real_was_running=1; launchctl kill SIGTERM "$dom/$label"; sleep 1
fi
pkill -f "^$real_home/Spyglass$" 2>/dev/null && real_was_running=1   # started outside launchd

SPYGLASS_HOME="$home" SPYGLASS_NO_REGISTRY=1 "$bin" >/dev/null 2>&1 &
app=$!

cleanup() {
  kill "$app" 2>/dev/null; rm -rf "$home"; rm -f "$real_home/demo.lock"
  [ "$real_was_running" = 1 ] && launchctl kickstart "$dom/$label" >/dev/null 2>&1
  echo; echo "Demo stopped."
}
trap cleanup EXIT INT TERM

now() { date +%s; }
t0=$(now)

# write <id> <title> <status> <activity> [done] [total] [minutes-ago-started]
write() {
  local id="$1" title="$2" status="$3" activity="$4" done="${5:-}" total="${6:-}" ago="${7:-5}"
  jq -n --arg id "$id" --arg title "$title" --arg status "$status" --arg activity "$activity" \
    --arg done "$done" --arg total "$total" --argjson pid $$ --argjson now "$(now)" \
    --argjson started "$((t0 - ago * 60))" '
    {id: $id, title: $title, status: $status, activity: $activity, pid: $pid,
     started: $started, turnStarted: $started, updated: $now, cwd: "/Users/demo/code"}
    + (if $total != "" then {done: ($done | tonumber), total: ($total | tonumber)} else {} end)
  ' > "$dir/$id.json.tmp" && mv "$dir/$id.json.tmp" "$dir/$id.json"
}

echo "Spyglass demo running for ${secs}s — start your screen recording now (Cmd+Shift+5)."
tick=0
end=$(( $(now) + secs ))
while [ "$(now)" -lt "$end" ]; do
  i=$(( tick % 24 ))   # 24 ticks x 2s = 48s loop

  # 1. Steady progress through a task list, then done.
  acts=("Reading src/middleware/auth.ts" "Editing src/middleware/auth.ts" "Running npm test -- auth" "Editing src/routes/session.ts")
  if [ $i -lt 18 ]; then
    write a1 "Refactor auth middleware" working "${acts[$((i % 4))]}" $(( i / 4 + 1 )) 5 12
  else
    write a1 "Refactor auth middleware" done "Finished — ready for you" 5 5 12
  fi

  # 2. Hits a permission prompt mid-way ("needs you"), then carries on.
  if [ $i -lt 6 ]; then
    write a2 "Fix flaky checkout test" working "Running npm test -- checkout" "" "" 7
  elif [ $i -lt 13 ]; then
    write a2 "Fix flaky checkout test" waiting "Claude needs your permission to use Bash" "" "" 7
  else
    write a2 "Fix flaky checkout test" working "Re-running checkout tests 20 times" "" "" 7
  fi

  # 3. Slow, steady docs job.
  docs=("Writing docs/api/orders.md" "Reading src/routes/orders.ts" "Writing docs/api/orders.md")
  write a3 "Write API docs for /orders" working "${docs[$((i % 3))]}" $(( 2 + i / 8 )) 6 21

  # 4. Investigation that ends by asking a question.
  inv=("postgres · explain_query" "Reading db/queries/dashboard.sql" "Searching for SELECT *" "Subagent: profile slow endpoints")
  if [ $i -lt 16 ]; then
    write a4 "Investigate slow dashboard query" working "${inv[$((i % 4))]}" "" "" 4
  else
    write a4 "Investigate slow dashboard query" waiting "Asking you a question" "" "" 4
  fi

  # 5. Already finished.
  write a5 "Upgrade React to v19" done "Finished — ready for you" 8 8 35

  tick=$(( tick + 1 ))
  sleep 2
done
