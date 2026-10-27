#!/usr/bin/env bash
# Static checks that the release pieces agree (DESIGN.md 11): the files release.yml publishes are the files
# scripts/build-release.sh builds, they include everything install.sh downloads and the files the router's updater
# requires, the release is tagged plain X.Y.Z, the tag's commit is read one way (tag_commit), both workflows build and
# test the way the docs say, and no shell variable runs into « or » (macOS's bash 3.2).
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

# The updater on the router (update.uc) asks every release for these two by name, and an installed updater of
# any older version keeps asking for them (DESIGN.md 11)
UPDATER="$TREE/shadow-vpn/files/usr/share/ucode/shadow-vpn/update.uc"
needed="SHA256SUMS shadow-vpn.apk"
missing=
unnamed=
for f in $needed; do
	case " $workflow_assets " in *" $f "*) ;; *) missing="$missing $f" ;; esac
	grep -qF "$f" "$UPDATER" 2>/dev/null || unnamed="$unnamed $f"
done
if [ -n "$workflow_assets" ] && [ -z "$missing$unnamed" ]; then
	ok "the files the updater requires are published ($needed)"
else
	nok "the files the updater requires are published" "not published:${missing:- none}, not named in update.uc:${unnamed:- none}"
fi

case " $summed " in
*" install.sh "*) ok "SHA256SUMS covers install.sh too" ;;
*) nok "SHA256SUMS covers install.sh too" "SUMMED='$summed'" ;;
esac

if grep -qF -- '-f tag_name="$VERSION"' "$RELEASE" && ! grep -Eq '"v\$VERSION"|tag="v|tag_name="v|tags: \["v' "$RELEASE"; then
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

# The release list lags behind a draft created a moment ago (a published run failed on it): the publish job takes
# the draft's id from the create call and never looks the draft up in that list
if grep -qF 'id=$(gh api -X POST "repos/$GH_REPO/releases"' "$RELEASE" && grep -qF -- '-F draft=true --jq .id)' "$RELEASE" &&
	! grep -Eq 'gh release (create|upload)|^ *id=\$\(gh api --paginate' "$RELEASE"; then
	ok "publish works with the id the API returns for the new draft, not a lookup in the release list"
else
	nok "publish works with the id the API returns for the new draft" "release.yml creates or finds the draft another way"
fi

# The notes get the console marker from build/CONSOLE_UPDATE (DESIGN.md 11.1): the sparse checkout of the job that
# writes them must bring that file along, or a marked release would be published without its marker
if grep -q '^            /build/CONSOLE_UPDATE$' "$RELEASE" && grep -qF 'bash .github/scripts/release-notes.sh >' "$RELEASE"; then
	ok "the job that writes the release notes checks out build/CONSOLE_UPDATE"
else
	nok "the job that writes the release notes checks out build/CONSOLE_UPDATE" "release-notes.sh would never see the marker file"
fi

# A push to master starts release.yml only (which calls ci.yml): no second, skipped CI run for the same push
if grep -q '^    branches: \[master\]$' "$RELEASE" && grep -q '^    branches-ignore: \[master\]$' "$CI" &&
	! grep -q 'if: inputs.release ||' "$CI"; then
	ok "a push to master runs release.yml, ci.yml runs for the other branches and pull requests"
else
	nok "a push to master runs release.yml only" "release.yml must trigger on master, ci.yml must ignore master"
fi

# macOS's /bin/bash 3.2 in a UTF-8 locale reads the first byte of « or » as part of a name: $v right before » is
# the variable "v\xC2", unbound under set -u. The CI's bash on Linux does not, the owner's Mac does; ${v} is safe
unbraced="$(cd "$TREE" && LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~[:space:]]' \
	scripts/*.sh scripts/lib/*.sh .github/scripts/*.sh tests/unit/release/*.sh .github/workflows/*.yml |
	cut -d: -f1,2 | tr '\n' ' ')"
if [ -z "$unbraced" ]; then
	ok "no shell variable runs into a non-ASCII character (macOS's bash 3.2 would read it as part of the name)"
else
	nok "no shell variable runs into a non-ASCII character" "write \${name} at $unbraced"
fi

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]
