#!/bin/bash
# Regression checks for Spyglass. Run before every release (scripts/release.sh does).
# Each escaped bug gets a test here; see HARNESS.md.
cd "$(dirname "$0")" || exit 1
rc=0
for t in record_test.sh send_test.sh resume_test.sh answer_test.sh setup_test.sh migrate_test.sh doctor_test.sh panel_test.sh; do bash "$t" || rc=1; done
node core_test.js || rc=1
[ $rc = 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE"
exit $rc
