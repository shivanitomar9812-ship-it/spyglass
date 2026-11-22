#!/bin/bash
# Install the Spyglass panel to ~/.claude/spyglass and start it if it isn't running.
# Plugin paths change on every update, so the app and focus script are copied to a stable location.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
mkdir -p "$home/sessions"

[ "$(uname)" = "Darwin" ] || exit 0
[ "${SPYGLASS_DISABLE_PANEL:-}" = "1" ] && exit 0
# A demo recording is running (demo/demo.sh): don't start the real panel over it.
lock="$home/demo.lock"
[ -f "$lock" ] && kill -0 "$(cat "$lock" 2>/dev/null)" 2>/dev/null && exit 0

src="$root/bin/Spyglass"
# SPYGLASS_BUILD_FROM_SOURCE=1: replace the prebuilt binary with one built here, once per installed version (SECURITY.md).
if [ "${SPYGLASS_BUILD_FROM_SOURCE:-}" = 1 ] && [ ! -f "$root/bin/.built-here" ]; then
  bash "$root/app/build.sh" "$root/bin/Spyglass" >/dev/null 2>&1 && touch "$root/bin/.built-here"
fi
if [ ! -x "$src" ]; then
  bash "$root/app/build.sh" "$root/bin/Spyglass" >/dev/null 2>&1 || exit 0
fi
cp "$root/scripts/focus.sh" "$home/focus.sh"
cp "$root/editor-extension/core.js" "$home/editor-core.js"   # hot-loaded by the Cursor / VS Code extension
"$root/bin/Spyglass" json get "$root/.claude-plugin/plugin.json" .version > "$home/version" 2>/dev/null   # the panel compares sessions' hooks with it
cp "$root/scripts/stats.sh" "$root/scripts/send.sh" "$root/scripts/resume.sh" "$root/scripts/statusline.sh" "$root/scripts/login.sh" "$home/" \
  && chmod +x "$home/stats.sh" "$home/send.sh" "$home/resume.sh" "$home/statusline.sh" "$home/login.sh"
if ! cmp -s "$src" "$home/Spyglass"; then
  pkill -f "^$home/Spyglass$" 2>/dev/null
  # Wait for it to exit, or the check below sees it still shutting down and nothing restarts the panel.
  for _ in $(seq 1 30); do pgrep -f "^$home/Spyglass$" >/dev/null || break; sleep 0.1; done
  cp "$src" "$home/Spyglass" && chmod +x "$home/Spyglass"
fi

pgrep -f "^$home/Spyglass$" >/dev/null && exit 0
label="dev.spyglass.panel"
if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  launchctl kickstart "gui/$(id -u)/$label"
else
  nohup "$home/Spyglass" >/dev/null 2>&1 &
fi
