#!/bin/bash
# uninstall.sh (/spyglass:uninstall): lists first, undoes everything with --yes, leaves your own settings alone. Fake home.
source "$(dirname "$0")/lib.sh"
H="$TMP/home"; mkdir -p "$H/.claude" "$H/Library/LaunchAgents" "$H/.cursor/extensions/local.spyglass-focus-0.5.0" "$H/Library/Application Support/Cursor/User"
run() { env -i HOME="$H" PATH=/usr/bin:/bin SPYGLASS_TEST=1 bash "$SCRIPTS/$1" "${@:2}"; }
# A setup to undo: statusline wrapped by /spyglass:setup (around the user's own), login item, tab-title setting, state.
printf '#!/bin/bash\necho mine\n' > "$H/sl.sh"
echo '{"theme":"dark","statusLine":{"type":"command","command":"~/sl.sh"}}' > "$H/.claude/settings.json"
run setup.sh on >/dev/null
echo '<plist/>' > "$H/Library/LaunchAgents/dev.spyglass.panel.plist"
echo '{"terminal.integrated.tabs.title":"${sequence}","editor.fontSize":13}' > "$H/Library/Application Support/Cursor/User/settings.json"
mkdir -p "$H/.claude/spyglass/sessions"

before=$(cd "$H" && find . | sort; cat .claude/settings.json)
out=$(run uninstall.sh)
eq "dry run lists 5 steps" 5 "$(grep -c '^• Would' <<<"$out")"
eq "dry run changes nothing" "$before" "$(cd "$H" && find . | sort; cat .claude/settings.json)"

out=$(run uninstall.sh --yes)
eq "statusline: original back" '{"command":"~/sl.sh","type":"command"}' "$(jq -cS .statusLine "$H/.claude/settings.json")"
eq "your other settings kept" "dark" "$(jq -r .theme "$H/.claude/settings.json")"
eq "login item removed" "no" "$([ -f "$H/Library/LaunchAgents/dev.spyglass.panel.plist" ] && echo yes || echo no)"
eq "tab-title setting reset, the rest kept" "null|13" "$(jq -r '"\(."terminal.integrated.tabs.title")|\(."editor.fontSize")"' "$H/Library/Application Support/Cursor/User/settings.json")"
eq "state removed" "no" "$([ -e "$H/.claude/spyglass" ] && echo yes || echo no)"
eq "says the last step" 1 "$(grep -c '/plugin uninstall spyglass@spyglass' <<<"$out")"

# A statusline line added by hand: removed, with a backup; the rest of the script kept.
printf '#!/bin/bash\nin=$(cat)\n[ -x ~/.claude/spyglass/stats.sh ] && (~/.claude/spyglass/stats.sh <<<"$in" &)\necho mine\n' > "$H/sl2.sh"
echo '{"statusLine":{"type":"command","command":"~/sl2.sh"}}' > "$H/.claude/settings.json"
run uninstall.sh --yes >/dev/null
eq "hand-added line removed, rest kept" "#!/bin/bash|in=\$(cat)|echo mine" "$(paste -sd'|' "$H/sl2.sh")"
eq "backup of the statusline script" 1 "$(ls "$H"/sl2.sh.bak-spyglass-* 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$H/.cursor/extensions/local.spyglass-focus-0.5.0"   # what Cursor's own uninstall does (skipped in tests)
eq "nothing left: says so" 1 "$(run uninstall.sh | grep -c "Nothing of Spyglass's is left")"
finish
