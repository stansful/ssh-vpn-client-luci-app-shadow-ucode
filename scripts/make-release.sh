#!/usr/bin/env bash
# Prepares a release: shows the current version (build/VERSION) and the last release tag, asks for the new
# version (Enter takes the next patch version), checks that it is higher than the current version and every
# release tag (local ones and origin's), writes build/VERSION and commits only that file as
# "feat: release - version X.Y.Z". It never pushes: the release starts when that commit reaches the default
# branch on GitHub (.github/workflows/release.yml: the checks, the build and the release X.Y.Z). No tags here:
# GitHub creates the tag X.Y.Z when the workflow publishes the release (DESIGN.md 11).
#
#   scripts/make-release.sh [X.Y.Z] [--yes] [--no-commit]
#
# Runs from any directory; bash 3.2 (macOS) or 5 (Linux), BSD or GNU tools. Messages are in Russian.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=scripts/lib/version.sh
. "$HERE/lib/version.sh"

usage() {
	cat <<'EOF'
Готовит релиз Shadow для OpenWrt: новая версия в build/VERSION и коммит «feat: release - version X.Y.Z».
Релиз X.Y.Z выходит, когда этот коммит оказывается в ветке по умолчанию на GitHub.

  scripts/make-release.sh [X.Y.Z] [--yes] [--no-commit]

  X.Y.Z         новая версия; без неё скрипт покажет текущую и спросит (Enter — следующая патч-версия)
  -y, --yes     без вопросов: версия — следующая патч-версия (если не указана), коммит без подтверждения
  --no-commit   только записать build/VERSION, без коммита
  -h, --help    эта справка

Версия — X.Y.Z без ведущих нулей и без «v», выше текущей и всех релизных тегов (свои и в origin).
Теги скрипт не ставит: тег X.Y.Z создаёт GitHub при публикации релиза.
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'Внимание: %s\n' "$*" >&2; }
die() {
	printf 'Ошибка: %s\n' "$*" >&2
	exit 1
}
usage_error() {
	printf 'Ошибка: %s\n\n' "$*" >&2
	usage >&2
	exit 2
}
yes_answer() {
	case $1 in
	y | Y | yes | Yes | YES | д | Д | да | Да | ДА) return 0 ;;
	*) return 1 ;;
	esac
}
trim() {
	local s="$1"
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

new='' have_new='' yes='' commit=1
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	-y | --yes) yes=1 ;;
	--no-commit) commit= ;;
	-*) usage_error "неизвестный параметр $1" ;;
	*)
		[ -z "$have_new" ] || usage_error "версия указана дважды: $new и $1"
		new=$1 have_new=1
		;;
	esac
	shift
done

# --- the repository
command -v git >/dev/null 2>&1 || die "нужен git."
top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" ||
	die "$ROOT — не git-репозиторий. Сначала git init, первый коммит и git remote add origin <url>."
[ "$(cd "$top" && pwd -P)" = "$ROOT" ] || die "$ROOT — не корень git-репозитория (корень: $top)."
cd "$ROOT"
git rev-parse -q --verify HEAD >/dev/null || die "в репозитории ещё нет коммитов: сначала закоммитьте проект."
branch="$(git symbolic-ref -q --short HEAD)" ||
	die "HEAD не на ветке (detached HEAD): переключитесь на ветку, например: git switch master."
git ls-files --error-unmatch build/VERSION >/dev/null 2>&1 || die "build/VERSION не в git: закоммитьте его."

dirty="$(git status --porcelain --untracked-files=no)"
if [ -n "$dirty" ]; then
	printf 'Ошибка: есть незакоммиченные изменения (рабочее дерево или индекс):\n%s\n' "$dirty" >&2
	printf 'Закоммитьте их или уберите (git stash) и запустите снова: в релизный коммит входит только build/VERSION.\n' >&2
	exit 1
fi
untracked="$(git ls-files --others --exclude-standard)"
if [ -n "$untracked" ]; then
	warn "есть файлы не в git, в релиз они не попадут:"
	printf '%s\n' "$untracked" | sed -n '1,10s/^/  /p' >&2
	[ "$(printf '%s\n' "$untracked" | wc -l | tr -d ' ')" -le 10 ] || printf '  …\n' >&2
fi

has_origin=
git remote get-url origin >/dev/null 2>&1 && has_origin=1

