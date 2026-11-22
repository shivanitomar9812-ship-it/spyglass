#!/bin/bash
# setup.sh (/spyglass:setup): wraps the statusline without editing it, idempotent, fully undoable. Fake HOME throughout.
source "$(dirname "$0")/lib.sh"
export FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME/.claude"
export SPYGLASS_HOME="$FAKE_HOME/.claude/spyglass"
S="$FAKE_HOME/.claude/settings.json"
setup() { launchd bash "$SCRIPTS/setup.sh" "$@"; }
sample='{"session_id":"z","model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":32.4},"workspace":{"current_dir":"/x/repo"}}'
# Run the configured statusline the way Claude Code does: its command through a shell, data on stdin.
run_statusline() { launchd bash -c "$(jq -r .statusLine.command "$S")" <<<"$sample"; }

# 1. No statusline: a short one is added, and it feeds Spyglass.
echo '{"theme":"dark"}' > "$S"
setup on >/dev/null
eq "no statusline: wrapper installed" "true" "$(jq -r '.statusLine.command | contains("spyglass/statusline.sh")' "$S")"
eq "other settings kept" "dark" "$(jq -r .theme "$S")"
eq "default line" "repo  Opus 5.5  ctx 32%" "$(run_statusline)"
for _ in $(seq 1 30); do [ -s "$SPYGLASS_HOME/stats/z.json" ] && break; sleep 0.1; done
eq "feeds Spyglass" "Opus 5.5|32" "$(jq -r '"\(.model)|\(.ctx)"' "$SPYGLASS_HOME/stats/z.json" 2>/dev/null)"
setup off >/dev/null
eq "off: no statusline again" "null|dark" "$(jq -c '.statusLine' "$S")|$(jq -r .theme "$S")"

# 2. An existing statusline script: wrapped, shown exactly as before, restored exactly on off.
mkdir -p "$FAKE_HOME/bin"; printf '#!/bin/bash\nin=$(cat); echo "MINE $(jq -r .model.display_name <<<"$in")"\n' > "$FAKE_HOME/bin/sl.sh"; chmod +x "$FAKE_HOME/bin/sl.sh"
orig='{"type":"command","command":"~/bin/sl.sh","padding":2}'
jq --argjson o "$orig" '.statusLine = $o' "$S" > "$S.t" && mv "$S.t" "$S"
out=$(setup on); eq "wrapped" "true" "$(jq -r '.statusLine.command | contains("spyglass/statusline.sh")' "$S")"
eq "padding kept" "2" "$(jq -r .statusLine.padding "$S")"
eq "your statusline shows as before" "MINE Opus 5.5" "$(run_statusline)"
eq "backup made" 1 "$(ls "$S".bak-spyglass-* 2>/dev/null | wc -l | tr -d ' ' | cut -c1 | sed 's/[2-9]/1/')"
before=$(jq -cS . "$S"); setup on >/dev/null
eq "second run changes nothing" "$before" "$(jq -cS . "$S")"
setup off >/dev/null
eq "off restores it exactly" "$(jq -cS . <<<"$orig")" "$(jq -cS .statusLine "$S")"

# 3. A statusline that already calls stats.sh by hand (the manual setup): left alone.
printf '#!/bin/bash\nin=$(cat)\n[ -x ~/.claude/spyglass/stats.sh ] && (~/.claude/spyglass/stats.sh <<<"$in" &)\necho hi\n' > "$FAKE_HOME/bin/manual.sh"
jq '.statusLine = {"type":"command","command":"~/bin/manual.sh"}' "$S" > "$S.t" && mv "$S.t" "$S"
before=$(jq -cS . "$S"); out=$(setup on)
eq "manual setup detected" 1 "$(grep -c 'already feeds Spyglass' <<<"$out")"
eq "manual setup untouched" "$before" "$(jq -cS . "$S")"

# 4. Editor tab titles: plain JSON gets the setting; settings with comments are left untouched.
C="$FAKE_HOME/Library/Application Support/Cursor/User"; V="$FAKE_HOME/Library/Application Support/Code/User"; mkdir -p "$C" "$V"
echo '{"editor.fontSize": 13}' > "$C/settings.json"
printf '{\n  // my comment\n  "editor.fontSize": 14\n}\n' > "$V/settings.json"; vs=$(cat "$V/settings.json")
out=$(setup tabs)
eq "Cursor: tab titles set, rest kept" '${sequence}|13' "$(jq -r '"\(."terminal.integrated.tabs.title")|\(."editor.fontSize")"' "$C/settings.json")"
eq "VS Code with comments: untouched" "$vs" "$(cat "$V/settings.json")"
eq "says why it skipped" 1 "$(grep -c 'comments' <<<"$out")"
finish
