#!/usr/bin/env bash
# Static checks that the release pieces agree (DESIGN.md 11): the files release.yml publishes are the files
# scripts/build-release.sh builds, they include everything install.sh downloads, the release is tagged plain
# X.Y.Z, the tag's commit is read one way (tag_commit), and both workflows build and test the way the docs say.
#
#   tests/unit/release/assets_test.sh
#
# Prints 'ok <name>' / 'not ok <name>: <why>' and exits non-zero on a failure.
# The patterns match the workflows' and scripts' own text, $VERSION and the like included.
# shellcheck disable=SC2016
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TREE="$(cd "$HERE/../../.." && pwd -P)"
RELEASE="$TREE/.github/workflows/release.yml"
CI="$TREE/.github/workflows/ci.yml"
BUILD="$TREE/scripts/build-release.sh"

pass=0 fail=0
ok() {
	echo "ok $1"
	pass=$((pass + 1))
}
nok() {
	echo "not ok $1: $2"
	fail=$((fail + 1))
}
words() { tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' '; }

workflow_assets="$(sed -n 's/^  ASSETS: //p' "$RELEASE" | words)"
summed="$(sed -n 's/^SUMMED="\(.*\)"$/\1/p' "$BUILD")"
built="$(printf '%s SHA256SUMS' "$summed" | words)"
if [ -n "$workflow_assets" ] && [ "$workflow_assets" = "$built" ]; then
	ok "release.yml publishes what build-release.sh builds ($workflow_assets)"
else
	nok "release.yml publishes what build-release.sh builds" "release.yml: '$workflow_assets', build-release.sh: '$built'"
fi

downloads="$(sed -n 's/.*files="\(\$files \)\{0,1\}\([^"]*\)".*/\2/p' "$TREE/install.sh") SHA256SUMS"
missing=
for f in $downloads; do
	case " $workflow_assets " in *" $f "*) ;; *) missing="$missing $f" ;; esac
done
if [ -z "$missing" ] && [ "$(printf '%s' "$downloads" | words)" != "SHA256SUMS " ]; then
	ok "every file install.sh downloads is published ($(printf '%s' "$downloads" | words))"
else
	nok "every file install.sh downloads is published" "not published:${missing:- (install.sh lists no files?)}"
fi

case " $summed " in
*" install.sh "*) ok "SHA256SUMS covers install.sh too" ;;
*) nok "SHA256SUMS covers install.sh too" "SUMMED='$summed'" ;;
esac

if grep -q 'gh release create "\$VERSION" ' "$RELEASE" && ! grep -Eq '"v\$VERSION"|tag="v|tags: \["v' "$RELEASE"; then
	ok "the release and its tag are the plain version X.Y.Z"
else
	nok "the release and its tag are the plain version X.Y.Z" "release.yml creates or reads a vX.Y.Z tag"
fi

# `git ls-remote` given a pattern leaves out an annotated tag's peeled line, so it reads the tag object, not the
# commit: an annotated tag release-state.sh accepts as retry would fail the publish job after publishing
STATE="$TREE/.github/scripts/release-state.sh"
if grep -qF 'tag_sha=$(git ls-remote --tags origin | tag_commit "$VERSION")' "$RELEASE" &&
	grep -qF 'tag_sha="$(tag_commit "$VERSION" <<<"$refs")"' "$STATE" &&
	grep -qF 'refs="$(git -C "$ROOT" ls-remote --tags origin)"' "$STATE" &&
	! grep -Eq 'ls-remote[^|]*refs/tags' "$RELEASE" "$STATE"; then
	ok "release.yml checks the tag's commit the way release-state.sh reads it (tag_commit over every tag)"
else
	nok "release.yml checks the tag's commit the way release-state.sh reads it" "a tag is read another way (ls-remote with a pattern?)"
fi

if grep -q 'run: scripts/build-release.sh --out "\$RUNNER_TEMP/out"' "$RELEASE" && grep -q 'run: scripts/build-release.sh$' "$CI"; then
	ok "release.yml and the CI build with scripts/build-release.sh"
else
	nok "release.yml and the CI build with scripts/build-release.sh" "a workflow builds another way"
fi

if grep -q 'uses: ./.github/workflows/ci.yml' "$RELEASE"; then
	ok "release.yml runs the whole CI (ci.yml) before it builds"
else
	nok "release.yml runs the whole CI (ci.yml) before it builds" "no workflow_call of ci.yml"
fi

jobs="$(awk '/^jobs:/ { in_jobs = 1; next } in_jobs && /^  [a-z][a-z-]*:$/ { n++ } END { print n + 0 }' "$CI")"
skips="$(grep -c "^    if: inputs.release || github.event_name != 'push' || github.ref != format('refs/heads/{0}', github.event.repository.default_branch)$" "$CI")"
if [ "$jobs" -gt 0 ] && [ "$jobs" = "$skips" ]; then
	ok "every ci.yml job leaves a push to the default branch to release.yml ($jobs jobs)"
else
	nok "every ci.yml job leaves a push to the default branch to release.yml" "$jobs jobs, $skips with the condition"
fi

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]
