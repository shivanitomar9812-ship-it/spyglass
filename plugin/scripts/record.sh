#!/bin/bash
# Records per-session state for the Spyglass panel: ~/.claude/spyglass/sessions/<session_id>.json
# Runs on every hook event; must stay fast and never fail the session.
# Hooks and the statusline may run without Homebrew on PATH (jq).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
in=$(cat)
dir="${SPYGLASS_HOME:-$HOME/.claude/spyglass}/sessions"
mkdir -p "$dir"
sid=$(jq -r '.session_id // empty' <<<"$in")
[ -z "$sid" ] && exit 0
f="$dir/$sid.json"
ev=$(jq -r '.hook_event_name // empty' <<<"$in")

# Ended sessions move to ended/ so the panel can offer Resume (only ones that got a prompt).
if [ "$ev" = "SessionEnd" ]; then
  if [ -f "$f" ] && jq -e '.prompt // empty' "$f" >/dev/null 2>&1; then
    mkdir -p "${dir%/sessions}/ended"
    jq --argjson now "$(date +%s)" '. + {ended: $now} | del(.permission)' "$f" > "${dir%/sessions}/ended/$sid.json" 2>/dev/null
  fi
  rm -f "$f"; exit 0
fi

# Where the session lives (computed once per session, refreshed on each prompt).
pid=""; tty=""
if [ ! -f "$f" ] || [ "$ev" = "SessionStart" ] || [ "$ev" = "UserPromptSubmit" ]; then
  p=$$
  while [ -n "$p" ] && [ "$p" -gt 1 ]; do
    comm=$(ps -o comm= -p "$p" 2>/dev/null)
    t=$(ps -o tty= -p "$p" 2>/dev/null | tr -d ' ')
    [ -z "$tty" ] && [ -n "$t" ] && [ "$t" != "??" ] && tty="/dev/$t"
    case "$comm" in *claude*) pid="$p"; break ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  done
fi

