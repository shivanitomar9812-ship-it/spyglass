#!/bin/bash
# Spyglass doctor (/spyglass:doctor): finds the session it runs in, and checks each link. Fake home throughout.
source "$(dirname "$0")/lib.sh"
BIN="$ROOT/plugin/bin/Spyglass"
H="$TMP/home"; mkdir -p "$H/.claude/sessions" "$H/.claude/spyglass/sessions"
doc() { env -i HOME="$H" PATH=/usr/bin:/bin "$BIN" doctor "$ROOT/plugin" "$@" 2>/dev/null; }

# Finds the session from the claude process it runs under (a stand-in process named "claude"). Escaped (0.20.4):
# ps pads its columns and the parser lost the command name, so it never found the session.
mkdir -p "$TMP/bin"; ln -s /bin/bash "$TMP/bin/claude"
out=$(env -i HOME="$H" PATH=/usr/bin:/bin "$TMP/bin/claude" -c 'echo "{\"pid\":$$,\"sessionId\":\"fake-session\"}" > "$HOME/.claude/sessions/$$.json"; "'"$BIN"'" doctor --which; true')
eq "finds its session through the claude process" "fake-session" "$(sed -n 's/.*session=//p' <<<"$out")"

# This session's hooks: not reporting, then reporting.
out=$(doc --session s1); eq "no row: says hooks aren't reporting" 1 "$(grep -c "isn't reporting" <<<"$out")"
echo '{"id":"s1","hooks":"0.1.0"}' > "$H/.claude/spyglass/sessions/s1.json"
out=$(doc --session s1); eq "old hooks: says restart" 1 "$(grep -c 'claude --resume' <<<"$out")"
v=$(jq -r .version "$ROOT/plugin/.claude-plugin/plugin.json")
echo "{\"id\":\"s1\",\"hooks\":\"$v\"}" > "$H/.claude/spyglass/sessions/s1.json"
out=$(doc --session s1); eq "current hooks: ✓" 1 "$(grep -c '✓ This session reports' <<<"$out")"

# Claude Code newer than the version Spyglass was verified against: said, as information.
echo '{"pid":1,"sessionId":"s1","version":"9.0.0"}' > "$H/.claude/sessions/1.json"
out=$(doc --session s1); eq "newer Claude Code noted" 1 "$(grep -c 'newer than the' <<<"$out")"
# Actions that failed in the last day, from the panel's log.
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) action failed: /model sonnet (exit 1) in Demo [iTerm.app]" > "$H/.claude/spyglass/spyglass.log"
out=$(doc --session s1); eq "recent failed action reported" 1 "$(grep -c '1 action failed in the last day' <<<"$out")"

# Panel not installed; statusline not feeding.
eq "panel missing reported" 1 "$(grep -c "panel isn't installed" <<<"$out")"
eq "statusline not feeding reported" 1 "$(grep -c '/spyglass:setup' <<<"$out")"

eq "exit 1 when something needs fixing" 1 "$(doc --session s1 >/dev/null; echo $?)"
finish
