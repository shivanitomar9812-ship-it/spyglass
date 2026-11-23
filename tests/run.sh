#!/bin/bash
# Regression checks for Spyglass. Run before every release (scripts/release.sh does).
# Each escaped bug gets a test here; see HARNESS.md.
cd "$(dirname "$0")" || exit 1
rc=0
# Every test runs the hooks through plugin/bin/Spyglass: rebuild it first if any source is newer.
# Escaped (0.23.0 work): hook tests ran before panel_test rebuilt it and tested the previous build.
bin=../plugin/bin/Spyglass
if [ -n "$(find ../plugin/app -name '*.swift' -newer "$bin")" ]; then bash ../plugin/app/build.sh "$bin" >/dev/null 2>&1 || { echo "build failed"; exit 1; }; fi
for t in record_test.sh send_test.sh resume_test.sh answer_test.sh away_test.sh setup_test.sh doctor_test.sh uninstall_test.sh panel_test.sh; do bash "$t" || rc=1; done
node core_test.js || rc=1
[ $rc = 0 ] && echo "ALL PASSED" || echo "FAILURES ABOVE"
exit $rc
