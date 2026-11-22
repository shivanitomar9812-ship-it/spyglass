#!/bin/bash
# Type into a Claude session's terminal. Args: TERM_PROGRAM, tty, app bundle id, cmux workspace, cmux surface, claude pid, command,
# [session id, permission timestamp]. Commands: "/model opus|sonnet|haiku" (confirms Claude Code's "Switch model?" dialog; the user
# already confirmed in Spyglass), or "key:approve" / "key:deny" to answer a permission prompt (sent only while that same prompt is still
# pending), "answer:<1-4>" to pick an option of Claude's pending question (same guard), or "rename:<name>" to /rename the
# session and its terminal tab. Exit: 0 done, 1 failed / didn't apply,
# 2 terminal not supported, 3 not allowed, 4 prompt gone.
# Spyglass runs under launchd, whose PATH lacks Homebrew (jq).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
app="$1"; tty="$2"; bundle="$3"; cws="$4"; csf="$5"; cpid="$6"; cmd="$7"; sid="${8:-}"; at="${9:-}"
home="${SPYGLASS_HOME:-$HOME/.claude/spyglass}"
case "$cmd" in
  "/model opus"|"/model sonnet"|"/model haiku") kind=model ;;
  key:approve|key:deny)
    kind=key
    # Answer only the prompt the user saw: a stale click must not press Esc on a working session (that interrupts it).
    [ -n "$sid" ] && [ -n "$at" ] || exit 3
    jq -e --argjson at "$at" '.status == "waiting" and .permission.at == $at' "$home/sessions/$sid.json" >/dev/null 2>&1 || exit 4 ;;
  answer:[1-4])
    kind=answer
    # Only the question the user saw, still pending.
    [ -n "$sid" ] && [ -n "$at" ] || exit 3
    n="${cmd#answer:}"
    jq -e --argjson at "$at" --argjson n "$n" '.status == "waiting" and .question.at == $at and ((.question.options // []) | length) >= $n' \
      "$home/sessions/$sid.json" >/dev/null 2>&1 || exit 4 ;;
  rename:*)
    kind=rename; name="${cmd#rename:}"
    # One line, 1-80 chars, no control characters: it is typed after "/rename " into Claude's input box.
    LC_ALL=C; [[ ${#name} -ge 1 && ${#name} -le 80 && ! "$name" =~ [[:cntrl:]] && "$name" != " "* ]] || exit 3
    [ -n "$sid" ] || exit 3 ;;
  *) exit 3 ;;
esac

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
      */cmux.app/*) app="cmux"; break ;;
      *.app/*)
        appdir="${exe%%.app/*}.app"
        { [ -f "$appdir/Contents/Resources/app/bin/code" ] || [ -d "$appdir/Contents/Resources/app/out" ]; } && app="vscode"
        break ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
fi

# route <what>: how this terminal can take it. iterm | vscode | terminal | none.
# Terminal.app's `do script` always presses Enter after the text, so it only takes text commands and Enter itself;
# single keys (1, Esc) would be followed by a stray Enter. cmux refuses control from outside cmux.
route() {
  case "$app" in
    iTerm.app) [ -n "$tty" ] && echo iterm || echo none ;;
    vscode) [ -n "$cpid" ] && echo vscode || echo none ;;
    Apple_Terminal)
      case "$1" in key:approve|key:deny|key:[1-4]) echo none ;; *) [ -n "$tty" ] && echo terminal || echo none ;; esac ;;
    *) echo none ;;
  esac
}

# deliver <text | key:approve | key:deny | key:enter | key:1-4 | tabname:NAME>: type it into the session's terminal.
# Returns 0, 1, 2 (not possible in this terminal) or 4 (dialog gone).
deliver() {
  local what="$1" how
  how=$(route "$what")
  # Test seams (tests/send_test.sh), never set by the panel: print the route, or log instead of typing.
  if [ -n "${SPYGLASS_SEND_ROUTE:-}" ]; then echo "$how $what"; [ "$how" = none ] && return 2; return 0; fi
  if [ -n "${SPYGLASS_SEND_LOG:-}" ]; then echo "$what" >> "$SPYGLASS_SEND_LOG"; return 0; fi
  if [ "$how" = terminal ]; then
    # Terminal.app: do script types the text and presses Enter; "" is Enter alone; tabname sets the tab's custom title.
    local r
    r=$(osascript - "$tty" "$what" <<'OSA' 2>/dev/null
on run argv
  set what to item 2 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is (item 1 of argv) then
          if what starts with "tabname:" then
            set custom title of t to (text 9 thru -1 of what)
          else if what is "key:enter" then
            do script "" in t
          else
            do script what in t
          end if
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "missing"
end run
OSA
)
    [ "$r" = "ok" ] && return 0
    return 1
  fi
  if [ "$how" = iterm ]; then
    # Keys: "1" picks "Yes" on a permission prompt (never "always allow"); Esc declines; Enter confirms the highlighted option.
    # Text and Enter go separately so Claude Code doesn't take it as a paste.
    local send check='true'
    case "$what" in
      key:approve) send='tell s to write text "1" newline no'
                   check='(contents of s contains "Do you want") and (contents of s contains "Esc to cancel")' ;;
      key:deny)    send='tell s to write text (ASCII character 27) newline no'
                   check='(contents of s contains "Do you want") and (contents of s contains "Esc to cancel")' ;;
      key:enter)   send='tell s to write text ""' ;;
      key:[1-4])   send='tell s to write text (text 5 of (item 2 of argv)) newline no'
                   check='(contents of s contains "Enter to select")' ;;
      tabname:*)   send='set name of s to (text 9 thru -1 of (item 2 of argv))' ;;
      *)           send='tell s to write text (item 2 of argv) newline no
          delay 0.3
          tell s to write text ""' ;;
    esac
    local r
    r=$(osascript - "$tty" "$what" <<OSA 2>/dev/null
on run argv
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if tty of s is (item 1 of argv) then
            if not ($check) then return "gone"
            $send
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "missing"
end run
OSA
)
    [ "$r" = "ok" ] && return 0
    [ "$r" = "gone" ] && return 4
    return 1
  elif [ "$how" = vscode ]; then
    # Cursor/VS Code: the spyglass-focus extension types into the terminal whose shell is claude's parent.
    local shell ts ok
    shell=$(ps -o ppid= -p "$cpid" | tr -d ' ')
    ts=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
    jq -n --argjson ts "$ts" --argjson pid "${shell:-0}" --arg text "$what" '{ts: $ts, shellPid: $pid, text: $text}' \
      > "$home/send-request.json.tmp" && mv "$home/send-request.json.tmp" "$home/send-request.json"
    for _ in $(seq 1 30); do
      ok=$(jq -r --argjson ts "$ts" 'select(.ts == $ts) | .ok' "$home/send-response.json" 2>/dev/null)
      [ "$ok" = "true" ] && return 0
      [ "$ok" = "false" ] && return 1
      sleep 0.1
    done
    return 2   # no reply: extension missing, old, or the window needs a reload
  fi
  return 2
}

if [ "$kind" = rename ]; then
  transcript=$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
  lines0=0; [ -n "$transcript" ] && lines0=$(wc -l < "$transcript" | tr -d ' ')
  deliver "/rename $name" || exit $?
  # Applied = the transcript gained this customTitle.
  if [ -n "$transcript" ]; then
    ok=1
    for _ in $(seq 1 30); do
      tail -n +"$((lines0 + 1))" "$transcript" 2>/dev/null | grep '"customTitle"' | jq -e --arg n "$name" 'select(.customTitle == $n)' >/dev/null 2>&1 && { ok=0; break; }
      sleep 0.1
    done
    [ $ok = 0 ] || exit 1
  fi
  # Show it in Spyglass now (no hook fires for /rename), then rename the terminal tab; a tab failure doesn't undo the rename.
  f="$home/sessions/$sid.json"
  [ -f "$f" ] && jq --arg n "$name" '.title = $n | .titleSource = "custom"' "$f" > "$f.spyglass.tmp" && mv "$f.spyglass.tmp" "$f" || rm -f "$f.spyglass.tmp"
  deliver "tabname:$name"
  exit 0
fi

if [ "$kind" = answer ]; then
  deliver "key:$n"; rc=$?
  if [ $rc = 0 ]; then
    f="$home/sessions/$sid.json"
    jq --argjson at "$at" 'if .question.at == $at then del(.question) | .status = "working" | .activity = "Answered from Spyglass" else . end' \
      "$f" > "$f.spyglass.tmp" && mv "$f.spyglass.tmp" "$f" || rm -f "$f.spyglass.tmp"
  fi
  exit $rc
fi

if [ "$kind" = key ]; then
  deliver "$cmd"; rc=$?
  if [ $rc = 0 ]; then
    # Mark it answered: a declined prompt fires no hook, so the row would keep its buttons.
    f="$home/sessions/$sid.json"
    if [ "$cmd" = key:approve ]; then st=working; act="Approved from Spyglass"; else st=idle; act="Denied from Spyglass"; fi
    jq --argjson at "$at" --arg st "$st" --arg act "$act" \
      'if .permission.at == $at then del(.permission) | .status = $st | .activity = $act else . end' "$f" > "$f.spyglass.tmp" \
      && mv "$f.spyglass.tmp" "$f" || rm -f "$f.spyglass.tmp"
  fi
  exit $rc
fi

# --- /model ---
# /model also saves the pick as the default for new sessions; put the previous default back once it has applied.
settings="$HOME/.claude/settings.json"
before=$(jq -c '.model // null' "$settings" 2>/dev/null)
mtime=$(stat -f %m "$settings" 2>/dev/null)
restore() {
  [ -f "$settings" ] && [ -n "$before" ] || return
  for _ in $(seq 1 30); do [ "$(stat -f %m "$settings" 2>/dev/null)" != "$mtime" ] && break; sleep 0.1; done
  jq --argjson m "$before" 'if $m == null then del(.model) else .model = $m end' "$settings" > "$settings.spyglass.tmp" \
    && mv "$settings.spyglass.tmp" "$settings" || rm -f "$settings.spyglass.tmp"
}
# Applied = the transcript gained "Set model to ..." after we typed. Without a transcript, assume it applied.
transcript=""
[ -n "$sid" ] && transcript=$(ls "$HOME"/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1)
lines0=0; [ -n "$transcript" ] && lines0=$(wc -l < "$transcript" | tr -d ' ')
applied() {   # applied <tenths of a second to wait>
  [ -z "$transcript" ] && return 0
  for _ in $(seq 1 "$1"); do
    tail -n +"$((lines0 + 1))" "$transcript" 2>/dev/null | grep -q 'Set model to' && return 0
    sleep 0.1
  done
  return 1
}

deliver "$cmd" || exit $?
if ! applied 20; then
  # A cached conversation makes Claude Code ask "Switch model?" (option 1 = Yes, highlighted). The user confirmed in Spyglass.
  deliver key:enter || exit $?
  applied 40 || exit 1
fi
restore
exit 0
