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
stop $'All done. Released as 0.17.0.'
eq "plain ending: done" "done|null" "$(field t '"\(.status)|\(.asked)"')"
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
# Escaped bug (0.6.1): under launchd, jq was not on PATH and nothing reached Cursor. Since 0.17.0 Spyglass needs no
# jq at all: the JSON work is in its binary. No plugin script may call jq or perl again (comments aside).
eq "no jq or perl in plugin scripts" "" "$(grep -nE '(^|[^#]*[;&|(]\s*|^\s*)(jq|perl) ' "$SCRIPTS"/*.sh | grep -v '^\S*:\s*#' | grep -v 'statuslines often use' )"
finish
