#!/bin/sh
# Builds the Shadow for OpenWrt packages (noarch, apk v3) with stock apk-tools, no OpenWrt SDK:
#   out/shadow-vpn.apk  out/luci-app-shadow-vpn.apk  out/luci-i18n-shadow-vpn-ru.apk  out/SHA256SUMS
#
#   build/mk_apk.sh [VERSION]        VERSION is X.Y.Z, default build/VERSION; packages get X.Y.Z-r1
#
# Runs as root in alpine:3.23 (apk-tools 3.0.8; OpenWrt's apk 3.0.5 installs its mkpkg output).
# Anywhere else (macOS, a CI runner) it runs itself in that image with docker.
# Metadata keys, the /lib/apk/packages files and the maintainer scripts follow OpenWrt's
# include/package-pack.mk and feeds/luci/luci.mk.
#
# Env: OUT=<dir>            output directory (default: out/ next to build/)
#      STRICT=1             fail when a file every release must contain is missing (release workflow)
#      SOURCE_DATE_EPOCH    mtime of every packaged file (default: now)
set -eu

TREE="$(cd "$(dirname "$0")/.." && pwd)"
BUILDER_IMAGE=alpine:3.23
VERSION="${1:-$(cat "$TREE/build/VERSION")}"
OUT="${OUT:-$TREE/out}"
STRICT="${STRICT:-0}"
PACKAGES="shadow-vpn luci-app-shadow-vpn luci-i18n-shadow-vpn-ru"

die() { echo "mk_apk: $*" >&2; exit 1; }
warn() { echo "mk_apk: warning: $*" >&2; }

echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "version '$VERSION' is not X.Y.Z"

