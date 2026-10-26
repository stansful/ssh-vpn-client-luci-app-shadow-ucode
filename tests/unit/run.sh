#!/bin/sh
# Runs tests/unit/*_test.uc inside a throwaway container of the lab router image, with a copy of the
# package tree at /src. Usage: tests/unit/run.sh [name-substring]
#
# The tree is streamed in with tar instead of a bind mount: OrbStack bind mounts can show a stale,
# cut-off copy of a file for a while after it was rewritten.
#
# Needs the lab image (build it once with tests/lab/up.sh, or BUILD_ONLY=1 tests/lab/up.sh).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
IMAGE="${SHADOW_TEST_IMAGE:-shadow-testenv/tr3000-deps:25.12.6}"
FILTER="${1:-}"

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
	echo "missing image $IMAGE: run tests/lab/up.sh (or BUILD_ONLY=1 tests/lab/up.sh) first" >&2
	exit 2
}

# The image has no ucode-mod-socket/digest extras by default; install what the tests need once per run.
COPYFILE_DISABLE=1 tar -C "$SRC" --exclude ./.git --exclude ./tests/lab/dl --exclude ./tests/lab/state --exclude ./tests/lab/ref \
	--exclude ./out --exclude ./.cache --exclude node_modules --exclude .DS_Store -cf - . |
docker run --rm -i --cap-add NET_ADMIN --entrypoint /bin/sh "$IMAGE" -c '
	set -u
	mkdir -p /src && tar -xf - -C /src && chmod -R a-w /src || exit 2
	apk add -q ucode-mod-digest ucode-mod-socket >/dev/null 2>&1 || true
	fail=0
	for t in /src/tests/unit/*_test.uc; do
		[ -e "$t" ] || continue
		case "$t" in *"'"$FILTER"'"*) ;; *) continue ;; esac
		echo "# $(basename "$t")"
		ucode -L /src/shadow-vpn/files/usr/share/ucode "$t" || fail=1
	done
	exit $fail
'
