#!/bin/bash
# /spyglass:setup [on | tabs | off | status]
#   on      Feed Spyglass the statusline data (model, context, plan limits): wraps your statusline, never edits it.
#   tabs    Also show Claude's session titles on unnamed Cursor / VS Code / Windsurf terminal tabs.
#   off     Put your original statusline back.
#   status  Show what is set up.
# Backs up settings.json before changing it; running it twice changes nothing.
here="$(cd "$(dirname "$0")" && pwd)"
SG="$here/../bin/Spyglass"; [ -x "$SG" ] || SG="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/Spyglass"   # JSON helper (no jq)
mode="${1:-on}"
root="$(cd "$(dirname "$0")/.." && pwd)"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
saved="$home/statusline-original.json"
wrapper="$home/statusline.sh"
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$home"

current() { "$SG" json raw "$settings" .statusLine 2>/dev/null || echo null; }
backup() { cp "$1" "$1.bak-spyglass-$stamp" && echo "Backed up $1 → $(basename "$1").bak-spyglass-$stamp"; }
# Changes settings.json only if it is plain JSON (the helper refuses otherwise, so a file with comments is never lost).
write_settings() {
  [ -f "$settings" ] || echo '{}' > "$settings"
  "$SG" json valid "$settings" || { echo "$settings isn't plain JSON (comments?); not changing it."; exit 1; }
  "$SG" json set "$settings" "$@" || { echo "Could not update $settings"; exit 1; }
}
# Already feeding Spyglass: our wrapper, or a statusline script that already calls stats.sh (the manual setup).
feeding() {
  local cmd; cmd=$("$SG" json get "$settings" .statusLine.command 2>/dev/null)
  [ -n "$cmd" ] || return 1
  case "$cmd" in *spyglass/statusline.sh*) echo wrapper; return 0 ;; esac
  local file="${cmd%% *}"; file="${file/#\~/$HOME}"; file="${file//\"/}"
  [ -f "$file" ] && grep -qE 'spyglass/stats.sh' "$file" && { echo manual; return 0; }
  return 1
}
install_scripts() {
  cp "$root/scripts/stats.sh" "$home/stats.sh"; cp "$root/scripts/statusline.sh" "$wrapper"
  [ -x "$home/Spyglass" ] || cp "$root/bin/Spyglass" "$home/Spyglass"   # the copies above run their JSON work through it
  chmod +x "$home/stats.sh" "$wrapper"
}

tabs() {
  local done_any=0
  for f in "$HOME/Library/Application Support/Cursor/User/settings.json" \
           "$HOME/Library/Application Support/Code/User/settings.json" \
           "$HOME/Library/Application Support/Windsurf/User/settings.json"; do
    [ -f "$f" ] || continue
    local app; app=$(basename "$(dirname "$(dirname "$f")")")
    if ! "$SG" json valid "$f"; then
      echo "$app: settings have comments or aren't plain JSON, left untouched. Add \"terminal.integrated.tabs.title\": \"\${sequence}\" yourself."
      continue
    fi
    if [ "$("$SG" json get "$f" '."terminal.integrated.tabs.title"')" = '${sequence}' ]; then
      echo "$app: tab titles already show Claude's session names."; done_any=1; continue
    fi
    backup "$f"
    "$SG" json set "$f" --str '."terminal.integrated.tabs.title"' '${sequence}'
    echo "$app: unnamed terminal tabs now show Claude's session names (tabs you named keep their names)."; done_any=1
  done
  [ $done_any = 1 ] || echo "No Cursor / VS Code / Windsurf settings found."
}

case "$mode" in
  on|tabs)
    install_scripts
    how=$(feeding)
    if [ "$how" = wrapper ]; then echo "Statusline: already set up for Spyglass."
    elif [ "$how" = manual ]; then echo "Statusline: your statusline script already feeds Spyglass; nothing changed."
    else
      [ -f "$settings" ] && backup "$settings"
      orig=$(current)
      # Keep the original exactly, to run it inside the wrapper and restore it on `off`.
      echo "$orig" > "$saved"
      pad=$("$SG" json get - .padding <<<"$orig" 2>/dev/null) || pad=0
      write_settings --json .statusLine "$("$SG" json make --str type command --str command "bash \"$wrapper\"" --json padding "${pad:-0}")"
      if [ "$orig" = null ]; then echo "Statusline: added a short one (folder, model, context) that also feeds Spyglass."
      else echo "Statusline: Spyglass now gets model, context and plan usage; your statusline shows exactly as before."; fi
      echo "Takes effect when each session's statusline next refreshes (send any message)."
    fi
    [ "$mode" = tabs ] && tabs
    exit 0 ;;
  off)
    if [ "$(feeding)" != wrapper ]; then
      [ "$(feeding)" = manual ] && echo "Your statusline script calls Spyglass itself; remove the spyglass/stats.sh line from it to stop." \
                                || echo "Spyglass isn't wrapping your statusline; nothing to undo."
      exit 0
    fi
    [ -f "$saved" ] || { echo "Original statusline not found ($saved); leaving settings alone."; exit 1; }
    backup "$settings"
    orig=$(cat "$saved")
    if [ "$orig" = null ]; then write_settings --del .statusLine; else write_settings --json .statusLine "$orig"; fi
    rm -f "$saved"
    echo "Statusline: your original is back; Spyglass no longer gets model, context or plan usage." ;;
  status)
    case "$(feeding)" in
      wrapper) echo "Statusline: wrapped for Spyglass (original: $("$SG" json raw "$saved" .))." ;;
      manual) echo "Statusline: your script feeds Spyglass directly." ;;
      *) echo "Statusline: not feeding Spyglass. Run /spyglass:setup to fix." ;;
    esac ;;
  *) echo "Usage: /spyglass:setup [on | tabs | off | status]"; exit 2 ;;
esac