if ! { [ "$(id -u)" = 0 ] && apk --version 2>/dev/null | grep -q '^apk-tools 3\.'; }; then
	command -v docker >/dev/null 2>&1 || die "needs apk-tools 3 as root (alpine:3.23) or docker"
	mkdir -p "$OUT"
	OUT="$(cd "$OUT" && pwd)"
	# The tree goes in as a tar stream, not a bind mount: OrbStack bind mounts can show a stale,
	# cut-off copy of a file that was just rewritten, and that copy would be packaged.
	COPYFILE_DISABLE=1 tar -C "$TREE" --exclude ./.git --exclude ./out --exclude ./tests --exclude ./.cache --exclude .DS_Store -cf - . |
		docker run --rm -i \
			-e OUT=/out -e STRICT="$STRICT" -e SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}" \
			-e HOST_IDS="$(id -u):$(id -g)" \
			-v "$OUT:/out" \
			"$BUILDER_IMAGE" sh -c 'mkdir -p /src && tar -xf - -C /src && exec sh /src/build/mk_apk.sh "$1"' _ "$VERSION"
	rc=$?
	[ "$rc" = 0 ] || exit "$rc"
	# the packages were written through a bind mount too: check them on this side
	if command -v sha256sum >/dev/null 2>&1; then
		(cd "$OUT" && sha256sum -c SHA256SUMS >/dev/null) || die "the packages in $OUT do not match SHA256SUMS"
	elif command -v shasum >/dev/null 2>&1; then
		(cd "$OUT" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "the packages in $OUT do not match SHA256SUMS"
	fi
	exit 0
fi

command -v python3 >/dev/null 2>&1 || apk add -q --no-cache python3 >/dev/null || die "cannot install python3"

EPOCH="${SOURCE_DATE_EPOCH:-}"
[ -n "$EPOCH" ] || EPOCH="$(date +%s)"
export SOURCE_DATE_EPOCH="$EPOCH"

control() { sed -n "s/^$1: *//p" "$TREE/shadow-vpn/control" | head -n 1; }
PKGVER="$VERSION-r1"
LICENSE="$(control License)"
MAINTAINER="$(control Maintainer)"
URL="$(control URL)"
[ "$(control Package)" = shadow-vpn ] || die "shadow-vpn/control: Package is not shadow-vpn"
[ -n "$(control Depends)" ] || die "shadow-vpn/control: no Depends"

B="$(mktemp -d)"
trap 'rm -rf "$B"' EXIT
mkdir -p "$OUT"
for p in $PACKAGES; do rm -f "$OUT/$p.apk"; done
rm -f "$OUT/SHA256SUMS"

# Files every release must contain; a development build packages whatever exists.
REQUIRED="
shadow-vpn/files/etc/init.d/shadow-vpn
shadow-vpn/files/etc/uci-defaults/80-shadow-vpn
shadow-vpn/files/usr/libexec/shadow-vpn/apply
shadow-vpn/files/usr/libexec/shadow-vpn/lists
luci-app-shadow-vpn/root/usr/share/luci/menu.d/luci-app-shadow-vpn.json
luci-app-shadow-vpn/root/usr/share/rpcd/acl.d/luci-app-shadow-vpn.json
luci-app-shadow-vpn/root/usr/share/rpcd/ucode/luci.shadow-vpn
luci-app-shadow-vpn/po/ru/shadow-vpn.po
"
for f in $REQUIRED; do
	[ -e "$TREE/$f" ] && continue
	[ "$STRICT" = 1 ] && die "missing $f"
	warn "missing $f (development build)"
done

# Package-specific maintainer script parts, appended to OpenWrt's generated headers like a
# Makefile's Package/<name>/postinst, /prerm and /postrm. Nothing runs when building an image
# (IPKG_INSTROOT set). The cron line is installed once here, not on every start (flash wear).

cat > "$B/shadow-vpn.postinst-pkg" <<'EOF'
[ -n "${IPKG_INSTROOT}" ] || {
	# the fw4 include and the chain-pre accept rule take effect only after a reload
	fw4 -q reload 2>/dev/null
	cron_cmd="/usr/libexec/shadow-vpn/lists refresh due"
	if ! crontab -c /etc/crontabs -l 2>/dev/null | grep -qF "$cron_cmd"; then
		{ crontab -c /etc/crontabs -l 2>/dev/null; echo "23 * * * * $cron_cmd >/dev/null 2>&1"; } \
			| crontab -c /etc/crontabs -
		# a stock image has an empty /etc/crontabs, so cron is not running yet
		/etc/init.d/cron enable
		/etc/init.d/cron restart
	fi
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
EOF

cat > "$B/shadow-vpn.prerm-pkg" <<'EOF'
[ -n "${IPKG_INSTROOT}" ] || {
	# package removal is a real Off: enabled=0, then tear down. Without enabled=0 a later install (its
	# post-install runs "start") would arm Shadow again unasked.
	# apk runs no pre-deinstall on an upgrade, so an upgrade keeps Shadow on.
	if [ "$(uci -q get shadow-vpn.main)" = shadow ]; then
		uci -q set shadow-vpn.main.enabled=0
		uci -q commit shadow-vpn
	fi
	# --from-init: default_prerm's "stop" above already removed the procd service; a teardown that
	# declared the instances again would register the service and its triggers once more, and procd
	# would keep calling the removed files on every dhcp commit and WAN ifup until a reboot
	[ -x /usr/libexec/shadow-vpn/apply ] && /usr/libexec/shadow-vpn/apply teardown --from-init
	cron_cmd="/usr/libexec/shadow-vpn/lists refresh due"
	if crontab -c /etc/crontabs -l 2>/dev/null | grep -qF "$cron_cmd"; then
		crontab -c /etc/crontabs -l 2>/dev/null | grep -vF "$cron_cmd" | crontab -c /etc/crontabs -
		[ -s /etc/crontabs/root ] || crontab -c /etc/crontabs -r 2>/dev/null
	fi
	for s in $(uci -q show firewall | sed -n "s|^firewall\.\([^.]*\)\.path='/usr/libexec/shadow-vpn/fw4-hook'$|\1|p"); do
		uci -q delete "firewall.$s"
	done
	uci -q commit firewall
}
exit 0
EOF

cat > "$B/shadow-vpn.postrm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || fw4 -q reload 2>/dev/null
exit 0
EOF

cat > "$B/luci-app-shadow-vpn.postinst-pkg" <<'EOF'
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
	exit 0
}
EOF

cat > "$B/luci-app-shadow-vpn.postrm" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
EOF

# copy_tree <source dir> <destination>: a source that does not exist yet is skipped
copy_tree() {
	[ -d "$1" ] || return 0
	mkdir -p "$2"
	cp -a "$1/." "$2/"
}

# check_scripts <root>: shell syntax, and no comment on a shebang line (Linux would pass it to sh)
check_scripts() {
	local f first
	find "$1" -type f | while read -r f; do
		first="$(head -n 1 "$f")"
		case "$first" in
		'#!'*'#'*) die "${f#"$1"}: comment on the shebang line" ;;
		'#!/bin/sh'*) sh -n "$f" || die "${f#"$1"}: shell syntax error" ;;
		esac
	done
}

