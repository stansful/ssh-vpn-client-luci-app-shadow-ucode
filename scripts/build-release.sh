#!/usr/bin/env bash
# Builds the release assets of build/VERSION exactly as the release workflow does (.github/workflows/release.yml
# runs this script, and so does the CI's unit job): build/mk_apk.sh with STRICT=1 in alpine:3.23 (docker), then
# install.sh next to the packages and SHA256SUMS over every published file:
#   shadow-vpn.apk luci-app-shadow-vpn.apk luci-i18n-shadow-vpn-ru.apk install.sh SHA256SUMS
# The files get the time of the HEAD commit (SOURCE_DATE_EPOCH), so one commit builds the same packages here and
# in CI. Prints the version, the files with their sizes and the sums.
#
#   scripts/build-release.sh [--test] [--out DIR]
#
#   --test     first tests/unit/run.sh (needs the lab image: BUILD_ONLY=1 tests/lab/up.sh) and
#              node tests/unit/luci/check_views.mjs
#   --out DIR  output directory (default: out/)
#
# Env: SOURCE_DATE_EPOCH  the files' time (default: the HEAD commit's time, else now)
# bash 3.2 (macOS) or 5 (Linux); needs docker unless it runs as root in alpine:3.23 (build/mk_apk.sh).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=scripts/lib/version.sh
. "$HERE/lib/version.sh"

# Published with every release, in this order; SHA256SUMS covers the others. release.yml checks the build
# against the same list (ASSETS).
SUMMED="shadow-vpn.apk luci-app-shadow-vpn.apk luci-i18n-shadow-vpn-ru.apk install.sh"
ASSETS="$SUMMED SHA256SUMS"

usage() {
	cat <<'EOF'
Собирает файлы релиза из build/VERSION так же, как GitHub Actions (release.yml запускает этот скрипт):
пакеты (build/mk_apk.sh, STRICT=1), install.sh и SHA256SUMS.

  scripts/build-release.sh [--test] [--out DIR]

  --test     сначала тесты: tests/unit/run.sh и node tests/unit/luci/check_views.mjs
  --out DIR  куда положить файлы (по умолчанию out/)
EOF
}
say() { printf '%s\n' "$*"; }
die() {
	printf 'Ошибка: %s\n' "$*" >&2
	exit 1
}
usage_error() {
	printf 'Ошибка: %s\n\n' "$*" >&2
	usage >&2
	exit 2
}
sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$@"
	else
		shasum -a 256 "$@"
	fi
}

run_tests='' out=''
while [ $# -gt 0 ]; do
	case $1 in
	-h | --help)
		usage
		exit 0
		;;
	--test) run_tests=1 ;;
	--out)
		[ $# -ge 2 ] && [ -n "$2" ] || usage_error "--out: укажите каталог"
		out=$2
		shift
		;;
	--out=?*) out=${1#--out=} ;;
	*) usage_error "неизвестный параметр $1" ;;
	esac
	shift
done

version="$(cat "$ROOT/build/VERSION")"
version_valid "$version" || die "в build/VERSION «${version}», а не X.Y.Z (без ведущих нулей и «v»)."

if [ -n "$run_tests" ]; then
	say "== Тесты: tests/unit/run.sh"
	"$ROOT/tests/unit/run.sh" || die "tests/unit/run.sh не прошёл."
	say "== Тесты: node tests/unit/luci/check_views.mjs"
	command -v node >/dev/null 2>&1 || die "для --test нужен Node.js 22.18+."
	node "$ROOT/tests/unit/luci/check_views.mjs" || die "tests/unit/luci/check_views.mjs не прошёл."
fi

sh -n "$ROOT/install.sh" || die "в install.sh синтаксическая ошибка."

# The files' time: the HEAD commit's, as in CI. No git when SOURCE_DATE_EPOCH is given.
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
	if command -v git >/dev/null 2>&1 &&
		top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" &&
		[ "$(cd "$top" && pwd -P)" = "$ROOT" ] &&
		epoch="$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null)" && [ -n "$epoch" ]; then
		SOURCE_DATE_EPOCH=$epoch
		export SOURCE_DATE_EPOCH
		if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]; then
			say "Внимание: есть незакоммиченные изменения — эта сборка не совпадёт с релизом коммита $(git -C "$ROOT" rev-parse --short HEAD)." >&2
		fi
	else
		say "Внимание: не git-репозиторий — у файлов в пакетах будет текущее время." >&2
	fi
fi

mkdir -p "${out:=$ROOT/out}"
out="$(cd "$out" && pwd -P)"

say "== Сборка $version: build/mk_apk.sh (STRICT=1)"
STRICT=1 OUT="$out" sh "$ROOT/build/mk_apk.sh" "$version"
cp "$ROOT/install.sh" "$out/install.sh"
# shellcheck disable=SC2086 # SUMMED is a list of plain file names
(cd "$out" && sha256 $SUMMED >SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS)
(cd "$out" && sha256 -c SHA256SUMS >/dev/null) || die "файлы в $out не совпадают с SHA256SUMS."
for f in $ASSETS; do
	[ -s "$out/$f" ] || die "$f не собран."
done

say
say "Релиз $version (пакеты $version-r1, SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-сейчас}): $out"
for f in $ASSETS; do
	printf '  %9s  %s\n' "$(wc -c <"$out/$f" | tr -d ' ')" "$f"
done
say
say "SHA256SUMS:"
sed 's/^/  /' "$out/SHA256SUMS"
other=
for f in "$out"/* "$out"/.[!.]*; do
	[ -e "$f" ] || continue
	case " $ASSETS " in *" ${f##*/} "*) continue ;; esac
	other="$other ${f##*/}"
done
[ -z "$other" ] || say "В $out есть и другие файлы, в релиз они не входят:$other"
