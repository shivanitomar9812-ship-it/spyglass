#!/bin/bash
# resume.sh: refuses bad ids and missing folders before opening anything.
source "$(dirname "$0")/lib.sh"
launchd bash "$SCRIPTS/resume.sh" iTerm.app "" /tmp 'x; rm -rf ~' >/dev/null 2>&1; eq "bad session id" 3 $?
launchd bash "$SCRIPTS/resume.sh" iTerm.app "" /nonexistent 11111111-2222-3333-4444-555555555555 >/dev/null 2>&1; eq "missing folder" 5 $?
eq "resume.sh finds jq under launchd" "ok" "$(launchd bash -c "eval \"\$(grep '^export PATH' '$SCRIPTS/resume.sh')\"; command -v jq >/dev/null && echo ok")"
finish
