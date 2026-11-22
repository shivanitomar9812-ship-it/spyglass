#!/bin/bash
# record.sh: hook input -> session file.
source "$(dirname "$0")/lib.sh"
export SPYGLASS_HOME="$TMP/spyglass"
hook() { launchd bash "$SCRIPTS/record.sh" <<<"$1"; }
field() { jq -r "$2" "$SPYGLASS_HOME/sessions/$1.json" 2>/dev/null; }

hook '{"session_id":"a","hook_event_name":"SessionStart","cwd":"/tmp"}'
eq "start is idle" "idle" "$(field a .status)"
hook '{"session_id":"a","hook_event_name":"UserPromptSubmit","prompt":"fix the bug","cwd":"/tmp"}'
eq "prompt sets working" "working" "$(field a .status)"
eq "prompt becomes title" "fix the bug|prompt" "$(field a '"\(.title)|\(.titleSource)"')"

# Permission prompt: waiting with the command; cleared by the next tool event.
hook '{"session_id":"a","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}'
eq "permission waits" "waiting|rm -rf build" "$(field a '"\(.status)|\(.permission.detail)"')"
hook '{"session_id":"a","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{}}'
eq "permission cleared after tool" "null" "$(field a .permission)"

# Questions: recorded as a question, never as a permission prompt (Allow once = key 1 would pick option 1).
q='{"questions":[{"question":"Which fruit?","header":"Fruit","multiSelect":false,"options":[{"label":"Apple"},{"label":"Banana"}]}]}'
hook "{\"session_id\":\"q\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":$q}"
hook "{\"session_id\":\"q\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":$q}"
eq "question recorded" "waiting|Which fruit?|Apple,Banana|null" "$(field q '"\(.status)|\(.question.text)|\(.question.options | join(","))|\(.permission)"')"
hook '{"session_id":"q","hook_event_name":"PostToolUse","tool_name":"AskUserQuestion","tool_input":{}}'
eq "question cleared after answer" "null" "$(field q .question)"
qm='{"questions":[{"question":"Pick some","multiSelect":true,"options":[{"label":"A"},{"label":"B"}]}]}'
hook "{\"session_id\":\"q2\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"AskUserQuestion\",\"tool_input\":$qm}"
eq "multi-select: no options (answer in terminal)" "0" "$(field q2 '.question.options | length')"

# Escaped bug (0.9.0): Claude Code's one-minute idle reminder showed as "Needs you".
hook '{"session_id":"a","hook_event_name":"Stop"}'
hook '{"session_id":"a","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
eq "idle reminder keeps done" "done" "$(field a .status)"
hook '{"session_id":"a","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}'
eq "real notification waits" "waiting" "$(field a .status)"

# Where the session runs (terminal, Claude extension panel, desktop app, JetBrains).
CLAUDE_CODE_ENTRYPOINT=claude-vscode hook '{"session_id":"v","hook_event_name":"SessionStart","cwd":"/tmp"}'
eq "entrypoint recorded" "claude-vscode" "$(field v .entrypoint)"

# A turn that ends by asking you something (plain text, no question tool) waits on you. Escaped (0.17.0): it showed as Done.
stop() { hook "$(jq -nc --arg m "$1" '{session_id: "t", hook_event_name: "Stop", last_assistant_message: $m}')"; }
stop $'Built it.\n\nShall I continue with the **welcome card**?'
eq "ends with a question: waiting" "waiting|Shall I continue with the welcome card?" "$(field t '"\(.status)|\(.asked.text)"')"
hook '{"session_id":"t","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
eq "idle reminder keeps the question" "waiting" "$(field t .status)"
hook '{"session_id":"t","hook_event_name":"UserPromptSubmit","prompt":"yes"}'
eq "your reply clears it" "null|working" "$(field t '"\(.asked)|\(.status)"')"
stop $'All done.\n\n- Released as **0.17.0**.'
eq "plain ending: done" "done|null" "$(field t '"\(.status)|\(.asked)"')"
eq "last line kept for the row preview" "Released as 0.17.0." "$(field t .lastLine)"
CLAUDE_PLUGIN_ROOT="$ROOT/plugin" hook '{"session_id":"t","hook_event_name":"UserPromptSubmit","prompt":"next"}'
eq "hooks record their Spyglass version" "$(jq -r .version "$ROOT/plugin/.claude-plugin/plugin.json")" "$(field t .hooks)"
eq "a new prompt clears the preview" "null" "$(field t .lastLine)"
stop $'Here is the fix:\n```\nif ok? then\n```'
eq "code block ending: done" "done" "$(field t .status)"

