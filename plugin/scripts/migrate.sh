#!/bin/bash
# One-time move from the plugin's old name (Tower, ~/.claude/tower) to Spyglass. Safe to run any number of times.
# Leaves ~/.claude/tower as a link, so sessions still running the old hooks, and an editor window still running the old
# extension, keep working until they restart.
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
old="${SPYGLASS_OLD_HOME:-$HOME/.claude/tower}"
real() { [ -z "${SPYGLASS_TEST:-}" ]; }   # tests skip launchd, processes and preferences

[ -d "$old" ] && [ ! -L "$old" ] && [ ! -e "$home" ] || exit 0

had_login=0
oldplist="$HOME/Library/LaunchAgents/dev.tower.panel.plist"
if real; then
  [ -f "$oldplist" ] && had_login=1
  launchctl bootout "gui/$(id -u)/dev.tower.panel" 2>/dev/null
  rm -f "$oldplist"
  pkill -f "^$old/Tower$" 2>/dev/null
  for _ in $(seq 1 30); do pgrep -f "^$old/Tower$" >/dev/null || break; sleep 0.1; done
fi

mv "$old" "$home" && ln -s "$home" "$old"
rm -f "$home/Tower"

if real; then
  # Panel preferences (position, compact view, sounds, hidden) carry over.
  if defaults read Tower >/dev/null 2>&1 && ! defaults read Spyglass >/dev/null 2>&1; then
    defaults export Tower - | defaults import Spyglass -
    f=$(defaults read Spyglass "NSWindow Frame TowerPanel" 2>/dev/null) && defaults write Spyglass "NSWindow Frame SpyglassPanel" "$f"
  fi
  [ $had_login = 1 ] && bash "$(dirname "$0")/login.sh" on >/dev/null 2>&1
fi
echo "Moved $old to $home (renamed Tower to Spyglass)."
