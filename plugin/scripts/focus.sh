#!/bin/bash
# Bring a Claude session's terminal tab to the front. Args: TERM_PROGRAM, tty, app bundle id, [cmux workspace, cmux surface,
# claude pid, entrypoint, cwd].
# Spyglass runs under launchd, whose PATH lacks Homebrew (jq).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
app="$1"; tty="$2"; bundle="$3"; cws="$4"; csf="$5"; cpid="$6"; entry="${7:-}"; cwd="${8:-}"

# Not a terminal: the Claude desktop app, the Claude extension panel in Cursor / VS Code, or a JetBrains IDE.
case "$entry" in
  claude-desktop) open -b com.anthropic.claudefordesktop; exit 0 ;;
  *jetbrains*) [ -n "$bundle" ] && open -b "$bundle"; exit 0 ;;
  claude-vscode)
    # The spyglass-focus extension in the window that has this folder open focuses Claude's input there.
    d="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"; ts=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    jq -n --argjson ts "$ts" --arg cwd "$cwd" '{ts: $ts, claudePanel: true, cwd: $cwd}' > "$d/focus-request.json"
    target=""
    for _ in $(seq 1 20); do
      target=$(jq -r --argjson ts "$ts" 'select(.ts == $ts) | .target' "$d/focus-response.json" 2>/dev/null)
      [ -n "$target" ] && break; sleep 0.1
    done
    if [ -n "$bundle" ]; then if [ -n "$target" ]; then open -b "$bundle" "$target"; else open -b "$bundle"; fi; fi
    exit 0 ;;
esac
C=/Applications/cmux.app/Contents/Resources/bin/cmux

# Sessions known only from Claude Code's registry carry just a pid: derive tty and host app from the process tree.
if [ -z "$app" ] && [ -n "$cpid" ]; then
  t=$(ps -o tty= -p "$cpid" 2>/dev/null | tr -d ' ')
  [ -z "$tty" ] && [ -n "$t" ] && [ "$t" != "??" ] && tty="/dev/$t"
  p="$cpid"
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    exe=$(ps -o comm= -p "$p" 2>/dev/null)
    case "$exe" in
      */iTerm.app/*) app="iTerm.app"; break ;;
      */Terminal.app/*) app="Apple_Terminal"; break ;;
      */cmux.app/*) app="cmux"; bundle="com.cmuxterm.app"; break ;;
      *.app/*)
        appdir="${exe%%.app/*}.app"
        bundle=$(defaults read "$appdir/Contents/Info" CFBundleIdentifier 2>/dev/null)
        [ -f "$appdir/Contents/Resources/app/bin/code" ] || [ -d "$appdir/Contents/Resources/app/out" ] && app="vscode"
        [ -z "$app" ] && app="other"
        break ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
  [ -n "${SPYGLASS_FOCUS_DRYRUN:-}" ] && { echo "app=$app tty=$tty bundle=$bundle"; exit 0; }
  [ "$app" = "cmux" ] && { open -a cmux; exit 0; }
fi
if [ -n "$cws" ] && [ -x "$C" ]; then
  "$C" select-workspace --workspace "$cws" >/dev/null 2>&1
  [ -n "$csf" ] && "$C" focus-panel --panel "$csf" --workspace "$cws" >/dev/null 2>&1
  open -a cmux
elif [ "$app" = "iTerm.app" ] && [ -n "$tty" ]; then
  osascript <<OSA
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if tty of s is "$tty" then
          select w
          select t
          select s
          activate
          return
        end if
      end repeat
    end repeat
  end repeat
  activate
end tell
OSA
elif [ "$app" = "Apple_Terminal" ] && [ -n "$tty" ]; then
  osascript <<OSA
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "$tty" then
        set selected of t to true
        set index of w to 1
        activate
        return
      end if
    end repeat
  end repeat
  activate
end tell
OSA
elif [ "$app" = "vscode" ] && [ -n "$cpid" ] && [ -n "$bundle" ]; then
  # Cursor/VS Code: the spyglass-focus extension in the owning window shows the terminal whose shell is claude's parent.
  shell=$(ps -o ppid= -p "$cpid" | tr -d ' ')
  d="$HOME/.claude/spyglass"; ts=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  printf '{"ts":%s,"shellPid":%s}' "$ts" "${shell:-0}" > "$d/focus-request.json"
  target=""
  for _ in $(seq 1 20); do
    target=$(jq -r --argjson ts "$ts" 'select(.ts == $ts) | .target' "$d/focus-response.json" 2>/dev/null)
    [ -n "$target" ] && break; sleep 0.1
  done
  if [ -n "$target" ]; then open -b "$bundle" "$target"; else open -b "$bundle"; fi
elif [ -n "$bundle" ]; then
  open -b "$bundle"
fi
