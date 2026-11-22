# Shared helpers for tests/*.sh. Each test file sources this, calls check/eq, and ends with `finish`.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/plugin/scripts"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# The panel runs scripts under launchd: no Homebrew on PATH. Every script test must run this way.
launchd() { env -i HOME="${FAKE_HOME:-$HOME}" PATH=/usr/bin:/bin:/usr/sbin:/sbin SPYGLASS_HOME="${SPYGLASS_HOME:-}" SPYGLASS_SEND_LOG="${SPYGLASS_SEND_LOG:-}" \
  SPYGLASS_SEND_ROUTE="${SPYGLASS_SEND_ROUTE:-}" CLAUDE_CODE_ENTRYPOINT="${CLAUDE_CODE_ENTRYPOINT:-}" "$@"; }
eq() {   # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$1" "$2" "$3"; fi
}
finish() { printf '%s: %d passed, %d failed\n' "$(basename "$0" .sh)" "$PASS" "$FAIL"; [ "$FAIL" = 0 ]; }
