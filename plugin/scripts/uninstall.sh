#!/bin/bash
# /spyglass:uninstall [--yes]: undo everything Spyglass changed on this Mac. Without --yes it only lists what it would do.
#   statusline (wrapper or the line you added), login item, editor extension and tab-title setting, panel, state.
# Then: /plugin uninstall spyglass@spyglass  (a plugin can't remove itself from inside a session).
here="$(cd "$(dirname "$0")" && pwd)"
SG="$here/../bin/Spyglass"; [ -x "$SG" ] || SG="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/Spyglass"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
yes=0; [ "${1:-}" = "--yes" ] && yes=1
real() { [ -z "${SPYGLASS_TEST:-}" ]; }   # tests skip launchd, processes, preferences and editor CLIs
stamp=$(date +%Y%m%d-%H%M%S)
n=0
step() { n=$((n + 1)); if [ $yes = 1 ]; then echo "✓ $1"; else echo "• Would: $1"; fi; }

# 1. Statusline
cmd=$("$SG" json get "$settings" .statusLine.command 2>/dev/null)
case "$cmd" in
  *spyglass/statusline.sh*)
    step "put your original statusline back (settings.json backed up)"
    [ $yes = 1 ] && bash "$here/setup.sh" off >/dev/null ;;
  "") ;;
  *)
    file="${cmd%% *}"; file="${file/#\~/$HOME}"; file="${file//\"/}"
    if [ -f "$file" ] && grep -qE 'spyglass/stats\.sh' "$file"; then
      step "remove the Spyglass line from your statusline script ${file/#$HOME/~} (backup: $(basename "$file").bak-spyglass-$stamp)"
      if [ $yes = 1 ]; then
        cp "$file" "$file.bak-spyglass-$stamp"
        grep -vE 'spyglass/stats\.sh' "$file.bak-spyglass-$stamp" > "$file"
      fi
    fi ;;
esac

# 2. Login item
label=dev.spyglass.panel; plist="$HOME/Library/LaunchAgents/$label.plist"
if [ -f "$plist" ]; then
  step "remove the login item $label"
  if [ $yes = 1 ]; then real && launchctl bootout "gui/$(id -u)/$label" 2>/dev/null; rm -f "$plist"; fi
fi

# 3. Editor extension and the tab-title setting (only if it's still the value Spyglass set)
for app in Cursor Code Windsurf; do
  dir="$HOME/.$(echo "$app" | tr '[:upper:]' '[:lower:]')/extensions"; [ "$app" = Code ] && dir="$HOME/.vscode/extensions"
  if ls "$dir" 2>/dev/null | grep -qE '^local\.spyglass-focus-'; then
    step "uninstall the Spyglass extension from $app"
    if [ $yes = 1 ] && real; then
      for cli in "/Applications/$app.app/Contents/Resources/app/bin/$(echo "$app" | tr '[:upper:]' '[:lower:]')" \
                 "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; do
        [ -x "$cli" ] || continue
        "$cli" --uninstall-extension local.spyglass-focus >/dev/null 2>&1;
      done
    fi
  fi
  s="$HOME/Library/Application Support/$app/User/settings.json"
  if [ -f "$s" ] && [ "$("$SG" json get "$s" '."terminal.integrated.tabs.title"' 2>/dev/null)" = '${sequence}' ]; then
    step "reset $app's terminal tab titles (the setting /spyglass:setup tabs added)"
    [ $yes = 1 ] && cp "$s" "$s.bak-spyglass-$stamp" && "$SG" json set "$s" --del '."terminal.integrated.tabs.title"'
  fi
done

# 4. Panel, preferences, state
if [ -e "$home" ]; then
  step "quit the panel and delete its state (${home/#$HOME/~}) and preferences"
  if [ $yes = 1 ]; then
    if real; then
      pkill -f "^$home/Spyglass$" 2>/dev/null
      defaults delete Spyglass >/dev/null 2>&1
    fi
    rm -rf "$home"
  fi
fi

echo
if [ $n = 0 ]; then echo "Nothing of Spyglass's is left on this Mac."
elif [ $yes = 1 ]; then echo "Done. Last step: /plugin uninstall spyglass@spyglass (and /plugin marketplace remove spyglass)."
else echo "Nothing changed yet. Run with --yes to do the $n step$([ $n = 1 ] || echo s) above."; fi
