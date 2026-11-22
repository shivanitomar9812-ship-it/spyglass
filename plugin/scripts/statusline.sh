#!/bin/bash
# Spyglass's statusline wrapper (installed by /spyglass:setup): hands Claude Code's statusline data to Spyglass (stats.sh),
# then runs your original statusline unchanged. With no original statusline, prints a short one.
here="$(cd "$(dirname "$0")" && pwd)"
SG="$here/../bin/Spyglass"; [ -x "$SG" ] || SG="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/Spyglass"   # JSON helper (no jq)
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
in=$(cat)
[ -x "$home/stats.sh" ] && ("$home/stats.sh" <<<"$in" >/dev/null 2>&1 &)
orig=$("$SG" json get "$home/statusline-original.json" .command)
# Your statusline runs here as it would on its own: statuslines often use Homebrew tools (jq), so keep them on PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
if [ -n "$orig" ]; then
  printf '%s' "$in" | bash -c "$orig"
else
  dir=$("$SG" json get - .workspace.current_dir <<<"$in" || "$SG" json get - .cwd <<<"$in")
  model=$("$SG" json get - .model.display_name <<<"$in")
  ctx=$("$SG" json get - .context_window.used_percentage <<<"$in"); ctx="${ctx%%.*}"
  line="${dir##*/}"; [ -n "$model" ] && line="$line  $model"; [ -n "$ctx" ] && line="$line  ctx $ctx%"
  echo "${line#  }"
fi