# Titles: /rename (custom) beats the AI title.
tp="$TMP/t.jsonl"; echo '{"type":"ai-title","aiTitle":"Auto name"}' > "$tp"
hook "{\"session_id\":\"b\",\"hook_event_name\":\"Stop\",\"transcript_path\":\"$tp\"}"
eq "ai title" "Auto name|ai" "$(field b '"\(.title)|\(.titleSource)"')"
echo '{"type":"custom-title","customTitle":"My name"}' >> "$tp"
hook "{\"session_id\":\"b\",\"hook_event_name\":\"Stop\",\"transcript_path\":\"$tp\"}"
eq "custom title wins" "My name|custom" "$(field b '"\(.title)|\(.titleSource)"')"

# SessionEnd keeps prompted sessions for Resume, drops empty ones.
hook '{"session_id":"empty","hook_event_name":"SessionStart","cwd":"/tmp"}'
hook '{"session_id":"a","hook_event_name":"SessionEnd"}'
hook '{"session_id":"empty","hook_event_name":"SessionEnd"}'
eq "ended kept" "fix the bug" "$(jq -r .prompt "$SPYGLASS_HOME/ended/a.json" 2>/dev/null)"
eq "empty not kept" "no" "$([ -f "$SPYGLASS_HOME/ended/empty.json" ] && echo yes || echo no)"
eq "live file removed" "no" "$([ -f "$SPYGLASS_HOME/sessions/a.json" ] && echo yes || echo no)"
# Escaped (0.17.0-0.20.3): run from an installed plugin (a path under ~/.claude), the hook matched its own process as
# "claude", recorded that pid, and the panel deleted the live session's row as soon as the hook exited.
# Run it the way an installed plugin does: from a folder under .claude.
IH="$TMP/ihome"; P="$IH/.claude/plugins/cache/spyglass/spyglass/9.9.9"; mkdir -p "$P/bin" "$P/scripts" "$IH/.claude/sessions"
cp "$ROOT/plugin/bin/Spyglass" "$P/bin/Spyglass"; cp "$SCRIPTS/record.sh" "$P/scripts/record.sh"
sleep 60 & live=$!
echo "{\"pid\":$live,\"sessionId\":\"reg\",\"cwd\":\"/tmp\"}" > "$IH/.claude/sessions/$live.json"
echo '{"session_id":"reg","hook_event_name":"SessionStart","cwd":"/tmp"}' | env -i HOME="$IH" PATH=/usr/bin:/bin bash "$P/scripts/record.sh"
eq "installed hook: pid from Claude Code's registry" "$live" "$(jq -r .pid "$IH/.claude/spyglass/sessions/reg.json")"
echo '{"session_id":"noreg","hook_event_name":"SessionStart","cwd":"/tmp"}' | env -i HOME="$IH" PATH=/usr/bin:/bin bash "$P/scripts/record.sh"
p2=$(jq -r '.pid // empty' "$IH/.claude/spyglass/sessions/noreg.json")
eq "installed hook: never records its own (already gone) process" "ok" "$({ [ -z "$p2" ] || kill -0 "$p2" 2>/dev/null; } && echo ok || echo "dead pid $p2")"
kill $live 2>/dev/null; wait $live 2>/dev/null

# The binary uses $HOME like the scripts (it once used the account's home, so a test hook wrote to the real one).
H2="$TMP/otherhome"; mkdir -p "$H2"
echo '{"session_id":"homecheck","hook_event_name":"SessionStart","cwd":"/tmp"}' | env -i HOME="$H2" PATH=/usr/bin:/bin bash "$SCRIPTS/record.sh"
eq "hooks follow \$HOME" "yes" "$([ -f "$H2/.claude/spyglass/sessions/homecheck.json" ] && echo yes || echo no)"

# Escaped bug (0.6.1): under launchd, jq was not on PATH and nothing reached Cursor. Since 0.17.0 Spyglass needs no
# jq at all: the JSON work is in its binary. No plugin script may call jq or perl again (comments aside).
eq "no jq or perl in plugin scripts" "" "$(grep -nE '(^|[^#]*[;&|(]\s*|^\s*)(jq|perl) ' "$SCRIPTS"/*.sh | grep -v '^\S*:\s*#' | grep -v 'statuslines often use' )"
finish