# Title: /rename name, else Claude's auto title (read on prompt and stop only).
title=""
if [ "$ev" = "UserPromptSubmit" ] || [ "$ev" = "Stop" ] || [ "$ev" = "SessionStart" ] \
   || ! jq -e '.title // empty' "$f" >/dev/null 2>&1; then
  tp=$(jq -r '.transcript_path // empty' <<<"$in")
  if [ -f "$tp" ]; then
    title=$(grep -h '"customTitle"' "$tp" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
    tsrc=custom
    [ -z "$title" ] && title=$(grep -h '"type":"ai-title"' "$tp" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null) && tsrc=ai
  fi
fi

old="{}"; [ -f "$f" ] && old=$(cat "$f" 2>/dev/null || echo "{}")

# Fingerprint of a permission prompt's tool call; answer.sh computes the same, so Spyglass answers only this prompt.
key=""
[ "$ev" = "PermissionRequest" ] && key=$(jq -cS '.tool_input // {}' <<<"$in" | shasum -a 256 | cut -c1-16)

jq -n --argjson in "$in" --argjson o "${old:-{\}}" --arg ev "$ev" --argjson now "$(date +%s)" \
  --arg title "$title" --arg tsrc "${tsrc:-}" --arg pid "$pid" --arg tty "$tty" --arg key "$key" \
  --arg term "${TERM_PROGRAM:-}" --arg bundle "${__CFBundleIdentifier:-}" \
  --arg cws "${CMUX_WORKSPACE_ID:-}" --arg csf "${CMUX_SURFACE_ID:-}" --arg entry "${CLAUDE_CODE_ENTRYPOINT:-}" '
def base: $in.tool_input.file_path // $in.tool_input.notebook_path // "" | split("/") | last;
def cut($n): if length > $n then .[0:$n-1] + "…" else . end;
def act:
  ($in.tool_name // "") as $t | ($in.tool_input // {}) as $i |
  if $t == "Bash" then ($i.description // $i.command // "Running a command")
  elif ($t | test("^(Edit|Write|MultiEdit|NotebookEdit)$")) then "Editing " + base
  elif $t == "Read" then "Reading " + base
  elif $t == "Grep" then "Searching for " + ($i.pattern // "")
  elif $t == "Glob" then "Finding " + ($i.pattern // "files")
  elif $t == "Agent" or $t == "Task" then "Subagent: " + ($i.description // "working")
  elif $t == "WebFetch" then "Reading " + ($i.url // "" | sub("^https?://"; ""))
  elif $t == "WebSearch" then "Searching the web: " + ($i.query // "")
  elif $t == "AskUserQuestion" then "Asking you a question"
  elif $t == "Skill" then "Using skill " + ($i.skill // "")
  elif ($t | startswith("mcp__")) then ($t | split("__")) as $p | ($p[1] | sub("^claude_ai_"; "")) + " · " + ($p[2] // "")
  else $t end | gsub("\n"; " ") | cut(80);
def todos: ($in.tool_input.todos // null);
# Multiple-choice question from Claude: options only when Spyglass can answer it with one key (one question, single choice, <= 4 options).
def question: ($in.tool_input.questions // []) as $qs | ($qs[0] // {}) as $q |
  {text: (($q.question // "Claude has a question") | gsub("\n"; " ") | cut(200)), header: ($q.header // null), at: $now,
   options: (if ($qs | length) == 1 and ($q.multiSelect // false | not) and (($q.options // []) | length) <= 4
             then [($q.options // [])[] | .label // "" | cut(40)] else [] end)};
def ask: ($in.tool_input // {}) as $i |
  ($i.command // $i.file_path // $i.notebook_path // $i.url // $i.query // $i.pattern // "") | gsub("\n"; " ") | cut(300);

($o + {
  id: ($in.session_id),
  cwd: ($in.cwd // $o.cwd // ""),
  updated: $now,
  started: ($o.started // $now),
  steps: ($o.steps // 0)
})
| if $title != "" then .title = $title | .titleSource = $tsrc else . end
| if $pid != "" then .pid = ($pid | tonumber) else . end
| if $tty != "" then .tty = $tty else . end
| if $term != "" then .term = $term else . end
| if $bundle != "" then .bundle = $bundle else . end
| if $cws != "" then .cmuxWorkspace = $cws | .cmuxSurface = $csf else . end
# Where it runs: cli (a terminal), claude-vscode (extension panel), claude-desktop, claude-code-jetbrains-plugin, ...
| if $entry != "" then .entrypoint = $entry else . end
| if ($ev | test("^(SessionStart|UserPromptSubmit|PreToolUse|PostToolUse|Stop)$")) then del(.permission) else . end
| if ($ev | test("^(SessionStart|UserPromptSubmit|PostToolUse|Stop)$")) or ($ev == "PreToolUse" and $in.tool_name != "AskUserQuestion")
  then del(.question) else . end
| if $ev == "SessionStart" then .status = "idle" | .activity = "Ready"
  elif ($ev == "PermissionRequest" or $ev == "PreToolUse") and $in.tool_name == "AskUserQuestion" then
      # A question, not a permission prompt: "Allow once" (key 1) would silently pick the first option.
      .status = "waiting" | .activity = "Asking you a question" | .question = question
      | if $ev == "PreToolUse" then .steps += 1 else . end
  elif $ev == "PermissionRequest" then
      .status = "waiting" | .activity = "Wants to use " + ($in.tool_name // "a tool")
      | .permission = {tool: ($in.tool_name // ""), detail: ask, at: $now, key: $key}
  elif $ev == "UserPromptSubmit" then
      .status = "working" | .activity = "Thinking…" | .turnStarted = $now
      | .prompt = (($in.prompt // "") | gsub("\n"; " ") | cut(120))
      | if (.title // "") == "" then .title = (.prompt | cut(50)) | .titleSource = "prompt" else . end
  elif $ev == "PreToolUse" then
      .status = (if $in.tool_name == "AskUserQuestion" then "waiting" else "working" end)
      | .activity = act | .steps += 1
  elif $ev == "PostToolUse" then
      if todos then .total = (todos | length) | .done = ([todos[] | select(.status == "completed")] | length)
        | .activity = ((todos | map(select(.status == "in_progress")) | first | .activeForm // .content) // .activity)
      else . end
      | if .status == "waiting" then .status = "working" else . end
  elif $ev == "Notification" and (($in.notification_type // "") == "idle_prompt" or ($in.message // "" | test("waiting for your input"))) then .
  elif $ev == "Notification" then .status = "waiting" | .activity = (($in.message // "Needs your attention") | cut(80))
  elif $ev == "Stop" then .status = "done" | .activity = "Finished — ready for you"
  else . end
' > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" || rm -f "$f.tmp"
exit 0
