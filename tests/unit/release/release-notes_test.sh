#!/usr/bin/env bash
# Tests of .github/scripts/release-notes.sh on the host: a throwaway repository with release tags, a side branch
# and a merge. Runs the script under $TEST_BASH (default: bash).
#
#   tests/unit/release/release-notes_test.sh          KEEP=1 keeps the temp dir
#
# Prints 'ok <name>' / 'not ok <name>: <why>' and exits non-zero on a failure.
# The conditions of check() are eval'd when it runs: single quotes on purpose, and the variables they read are
# set outside them.
# shellcheck disable=SC2016,SC2034
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TREE="$(cd "$HERE/../../.." && pwd -P)"
BASH_BIN="${TEST_BASH:-bash}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-notes-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$WORK"' EXIT; else echo "# work dir: $WORK"; fi

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_REPO GITHUB_REPOSITORY GITHUB_SHA VERSION
mkdir -p "$HOME"

pass=0 fail=0
ok() {
	echo "ok $1"
	pass=$((pass + 1))
}
nok() {
	echo "not ok $1: $2"
	fail=$((fail + 1))
}
check() {
	if eval "$2"; then ok "$1"; else nok "$1" "rc=$RC; condition: $2; output:
$OUT"; fi
}
line() { printf '%s\n' "$OUT" | grep -qxF -- "$1"; }

# new_repo <dir>: a repository with the scripts and build/VERSION 0.2.0
new_repo() {
	REPO="$1"
	mkdir -p "$REPO/build" "$REPO/scripts/lib" "$REPO/.github/scripts"
	cp "$TREE/scripts/lib/version.sh" "$REPO/scripts/lib/"
	cp "$TREE/.github/scripts/release-notes.sh" "$REPO/.github/scripts/"
	echo 0.2.0 >"$REPO/build/VERSION"
	git -c init.defaultBranch=master init -q "$REPO"
	git -C "$REPO" symbolic-ref HEAD refs/heads/master
	git -C "$REPO" add -A
	git -C "$REPO" commit -q -m 'feat: first'
}
c() { git -C "$REPO" commit -q --allow-empty -m "$1"; }
# rn [VAR=value...]: release-notes.sh of REPO, run from WORK; sets OUT and RC
rn() {
	OUT="$(cd "$WORK" && env GITHUB_REPOSITORY=owner/repo "$@" "$BASH_BIN" "$REPO/.github/scripts/release-notes.sh" 2>&1)"
	RC=$?
}

# v0.0.9 (legacy, annotated) - fix: second (0.1.0) - [side: side work (0.1.5)] - release commit - topic merge - fix: third
new_repo "$WORK/main"
git -C "$REPO" tag -a v0.0.9 -m legacy
c 'fix: second'
git -C "$REPO" tag 0.1.0
git -C "$REPO" checkout -q -b side
c 'side work'
git -C "$REPO" tag 0.1.5
git -C "$REPO" checkout -q master
c 'feat: release - version 0.2.0'
git -C "$REPO" checkout -q -b topic
c 'feat: topic'
git -C "$REPO" checkout -q master
git -C "$REPO" merge -q --no-ff -m 'Merge branch topic' topic
c 'fix: third'

rn
check "Russian first: version, OpenWrt 25.12, the same command for install and upgrade" '[ $RC = 0 ] && [ "$(printf "%s\n" "$OUT" | head -n 1)" = "Shadow для OpenWrt 0.2.0 (OpenWrt 25.12 и новее). Установка и обновление — одна и та же команда на роутере, удаление — она же с \`--uninstall\`:" ]'
check "then English" 'line "Shadow for OpenWrt 0.2.0 (OpenWrt 25.12 and newer). Install or upgrade on the router with the same command, remove with \`--uninstall\`:"'
check "the install command of this repository" 'line "sh <(wget -O - https://raw.githubusercontent.com/owner/repo/HEAD/install.sh)"'
check "the README links" 'line "Подробнее: [README](https://github.com/owner/repo#readme) · Details: [README.en.md](https://github.com/owner/repo/blob/HEAD/README.en.md)"'
check "changes since the previous release tag in the history (0.1.0, not the side branch's 0.1.5)" 'line "Изменения с 0.1.0 / Changes since 0.1.0:"'
check "the commits since then, newest first" '[ "$(printf "%s\n" "$OUT" | grep "^- " | tr "\n" "|")" = "- fix: third|- feat: topic|" ]'
check "...without merges, release commits, older or side commits" '! line "- Merge branch topic" && ! line "- feat: release - version 0.2.0" && ! line "- fix: second" && ! line "- side work"'
git -C "$REPO" tag 0.2.0
rn
check "a tag of the version itself (a retry) is not the previous one" 'line "Изменения с 0.1.0 / Changes since 0.1.0:"'
rn GH_REPO=other/name GITHUB_SHA=0.1.0 VERSION=0.1.0
check "GH_REPO, GITHUB_SHA and VERSION: the history up to that commit, since the legacy tag v0.0.9" 'line "Изменения с v0.0.9 / Changes since v0.0.9:" && line "- fix: second" && ! line "- fix: third" && line "sh <(wget -O - https://raw.githubusercontent.com/other/name/HEAD/install.sh)" && line "Shadow for OpenWrt 0.1.0 (OpenWrt 25.12 and newer). Install or upgrade on the router with the same command, remove with \`--uninstall\`:"'

new_repo "$WORK/first"
c 'fix: a'
rn
check "no release tag yet: every commit" '[ $RC = 0 ] && line "Изменения / Changes:" && line "- fix: a" && line "- feat: first"'
git -C "$REPO" tag 0.1.0
c 'feat: release - version 0.2.0'
rn
check "only a release commit since the last tag" 'line "Изменения с 0.1.0 / Changes since 0.1.0:" && line "- только новая версия / version bump only"'
rn VERSION=v0.2.0
check "a malformed VERSION is refused" '[ $RC = 1 ]'

# The console marker (DESIGN.md 11.1): update.uc refuses a release whose body has a line that is exactly
# `shadow-update: console` (CONSOLE_RE /(^|\n)shadow-update: console(\n|$)/, after it removed CR)
marker() { printf '%s\n' "$OUT" | grep -cx 'shadow-update: console'; }
rn
check "no build/CONSOLE_UPDATE: no console marker" '[ $RC = 0 ] && [ "$(marker)" = 0 ] && ! printf "%s" "$OUT" | grep -q "shadow-update"'
printf '0.2.0\n' >"$REPO/build/CONSOLE_UPDATE"
rn
check "build/CONSOLE_UPDATE names this version: the last line is the marker, once, as update.uc reads it" \
	'[ $RC = 0 ] && [ "$(marker)" = 1 ] && [ "$(printf "%s\n" "$OUT" | tail -n 1)" = "shadow-update: console" ] && ! printf "%s" "$OUT" | grep -q "$(printf "\r")"'
check "...with a line that says so in Russian and English" 'printf "%s\n" "$OUT" | grep -q "Эту версию обновление из LuCI не устанавливает" && printf "%s\n" "$OUT" | grep -q "Updates from LuCI do not install this version"'
printf ' 0.2.0 \r\n' >"$REPO/build/CONSOLE_UPDATE"
rn
check "...also with blanks and CRLF around the version" '[ "$(marker)" = 1 ]'
printf '0.1.9\n' >"$REPO/build/CONSOLE_UPDATE"
rn
check "a CONSOLE_UPDATE left from another release marks nothing" '[ $RC = 0 ] && [ "$(marker)" = 0 ]'
rm -f "$REPO/build/CONSOLE_UPDATE"

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]
