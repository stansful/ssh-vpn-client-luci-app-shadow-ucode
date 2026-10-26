#!/bin/sh
# build/po2lmo.py against the official tool, on the host (needs python3):
#
#   tests/unit/packaging/po2lmo_test.sh
#   LUCI_SRC=<openwrt/luci checkout at the feed's commit> tests/unit/packaging/po2lmo_test.sh
#
# edge.lmo is what the official po2lmo (luci-base src/, openwrt-25.12 @75a306d) writes for
# edge.po. With LUCI_SRC set, every .lmo in the lab router image (luci-i18n-base-ru) is also
# rebuilt from its .po and compared. Prints 'ok <name>' / 'not ok <name>: <why>'.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
PO2LMO="$HERE/../../../build/po2lmo.py"
IMAGE="${SHADOW_TEST_IMAGE:-shadow-testenv/tr3000-deps:25.12.6}"
T="$(mktemp -d "${TMPDIR:-/tmp}/shv-po2lmo.XXXXXX")"
trap 'rm -rf "$T"' EXIT
fail=0

ok() { echo "ok $1"; }
nok() { echo "not ok $1: $2"; fail=1; }
po2lmo() { python3 -I "$PO2LMO" "$@"; }

if po2lmo "$HERE/edge.po" "$T/edge.lmo" && cmp -s "$HERE/edge.lmo" "$T/edge.lmo"; then
	ok "edge.po compiles to the official tool's bytes"
else
	nok "edge.po compiles to the official tool's bytes" "output differs from edge.lmo"
fi

printf 'msgid ""\nmsgstr "Plural-Forms: nplurals=2;"\n\nmsgid "x"\nmsgstr ""\n' > "$T/empty.po"
if po2lmo "$T/empty.po" "$T/empty.lmo" && [ ! -e "$T/empty.lmo" ]; then
	ok "a catalog without translations writes no file"
else
	nok "a catalog without translations writes no file" "file written or error"
fi

printf 'msgid "a"\nmsgstr "b"\n\nmsgid "a"\nmsgstr "c"\n' > "$T/dup.po"
if po2lmo "$T/dup.po" "$T/dup.lmo" 2>"$T/dup.err"; then
	nok "a duplicate msgid is refused" "accepted"
else
	grep -q 'same key hash' "$T/dup.err" && ok "a duplicate msgid is refused" || nok "a duplicate msgid is refused" "$(cat "$T/dup.err")"
fi

python3 -I -c 'print("msgid \"" + "a" * 5000 + "\"\nmsgstr \"b\"")' > "$T/long.po"
if po2lmo "$T/long.po" "$T/long.lmo" 2>"$T/long.err"; then
	nok "a line longer than po2lmo.c reads is refused" "accepted"
else
	ok "a line longer than po2lmo.c reads is refused"
fi

if [ -n "${LUCI_SRC:-}" ]; then
	mkdir -p "$T/official"
	docker run --rm --entrypoint /bin/sh "$IMAGE" -c 'cd /usr/lib/lua/luci/i18n && tar -cf - *.lmo' | tar -xf - -C "$T/official"
	for f in "$T"/official/*.lmo; do
		b="$(basename "$f" .lmo)"
		name="${b%.*}"
		lc="${b##*.}"
		case "$lc" in zh-cn) d=zh_Hans ;; zh-tw) d=zh_Hant ;; pt-br) d=pt_BR ;; no) d=nb_NO ;; bn) d=bn_BD ;; *) d="$lc" ;; esac
		po="$(ls "$LUCI_SRC"/modules/*/po/"$d"/"$name".po "$LUCI_SRC"/applications/*/po/"$d"/"$name".po 2>/dev/null | head -n 1)"
		if [ -z "$po" ]; then
			nok "$b.lmo" "no $name.po for $d in $LUCI_SRC"
		elif po2lmo "$po" "$T/$b.lmo" && cmp -s "$f" "$T/$b.lmo"; then
			ok "$b.lmo from $IMAGE is rebuilt byte for byte"
		else
			nok "$b.lmo from $IMAGE is rebuilt byte for byte" "output differs"
		fi
	done
fi

exit "$fail"
