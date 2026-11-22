#!/bin/bash
# Spyglass's statusline wrapper (installed by /spyglass:setup): hands Claude Code's statusline data to Spyglass (stats.sh),
# then runs your original statusline unchanged. With no original statusline, prints a short one.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
in=$(cat)
[ -x "$home/stats.sh" ] && ("$home/stats.sh" <<<"$in" >/dev/null 2>&1 &)
orig=$(jq -r '.command // empty' "$home/statusline-original.json" 2>/dev/null)
if [ -n "$orig" ]; then
  printf '%s' "$in" | bash -c "$orig"
else
  jq -r '[(.workspace.current_dir // .cwd // "" | split("/") | last),
          (.model.display_name // empty),
          (.context_window.used_percentage // empty | "ctx \(floor)%")] | map(select(. != "")) | join("  ")' <<<"$in" 2>/dev/null
fi
