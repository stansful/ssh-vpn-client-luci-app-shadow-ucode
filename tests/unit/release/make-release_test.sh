#!/usr/bin/env bash
# Tests of scripts/make-release.sh on the host: throwaway repositories, each a clone of its own local bare
# "origin", in a temp dir (TMPDIR). The script runs from a directory outside the repository, under $TEST_BASH
# (default: bash from PATH, /bin/bash 3.2 on macOS). git reads only this test's config (HOME is the temp dir).
#
#   tests/unit/release/make-release_test.sh          KEEP=1 keeps the temp dir
#
# Prints 'ok <name>' / 'not ok <name>: <why>' and exits non-zero on a failure.
# The conditions of check() are eval'd when it runs: single quotes on purpose, and the variables they read are
# set outside them.
# shellcheck disable=SC2016,SC2034
set -u

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TREE="$(cd "$HERE/../../.." && pwd -P)"
BASH_BIN="${TEST_BASH:-bash}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-release-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$WORK"' EXIT; else echo "# work dir: $WORK"; fi

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
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
# check <name> <condition (eval'd)>: on failure prints the script's output
check() {
	if eval "$2"; then ok "$1"; else nok "$1" "rc=$RC; condition: $2; output:
$OUT"; fi
}
has() { case $OUT in *"$1"*) return 0 ;; esac; return 1; }

echo "# scripts/make-release.sh under $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"'), $(git --version)"

# --- the template: origin.git with master (build/VERSION 0.1.0, the script) and the tag 0.1.0 on its first commit
TPL="$WORK/tpl"
mkdir -p "$TPL/seed/build" "$TPL/seed/scripts/lib"
cp "$TREE/scripts/make-release.sh" "$TPL/seed/scripts/"
cp "$TREE/scripts/lib/version.sh" "$TPL/seed/scripts/lib/"
echo 0.1.0 >"$TPL/seed/build/VERSION"
echo readme >"$TPL/seed/README"
printf 'out/\n' >"$TPL/seed/.gitignore"
(
	set -e
	cd "$TPL/seed"
	git -c init.defaultBranch=master init -q .
	git symbolic-ref HEAD refs/heads/master
	git add -A
	git commit -q -m init
	git tag 0.1.0
	echo more >>README
	git commit -q -am 'fix: something'
	git init -q --bare "$TPL/origin.git"
	git -C "$TPL/origin.git" symbolic-ref HEAD refs/heads/master
	git push -q "$TPL/origin.git" master 0.1.0
) || {
	echo "not ok the test fixture could not be built"
	exit 1
}

# new_case <name>: CASE/origin.git (a copy of the template's) and its clone REPO
new_case() {
	CASE="$WORK/$1"
	mkdir -p "$CASE"
	cp -R "$TPL/origin.git" "$CASE/origin.git"
	git clone -q "$CASE/origin.git" "$CASE/repo"
	REPO="$CASE/repo"
}
# mr <stdin (printf %b)> [args...]: make-release.sh of REPO, run from WORK; sets OUT and RC
mr() {
	local input="$1"
	shift
	OUT="$(cd "$WORK" && printf '%b' "$input" | "$BASH_BIN" "$REPO/scripts/make-release.sh" "$@" 2>&1)"
	RC=$?
}
g() { git -C "$REPO" "$@"; }
ver() { cat "$REPO/build/VERSION"; }
count() { g rev-list --count HEAD; }
subject() { g log -1 --format=%s; }
head_files() { g show --name-only --format= HEAD | tr '\n' ' '; }
origin_ref() { git -C "$CASE/origin.git" rev-parse -q --verify "refs/heads/$1"; }
all_tags() { { g tag -l && git -C "$CASE/origin.git" tag -l; } | LC_ALL=C sort | tr '\n' ' '; }
clean() { [ -z "$(g status --porcelain)" ]; }