# normalize <root>: owned by root, 0755 dirs, 0644 files, 0755 for executables, fixed mtimes
normalize() {
	local f
	find "$1" \( -name .DS_Store -o -name '._*' -o -name '.git*' \) -exec rm -rf {} +
	find "$1" -type d -exec chmod 0755 {} +
	find "$1" -type f -exec chmod 0644 {} +
	find "$1" -type f | while read -r f; do
		case "${f#"$1"}" in
		/etc/init.d/* | /etc/uci-defaults/* | /usr/libexec/* | /usr/bin/* | /usr/sbin/* | /bin/* | /sbin/*)
			chmod 0755 "$f" ;;
		*)
			if [ "$(head -c 2 "$f")" = '#!' ]; then chmod 0755 "$f"; fi ;;
		esac
	done
	chown -R 0:0 "$1"
	find "$1" -exec touch -d "@$EPOCH" {} +
}

# write_meta <pkg> <root> [conffile...]: /lib/apk/packages/<pkg>.list (+ .conffiles, .conffiles_static)
write_meta() {
	local pkg="$1" root="$2" f
	shift 2
	(cd "$root" && find . \( -type f -o -type l \) | sed 's|^\.||' | LC_ALL=C sort) > "$B/$pkg.list"
	mkdir -p "$root/lib/apk/packages"
	mv "$B/$pkg.list" "$root/lib/apk/packages/$pkg.list"
	[ $# -gt 0 ] || return 0
	for f in "$@"; do
		[ -f "$root$f" ] || die "$pkg: conffile $f is not packaged"
		echo "$f"
	done > "$root/lib/apk/packages/$pkg.conffiles"
	for f in "$@"; do
		echo "$f $(sha256sum "$root$f" | cut -d ' ' -f 1)"
	done > "$root/lib/apk/packages/$pkg.conffiles_static"
}

# write_scripts <pkg> <dir>: post-install, post-upgrade, pre-deinstall (+ post-deinstall) as
# package-pack.mk generates them
write_scripts() {
	local pkg="$1" dir="$2" s
	mkdir -p "$dir"
	{
		echo '#!/bin/sh'
		echo '[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0'
		echo '[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0'
		echo '. ${IPKG_INSTROOT}/lib/functions.sh'
		echo 'export root="${IPKG_INSTROOT}"'
		echo "export pkgname=\"$pkg\""
		echo 'add_group_and_user'
		echo 'default_postinst'
		if [ -f "$B/$pkg.postinst-pkg" ]; then cat "$B/$pkg.postinst-pkg"; fi
	} > "$dir/post-install"
	{
		echo '#!/bin/sh'
		echo 'export PKG_UPGRADE=1'
		sed '1{/^#!/d;}' "$dir/post-install"
	} > "$dir/post-upgrade"
	{
		echo '#!/bin/sh'
		echo '[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0'
		echo '. ${IPKG_INSTROOT}/lib/functions.sh'
		echo 'export root="${IPKG_INSTROOT}"'
		echo "export pkgname=\"$pkg\""
		echo 'default_prerm'
		if [ -f "$B/$pkg.prerm-pkg" ]; then cat "$B/$pkg.prerm-pkg"; fi
	} > "$dir/pre-deinstall"
	if [ -f "$B/$pkg.postrm" ]; then cp "$B/$pkg.postrm" "$dir/post-deinstall"; fi
	for s in "$dir"/*; do sh -n "$s" || die "$pkg: generated ${s##*/} has a syntax error"; done
	chmod 0755 "$dir"/*
}

# mkpkg <pkg> <origin> <depends> <description>
mkpkg() {
	local pkg="$1" dir="$B/$1"
	write_scripts "$pkg" "$dir/scripts"
	set -- --info "name:$pkg" --info "version:$PKGVER" --info "description:$4" --info "arch:noarch" \
		--info "license:$LICENSE" --info "origin:$2" --info "url:$URL" --info "maintainer:$MAINTAINER" \
		--script "post-install:$dir/scripts/post-install" --script "post-upgrade:$dir/scripts/post-upgrade" \
		--script "pre-deinstall:$dir/scripts/pre-deinstall" \
		--info "depends:$3"
	if [ -f "$dir/scripts/post-deinstall" ]; then set -- "$@" --script "post-deinstall:$dir/scripts/post-deinstall"; fi
	apk mkpkg "$@" --no-xattrs --files "$dir/root" --output "$OUT/$pkg.apk"
	apk adbdump "$OUT/$pkg.apk" >/dev/null || die "$pkg: apk cannot read the package it just built"
}

# shadow-vpn
R="$B/shadow-vpn/root"
mkdir -p "$R"
copy_tree "$TREE/shadow-vpn/files" "$R"
[ ! -e "$R/etc/config/shadow-vpn" ] || die "shadow-vpn must not ship /etc/config/shadow-vpn (uci-defaults creates it)"
check_scripts "$R"
normalize "$R"
# shellcheck disable=SC2046 # the Conffiles field is a space-separated list of paths
write_meta shadow-vpn "$R" $(control Conffiles)
mkpkg shadow-vpn shadow-vpn "$(control Depends)" "$(control Description)"

# luci-app-shadow-vpn (luci.mk layout: htdocs/ -> /www, root/ -> /)
R="$B/luci-app-shadow-vpn/root"
mkdir -p "$R"
copy_tree "$TREE/luci-app-shadow-vpn/htdocs" "$R/www"
copy_tree "$TREE/luci-app-shadow-vpn/root" "$R"
check_scripts "$R"
normalize "$R"
write_meta luci-app-shadow-vpn "$R"
mkpkg luci-app-shadow-vpn luci-app-shadow-vpn "shadow-vpn luci-base rpcd-mod-ucode" "LuCI support for Shadow"

# luci-i18n-shadow-vpn-ru (luci.mk LuciTranslation)
R="$B/luci-i18n-shadow-vpn-ru/root"
mkdir -p "$R/etc/uci-defaults" "$R/usr/lib/lua/luci/i18n"
printf '%s\n' "uci set luci.languages.ru='Русский (Russian)'; uci commit luci" \
	> "$R/etc/uci-defaults/luci-i18n-shadow-vpn-ru"
PO="$TREE/luci-app-shadow-vpn/po/ru/shadow-vpn.po"
if [ -f "$PO" ]; then
	python3 -I "$TREE/build/po2lmo.py" "$PO" "$R/usr/lib/lua/luci/i18n/shadow-vpn.ru.lmo"
	if [ ! -s "$R/usr/lib/lua/luci/i18n/shadow-vpn.ru.lmo" ]; then
		[ "$STRICT" = 1 ] && die "$PO has no translations"
		warn "$PO has no translations"
	fi
fi
normalize "$R"
write_meta luci-i18n-shadow-vpn-ru "$R"
mkpkg luci-i18n-shadow-vpn-ru luci-app-shadow-vpn "luci-app-shadow-vpn" \
	"Translation for luci-app-shadow-vpn - Русский (Russian)"

(cd "$OUT" && for p in $PACKAGES; do sha256sum "$p.apk"; done > SHA256SUMS)
[ -z "${HOST_IDS:-}" ] || chown "$HOST_IDS" "$OUT" "$OUT/SHA256SUMS" "$OUT"/*.apk
echo "mk_apk: $PKGVER -> $OUT"
cat "$OUT/SHA256SUMS"
