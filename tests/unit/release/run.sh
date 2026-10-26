#!/usr/bin/env bash
# Runs the tests of the release scripts on the host (tests/unit/release/*_test.sh): scripts/make-release.sh,
# .github/scripts/release-state.sh and release-notes.sh against throwaway git repositories in TMPDIR. Needs bash
# 3.2+ and git; TEST_BASH=<bash> runs the tests and the scripts under that bash (macOS: /bin/bash is 3.2).
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
fail=0
for t in "$HERE"/*_test.sh; do
	echo "# ${t##*/}"
	"${TEST_BASH:-bash}" "$t" || fail=1
done
exit "$fail"