# --- Enter takes the suggestion
new_case enter
before=$(count) head=$(g rev-parse HEAD) origin=$(origin_ref master) tags=$(all_tags)
mr '\n\n\n'
check "prints the current version" 'has "Текущая версия (build/VERSION): 0.1.0"'
check "prints the last release tag" 'has "Последний релизный тег:         0.1.0"'
check "suggests the next patch version" 'has "Новая версия [0.1.1]: "'
check "Enter takes 0.1.1, Enter commits (run from outside the repository)" '[ $RC = 0 ] && [ "$(ver)" = 0.1.1 ]'
check "...exactly one new commit, on the old HEAD" '[ "$(count)" = $((before + 1)) ] && [ "$(g rev-parse HEAD^)" = "$head" ]'
check "...named 'feat: release - version 0.1.1'" '[ "$(subject)" = "feat: release - version 0.1.1" ]'
check "...with build/VERSION only" '[ "$(head_files)" = "build/VERSION " ] && clean'
check "...never pushes and never asks to: origin and tags untouched" '[ "$(origin_ref master)" = "$origin" ] && [ "$(all_tags)" = "$tags" ] && ! has "Запуш" && ! has "запуш" && ! has "git push"'

# --- the prompt asks again after a refused version
new_case reask
before=$(count)
mr '0.0.9\n0.1.0\n1.2\nv0.2.0\n01.2.3\n0.2.0-rc1\n  0.2.0  \ny\nn\n'
check "prompt: a lower version is refused" 'has "версия 0.0.9 не выше текущей 0.1.0. Введите другую версию."'
check "prompt: an existing tag is refused" 'has "тег 0.1.0 уже есть: версия 0.1.0 уже выпускалась. Введите другую версию."'
check "prompt: a malformed version is refused" 'has "«1.2» — не версия X.Y.Z" && has "«01.2.3» — не версия X.Y.Z" && has "«0.2.0-rc1» — не версия X.Y.Z"'
check "prompt: a version with v is refused" 'has "«v0.2.0»: нужна версия без «v», например 0.2.0"'
check "prompt: then 0.2.0 (spaces trimmed) is committed" '[ $RC = 0 ] && [ "$(ver)" = 0.2.0 ] && [ "$(count)" = $((before + 1)) ] && [ "$(subject)" = "feat: release - version 0.2.0" ]'

# --- end of input at the prompt
new_case eof
before=$(count)
mr 'abc\n'
check "end of input at the prompt changes nothing" '[ $RC = 1 ] && has "ввод прерван, ничего не изменено" && [ "$(ver)" = 0.1.0 ] && [ "$(count)" = "$before" ] && clean'

