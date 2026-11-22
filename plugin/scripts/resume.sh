#!/bin/bash
# Reopen an ended Claude session in a new terminal tab. Args: TERM_PROGRAM, app bundle id, cwd, session id.
# Exit: 0 opened, 1 failed, 2 no reply from Cursor / VS Code (extension missing or older than v0.4), 3 bad session id, 5 folder gone.
# Spyglass runs under launchd, whose PATH lacks Homebrew (jq).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
term="$1"; bundle="$2"; cwd="$3"; sid="$4"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
[[ "$sid" =~ ^[0-9a-fA-F-]{36}$ ]] || exit 3
[ -d "$cwd" ] || exit 5
cmd="cd $(printf '%q' "$cwd") && claude --resume $sid"

iterm() {
  osascript - "$cmd" <<'OSA' >/dev/null 2>&1
on run argv
  tell application "iTerm2"
    if (count of windows) = 0 then
      set w to (create window with default profile)
    else
      set w to first window
      tell w to create tab with default profile
    end if
    tell current session of w to write text (item 1 of argv)
    activate
  end tell
end run
OSA
}
terminal() {
  osascript - "$cmd" <<'OSA' >/dev/null 2>&1
on run argv
  tell application "Terminal"
    do script (item 1 of argv)
    activate
  end tell
end run
OSA
}

case "$term" in
  iTerm.app) iterm || exit 1 ;;
  Apple_Terminal) terminal || exit 1 ;;
  vscode)
    # Cursor/VS Code: the frontmost window's spyglass-focus extension opens a terminal in cwd and resumes there.
    [ -n "$bundle" ] && open -b "$bundle"
    sleep 0.7
    ts=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    jq -n --argjson ts "$ts" --arg cwd "$cwd" --arg id "$sid" '{ts: $ts, cwd: $cwd, id: $id}' \
      > "$home/resume-request.json.tmp" && mv "$home/resume-request.json.tmp" "$home/resume-request.json"
    for _ in $(seq 1 30); do
      ok=$(jq -r --argjson ts "$ts" 'select(.ts == $ts) | .ok' "$home/resume-response.json" 2>/dev/null)
      [ "$ok" = "true" ] && exit 0
      [ "$ok" = "false" ] && exit 1
      sleep 0.1
    done
    exit 2 ;;
  *)
    # Unknown or unsupported host (cmux, registry-only sessions): use iTerm2 if installed, else Terminal.
    if [ -d /Applications/iTerm.app ]; then iterm || exit 1; else terminal || exit 1; fi ;;
esac
exit 0
