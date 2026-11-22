#!/bin/bash
# Release gate: tests -> universal build -> tests on that binary -> snapshot -> bump -> commit/push -> plugin update
# -> installed == running. Stops at the first failure.
# Usage: scripts/release.sh <version> "<commit subject>" ["<commit body>"]
# Env: SPYGLASS_GH_USER = gh account to push with (its token is used for this script only; the active account is
#      never switched); SPYGLASS_NO_PUSH=1 to stop before pushing.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; cd "$root"
ver="${1:?version, e.g. 0.10.0}"; subject="${2:?commit subject}"; body="${3:-}"
step() { printf '\n== %s\n' "$*"; }

step "Tests"
bash tests/run.sh

step "Universal build"
bash plugin/app/build.sh plugin/bin/Spyglass --universal
SPYGLASS_BIN="$root/plugin/bin/Spyglass" bash tests/panel_test.sh
echo "Snapshot: $root/tests/out/panel.png (look at it before shipping UI changes)"

step "Bump to $ver and commit"
jq --arg v "$ver" '.version = $v' plugin/.claude-plugin/plugin.json > plugin/.claude-plugin/plugin.json.tmp
mv plugin/.claude-plugin/plugin.json.tmp plugin/.claude-plugin/plugin.json
git add -u
git add tests scripts HARNESS.md 2>/dev/null || true
msg="$subject"; [ -n "$body" ] && msg="$subject

$body"
git commit -q -m "$msg

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git log --oneline -1
[ "${SPYGLASS_NO_PUSH:-}" = 1 ] && { echo "SPYGLASS_NO_PUSH=1: stopping before push."; exit 0; }

step "Push and update the plugin"
# Use the release account's token for these commands only. Never `gh auth switch`: the active account is shared by
# every Claude session on the machine, and switching races with them.
if [ -n "${SPYGLASS_GH_USER:-}" ]; then
  GH_TOKEN=$(gh auth token --user "$SPYGLASS_GH_USER") || { echo "No gh login for $SPYGLASS_GH_USER"; exit 1; }
  export GH_TOKEN
fi
git push -q origin HEAD
git tag "v$ver" && git push -q origin "v$ver"   # never forced; CI tests the tag and attaches its build to a GitHub release
remote=$(gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/commits/HEAD" --jq .sha)
[ "$remote" = "$(git rev-parse HEAD)" ] || { echo "Push did not reach GitHub"; exit 1; }
claude plugin marketplace update spyglass >/dev/null
claude plugin update spyglass@spyglass | tail -1
unset GH_TOKEN

step "Installed == running"
cache="$HOME/.claude/plugins/cache/spyglass/spyglass/$ver"
[ -d "$cache" ] || { echo "Plugin $ver not installed"; exit 1; }
bash "$cache/scripts/launch.sh"; sleep 3
home="$HOME/.claude/spyglass"
cmp "$cache/bin/Spyglass" "$home/Spyglass"
cmp "$cache/editor-extension/core.js" "$home/editor-core.js"
for f in send resume focus stats; do cmp "$cache/scripts/$f.sh" "$home/$f.sh"; done
pgrep -f "^$home/Spyglass$" >/dev/null || { echo "Panel not running"; exit 1; }
echo "Released $ver: installed files match, panel running."