# --- refused versions given as the argument
new_case refuse
before=$(count)
for c in "0.0.9|версия 0.0.9 не выше текущей 0.1.0" "0.1.0|тег 0.1.0 уже есть" "1.2|«1.2» — не версия X.Y.Z" \
	"1.2.3.4|не версия X.Y.Z" "v0.2.0|нужна версия без «v»" "01.2.3|не версия X.Y.Z" "1.02.3|не версия X.Y.Z" \
	"0.2.0-rc1|не версия X.Y.Z" " 0.2.0|не версия X.Y.Z" "|версия не указана"; do
	v=${c%%|*} want=${c#*|}
	mr '' --yes "$v"
	check "argument '$v' is refused: $want" '[ $RC = 1 ] && has "Ошибка: " && has "$want" && [ "$(ver)" = 0.1.0 ] && [ "$(count)" = "$before" ] && clean'
done

# --- tags: local only, origin only, a legacy vX.Y.Z on origin
new_case tags
g tag 0.5.0
git clone -q "$CASE/origin.git" "$CASE/other"
git -C "$CASE/other" tag 0.7.0
git -C "$CASE/other" tag -a v0.8.0 -m legacy
git -C "$CASE/other" push -q origin 0.7.0 v0.8.0
before=$(count) origin=$(origin_ref master)
mr '' --yes 0.5.0
check "a local tag is refused" '[ $RC = 1 ] && has "тег 0.5.0 уже есть"'
mr '' --yes 0.7.0
check "a tag only on origin is refused" '[ $RC = 1 ] && has "тег 0.7.0 уже есть"'
mr '' --yes 0.8.0
check "a legacy tag v0.8.0 on origin is refused for 0.8.0" '[ $RC = 1 ] && has "тег v0.8.0 уже есть"'
mr '' --yes 0.6.0
check "a version below the highest tag is refused" '[ $RC = 1 ] && has "версия 0.6.0 не выше последнего релизного тега v0.8.0"'
check "...nothing changed" '[ "$(ver)" = 0.1.0 ] && [ "$(count)" = "$before" ] && clean'
mr ''
check "the last tag and the suggestion come from all tags" 'has "Последний релизный тег:         v0.8.0" && has "Новая версия [0.8.1]: " && [ $RC = 1 ]'
mr '' --yes
check "--yes takes the suggested 0.8.1 and commits without a question" '[ $RC = 0 ] && [ "$(ver)" = 0.8.1 ] && [ "$(subject)" = "feat: release - version 0.8.1" ] && [ "$(count)" = $((before + 1)) ]'
check "--yes does not push" '[ "$(origin_ref master)" = "$origin" ] && ! has "Запуш"'

# --- a dirty tree
new_case dirty
before=$(count)
echo change >>"$REPO/README"
mr '' --yes 0.2.0
check "a modified file is refused" '[ $RC = 1 ] && has "есть незакоммиченные изменения" && has "README" && [ "$(ver)" = 0.1.0 ] && [ "$(count)" = "$before" ]'
check "...and stays modified" '[ "$(g status --porcelain)" = " M README" ]'
g checkout -q -- README
echo new >"$REPO/newfile"
g add newfile
mr '' --yes 0.2.0
check "a staged file is refused" '[ $RC = 1 ] && has "есть незакоммиченные изменения" && [ "$(ver)" = 0.1.0 ] && [ "$(count)" = "$before" ]'
g reset -q
mr '' --yes 0.2.0
check "an untracked file is only a warning, and stays out of the commit" '[ $RC = 0 ] && has "есть файлы не в git" && has "  newfile" && [ "$(head_files)" = "build/VERSION " ] && [ "$(g status --porcelain)" = "?? newfile" ]'

# --- git hooks: they run on the commit's own index, so what a pre-commit hook stages lands in the commit
# hook <commands>: REPO's pre-commit hook
hook() {
	printf '#!/bin/sh\n%s\n' "$1" >"$REPO/.git/hooks/pre-commit"
	chmod +x "$REPO/.git/hooks/pre-commit"
}
no_verify="git commit --no-verify -m 'feat: release - version 0.1.1' -- build/VERSION"
new_case hooknew
hook 'echo x >>other && git add other'
head=$(g rev-parse HEAD) origin=$(origin_ref master)
mr '' 0.1.1 --yes
check "a hook that stages a new file: the release commit is undone" '[ $RC = 1 ] && has "хук git (pre-commit или другой) изменил релизный коммит" && [ "$(g rev-parse HEAD)" = "$head" ] && [ "$(origin_ref master)" = "$origin" ]'
check "...it names the files the commit had and how to commit past the hook" 'has "  build/VERSION" && has "  other" && has "$no_verify"'
check "...build/VERSION is back in the tree and the index, the hook's file is left untracked" '[ "$(ver)" = 0.1.0 ] && [ "$(g status --porcelain)" = "?? other" ]'
new_case hooktracked
hook 'echo x >>README && git add README'
head=$(g rev-parse HEAD)
mr '' 0.1.1 --yes
check "a hook that stages a tracked file: the commit is undone, the hook's change is left unstaged" '[ $RC = 1 ] && has "  README" && [ "$(g rev-parse HEAD)" = "$head" ] && [ "$(ver)" = 0.1.0 ] && [ "$(g status --porcelain)" = " M README" ]'
new_case hookversion
hook 'echo 9.9.9 >build/VERSION && git add build/VERSION'
head=$(g rev-parse HEAD)
mr '' 0.1.1 --yes
check "a hook that rewrites build/VERSION: the commit is undone" '[ $RC = 1 ] && has "изменил релизный коммит" && [ "$(g rev-parse HEAD)" = "$head" ] && [ "$(ver)" = 0.1.0 ] && clean'
new_case hookfail
hook 'exit 1'
head=$(g rev-parse HEAD)
mr '' 0.1.1 --yes
check "a failing hook: no commit, build/VERSION is back" '[ $RC = 1 ] && has "git commit не удался, build/VERSION возвращён" && [ "$(g rev-parse HEAD)" = "$head" ] && [ "$(ver)" = 0.1.0 ] && clean'
new_case hookok
hook 'git add build/VERSION'
before=$(count)
mr '' 0.1.1 --yes
check "a hook that stages only build/VERSION (a formatter) keeps the release commit" '[ $RC = 0 ] && [ "$(count)" = $((before + 1)) ] && [ "$(subject)" = "feat: release - version 0.1.1" ] && [ "$(head_files)" = "build/VERSION " ] && clean'

# --- no push, ever
new_case nopush
origin=$(origin_ref master) tags=$(all_tags)
mr '\n\nд\n'
check "the commit stays local: no push question, origin and tags untouched" '[ $RC = 0 ] && [ "$(subject)" = "feat: release - version 0.1.1" ] && [ "$(origin_ref master)" = "$origin" ] && [ "$(all_tags)" = "$tags" ] && ! has "Запуш"'
mr '' 0.1.2 --push
check "--push is not an option" '[ $RC = 2 ] && has "неизвестный параметр --push"'

# --- the confirmation, --no-commit, options
new_case decline
before=$(count)
mr '0.1.1\nn\n'
check "a declined commit puts build/VERSION back" '[ $RC = 1 ] && has "Отменено" && [ "$(ver)" = 0.1.0 ] && [ "$(count)" = "$before" ] && clean'
mr '0.1.1\n'
check "end of input at the confirmation puts build/VERSION back" '[ $RC = 1 ] && has "ввод прерван, build/VERSION возвращён" && [ "$(ver)" = 0.1.0 ] && [ "$(count)" = "$before" ] && clean'
new_case nocommit
before=$(count)
mr '' 0.1.1 --no-commit
check "--no-commit writes build/VERSION and commits nothing" '[ $RC = 0 ] && [ "$(ver)" = 0.1.1 ] && [ "$(count)" = "$before" ] && [ "$(g status --porcelain)" = " M build/VERSION" ] && has "--no-commit"'
check "...and shows the diff" 'has "+0.1.1" && has "-0.1.0"'
mr '' --bogus
check "an unknown option is a usage error" '[ $RC = 2 ] && has "неизвестный параметр --bogus"'
mr '' 0.1.1 0.1.2
check "two versions are a usage error" '[ $RC = 2 ]'
mr '' --help
check "--help prints the usage" '[ $RC = 0 ] && has "scripts/make-release.sh [X.Y.Z] [--yes] [--no-commit]"'

# --- branches
new_case branch
g checkout -q -b feature
origin=$(origin_ref master)
mr '' 0.1.1 --yes
check "another branch: a warning, then the commit on that branch" '[ $RC = 0 ] && has "вы на ветке feature, а релиз выходит из ветки по умолчанию master" && [ "$(g symbolic-ref --short HEAD)" = feature ] && [ "$(subject)" = "feat: release - version 0.1.1" ] && [ "$(origin_ref master)" = "$origin" ]'
new_case detached
g checkout -q --detach
mr '' 0.1.1 --yes
check "a detached HEAD is refused" '[ $RC = 1 ] && has "detached HEAD" && [ "$(ver)" = 0.1.0 ]'
new_case behind
git clone -q "$CASE/origin.git" "$CASE/other"
echo other >>"$CASE/other/README"
git -C "$CASE/other" commit -q -am 'fix: other'
git -C "$CASE/other" push -q origin master
g fetch -q origin
origin=$(origin_ref master)
mr '' 0.1.1 --yes
check "a branch behind origin: a warning to pull first, the commit is still made locally" '[ $RC = 0 ] && has "ветка master отстаёт от origin/master на 1" && has "сначала git pull" && [ "$(origin_ref master)" = "$origin" ] && [ "$(subject)" = "feat: release - version 0.1.1" ]'

# --- no origin, no repository, the current version
new_case noorigin
g remote remove origin
before=$(count)
mr '' --yes
check "without origin: local tags count, the commit is made" '[ $RC = 0 ] && [ "$(ver)" = 0.1.1 ] && [ "$(count)" = $((before + 1)) ]'
new_case ahead
echo 0.3.0 >"$REPO/build/VERSION"
g commit -q -am 'feat: release - version 0.3.0'
mr ''
check "a version above every tag: says it is not released yet and suggests the next patch" 'has "Тега 0.3.0 ещё нет" && has "Новая версия [0.3.1]: "'
echo x >"$REPO/build/VERSION"
g commit -q -am broken
mr '' --yes 0.4.0
check "a malformed build/VERSION is refused" '[ $RC = 1 ] && has "в build/VERSION «x», а не X.Y.Z"'
mkdir -p "$WORK/plain/scripts/lib" "$WORK/plain/build"
cp "$TREE/scripts/make-release.sh" "$WORK/plain/scripts/"
cp "$TREE/scripts/lib/version.sh" "$WORK/plain/scripts/lib/"
echo 0.1.0 >"$WORK/plain/build/VERSION"
REPO="$WORK/plain"
mr '' 0.1.1 --yes
check "outside a git repository it is refused" '[ $RC = 1 ] && has "не git-репозиторий" && [ "$(ver)" = 0.1.0 ]'

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]