# The default branch: origin's HEAD, else master or main (origin's or local)
default=
if ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; then
	default=${ref#origin/}
else
	for b in master main; do
		if git show-ref -q --verify "refs/remotes/origin/$b" || git show-ref -q --verify "refs/heads/$b"; then
			default=$b
			break
		fi
	done
fi
if [ -z "$default" ]; then
	warn "не удалось определить ветку по умолчанию; релиз выходит только из неё."
elif [ "$branch" != "$default" ]; then
	warn "вы на ветке $branch, а релиз выходит из ветки по умолчанию $default: этот коммит выпустится только после слияния в $default."
fi
if [ -n "$has_origin" ] && git show-ref -q --verify "refs/remotes/origin/$branch"; then
	behind="$(git rev-list --count "HEAD..refs/remotes/origin/$branch")"
	[ "$behind" = 0 ] ||
		warn "ветка $branch отстаёт от origin/$branch на $behind коммит(ов) (по последнему fetch): сначала git pull."
fi

# --- versions
current="$(cat build/VERSION)"
version_valid "$current" || die "в build/VERSION «${current}», а не X.Y.Z: исправьте файл вручную и закоммитьте."

tags="$(git tag -l)"
if [ -n "$has_origin" ]; then
	if remote="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags origin)"; then
		tags="$tags
$remote"
	else
		warn "не удалось прочитать теги origin ($(git remote get-url origin)): сравниваю только с локальными тегами."
	fi
fi
highest="$(printf '%s\n' "$tags" | highest_tag)"
highest_version=${highest%% *}
last_tag=${highest#* }

say "Текущая версия (build/VERSION): $current"
if [ -n "$highest" ]; then
	say "Последний релизный тег:         $last_tag"
else
	say "Релизных тегов пока нет."
fi
if [ -z "$highest" ] || version_gt "$current" "$highest_version"; then
	say "Тега $current ещё нет: если коммит с этой версией уже в ветке по умолчанию, релиз $current выйдет и без новой версии."
fi
base=$current
[ -z "$highest" ] || ! version_gt "$highest_version" "$base" || base=$highest_version
suggested="$(version_next_patch "$base")"

# check_version <v>: prints why v cannot be the new version, and fails
check_version() {
	local v="$1" t
	if [ -z "$v" ]; then
		echo "версия не указана"
		return 1
	fi
	if ! version_valid "$v"; then
		case $v in
		v[0-9]* | V[0-9]*) echo "«${v}»: нужна версия без «v», например ${v#?}" ;;
		*) echo "«${v}» — не версия X.Y.Z (три числа без ведущих нулей, например $suggested)" ;;
		esac
		return 1
	fi
	t="$(printf '%s\n' "$tags" | tag_of_version "$v")"
	if [ -n "$t" ]; then
		echo "тег $t уже есть: версия $v уже выпускалась"
		return 1
	fi
	if ! version_gt "$v" "$current"; then
		echo "версия $v не выше текущей $current"
		return 1
	fi
	if [ -n "$highest" ] && ! version_gt "$v" "$highest_version"; then
		echo "версия $v не выше последнего релизного тега $last_tag"
		return 1
	fi
}

if [ -n "$have_new" ]; then
	reason="$(check_version "$new")" || die "$reason."
elif [ -n "$yes" ]; then
	new=$suggested
	say "Новая версия: $new"
else
	while :; do
		printf 'Новая версия [%s]: ' "$suggested"
		if ! IFS= read -r answer; then
			echo
			die "ввод прерван, ничего не изменено."
		fi
		answer="$(trim "$answer")"
		[ -n "$answer" ] || answer=$suggested
		if reason="$(check_version "$answer")"; then
			new=$answer
			break
		fi
		printf '  %s. Введите другую версию.\n' "$reason" >&2
	done
fi

# --- build/VERSION and the commit
message="feat: release - version $new"
restore() { git checkout -q -- build/VERSION; }
trap 'restore; printf "\nПрервано: build/VERSION возвращён.\n" >&2; exit 130' INT TERM
printf '%s\n' "$new" >build/VERSION
git --no-pager diff -- build/VERSION

if [ -z "$commit" ]; then
	trap - INT TERM
	say "build/VERSION: $new. Коммит не создан (--no-commit). Закоммитьте только этот файл:"
	say "  git commit -m '$message' -- build/VERSION"
	exit 0
fi
if [ -z "$yes" ]; then
	printf 'Закоммитить build/VERSION как «%s»? [Y/n] ' "$message"
	if ! IFS= read -r answer; then
		echo
		restore
		die "ввод прерван, build/VERSION возвращён."
	fi
	answer="$(trim "$answer")"
	if [ -n "$answer" ] && ! yes_answer "$answer"; then
		restore
		say "Отменено: build/VERSION возвращён, коммита нет."
		exit 1
	fi
fi
parent="$(git rev-parse HEAD)"
if ! git commit -q -m "$message" -- build/VERSION; then
	restore
	die "git commit не удался, build/VERSION возвращён."
fi
# git hooks (pre-commit and the like) run on the commit's own index: whatever one stages lands in the commit.
# The release commit is build/VERSION with the new version and nothing else, or it is undone.
changed="$(git diff-tree -r --name-only "$parent" HEAD)"
if [ "$changed" != build/VERSION ] || [ "$(git show HEAD:build/VERSION 2>/dev/null)" != "$new" ]; then
	git reset -q --soft "$parent"
	git reset -q -- build/VERSION
	restore
	trap - INT TERM
	{
		printf 'Ошибка: хук git (pre-commit или другой) изменил релизный коммит, а в нём должен быть только build/VERSION с версией %s. В коммит попало:\n' "$new"
		printf '%s\n' "$changed" | sed 's/^/  /'
		printf 'Коммит отменён, build/VERSION возвращён; что хук поменял в рабочем дереве, там и осталось (git status).\n'
		printf 'Поправьте хук или закоммитьте в обход хуков: scripts/make-release.sh %s --no-commit, затем\n' "$new"
		printf "  git commit --no-verify -m '%s' -- build/VERSION\n" "$message"
	} >&2
	exit 1
fi
trap - INT TERM
say "Коммит $(git rev-parse --short HEAD): $message"
