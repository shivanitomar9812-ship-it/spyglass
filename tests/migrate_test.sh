#!/bin/bash
# migrate.sh: the one-time move from the old name (Tower, ~/.claude/tower) to Spyglass.
source "$(dirname "$0")/lib.sh"
H="$TMP/home"; mkdir -p "$H/.claude/tower/sessions"
echo '{"id":"a"}' > "$H/.claude/tower/sessions/a.json"; echo bin > "$H/.claude/tower/Tower"; echo '{"x":1}' > "$H/.claude/tower/tokens.json"
mig() { env -i HOME="$H" PATH=/usr/bin:/bin SPYGLASS_TEST=1 bash "$SCRIPTS/migrate.sh"; }
mig >/dev/null
eq "state moved" '{"id":"a"}' "$(cat "$H/.claude/spyglass/sessions/a.json" 2>/dev/null)"
eq "old path is a link to the new one" "$H/.claude/spyglass" "$(readlink "$H/.claude/tower")"
eq "old hooks still write through the link" "yes" "$(echo '{}' > "$H/.claude/tower/sessions/b.json" && [ -f "$H/.claude/spyglass/sessions/b.json" ] && echo yes)"
eq "old app removed" "no" "$([ -e "$H/.claude/spyglass/Tower" ] && echo yes || echo no)"
eq "token counts kept" '{"x":1}' "$(cat "$H/.claude/spyglass/tokens.json")"
before=$(ls -la "$H/.claude"); mig >/dev/null
eq "second run changes nothing" "$before" "$(ls -la "$H/.claude")"
# Fresh install (no old folder): nothing happens.
H2="$TMP/home2"; mkdir -p "$H2/.claude"; env -i HOME="$H2" PATH=/usr/bin:/bin SPYGLASS_TEST=1 bash "$SCRIPTS/migrate.sh" >/dev/null
eq "fresh install untouched" "" "$(ls "$H2/.claude")"
finish
