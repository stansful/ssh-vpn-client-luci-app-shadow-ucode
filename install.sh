#!/bin/sh
# Shadow for OpenWrt 25.12+: install or upgrade, or remove with --uninstall (busybox ash).
#
#   sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh)
#   sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh) --uninstall
#
# Packages and SHA256SUMS come only from the latest GitHub release of
# https://github.com/stansful/ssh-vpn-client-luci-app-shadow-ucode
# SHADOW_BASE_URL=<url> takes every file from <url>/<file> instead (tests).
#
# Routers run this file from the default branch with the packages of the latest release: every version of it
# on the default branch must install the current latest release, and the asset names, the SHA256SUMS format
# and SHADOW_BASE_URL stay compatible both ways (DESIGN.md 11; tests/unit/packaging/install_test.sh checks
# this file against the published release).

REPO=stansful/ssh-vpn-client-luci-app-shadow-ucode
RELEASE_URL="https://github.com/$REPO/releases/latest/download"
RELEASE_API="https://api.github.com/repos/$REPO/releases/latest"
ASSET_API_PREFIX="https://api.github.com/repos/$REPO/releases/assets/"

# HTTPS needs a sane clock. A clock before this script's date is wrong for sure: 2026-10-25 UTC.
CLOCK_FLOOR=1792886400

NEED_FREE_KB=46080          # xray-core, OpenSSH, OpenSSL and dnsmasq-full on a fresh install
NEED_FREE_UPGRADE_KB=5120   # the dependencies are already there
NEED_MEM_KB=49152           # xray needs about 30 MB once it runs
NEED_MEM_UPGRADE_KB=16384
WGET_TIMEOUT=15             # uclient-fetch connect/read timeout
WGET_DEADLINE=60            # hard limit for one download attempt
WGET_TRIES=3
DOWNLOAD_DEADLINE=300       # hard limit for all downloads together
RELEASE_SETTLE=15           # a new release became the latest between two downloads: wait, then fetch all again
NTP_DEADLINE=30

TUNNEL_WAIT=15              # seconds to wait for xray's first tunnel probe
METRICS_URL=http://127.0.0.1:12348/debug/vars

DEPS="xray-core openssh-client dnsmasq-full"
PACKAGES="shadow-vpn luci-app-shadow-vpn luci-i18n-shadow-vpn-ru"

PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"
WORK=
BASE_URL="${SHADOW_BASE_URL:-}"

info() { printf '\n==> %s\n    %s\n' "$1" "$2"; }
note() { printf '    %s\n    %s\n' "$1" "$2"; }
warn() { printf 'ВНИМАНИЕ: %s\nWARNING: %s\n' "$1" "$2" >&2; }
die() {
	printf '\nОШИБКА: %s\nERROR: %s\n' "$1" "$2" >&2
	exit 1
}

usage() {
	printf '%s\n' \
		'Использование: install.sh [--uninstall]' \
		'  без параметров   установить или обновить Shadow' \
		'  --uninstall      выключить Shadow и удалить пакеты' \
		'Usage: install.sh [--uninstall]' \
		'  no option        install or upgrade Shadow' \
		'  --uninstall      turn Shadow off and remove the packages'
}

cleanup() {
	[ -n "$WORK" ] && rm -rf "$WORK"
}

installed() {
	apk info -e "$@" >/dev/null 2>&1
}

installed_version() {
	apk list -I shadow-vpn 2>/dev/null | sed -n 's/^shadow-vpn-\([^ ]*\) .*/\1/p'
}

# run_with_deadline <seconds> <command...>: the command is killed when it runs longer
run_with_deadline() {
	local secs="$1" pid watchdog rc
	shift
	"$@" &
	pid=$!
	(
		trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
		sleep "$secs" &
		sleeper=$!
		wait "$sleeper"
		kill "$pid" 2>/dev/null
	) &
	watchdog=$!
	wait "$pid"
	rc=$?
	kill "$watchdog" 2>/dev/null
	wait "$watchdog" 2>/dev/null
	return "$rc"
}

check_root() {
	[ "$(id -u)" = 0 ] || die "Запустите установщик от root." "Run the installer as root."
}

check_release() {
	local rel major rest minor
	[ -f /etc/openwrt_release ] ||
		die "Это не OpenWrt: нет /etc/openwrt_release." "This is not OpenWrt: /etc/openwrt_release is missing."
	rel="$(sed -n "s/^DISTRIB_RELEASE=//p" /etc/openwrt_release | tr -d "\"'")"
	case "$rel" in
	SNAPSHOT | snapshot) ;;
	[0-9]*.[0-9]*)
		major="${rel%%.*}"
		rest="${rel#*.}"
		minor="${rest%%[!0-9]*}"
		case "$major" in *[!0-9]*)
			die "Не удалось определить версию OpenWrt ('$rel')." "Cannot tell the OpenWrt version ('$rel')." ;;
		esac
		if [ "$major" -lt 25 ] || { [ "$major" -eq 25 ] && [ "${minor:-0}" -lt 12 ]; }; then
			die "Shadow работает на OpenWrt 25.12 и новее, а на роутере OpenWrt $rel. Обновите прошивку: в 24.10 и старше слишком старый xray-core." \
				"Shadow needs OpenWrt 25.12 or newer; this router runs OpenWrt $rel. Upgrade the firmware: 24.10 and older ship a too old xray-core."
		fi
		;;
	*)
		die "Не удалось определить версию OpenWrt ('$rel')." "Cannot tell the OpenWrt version ('$rel')."
		;;
	esac
	command -v apk >/dev/null 2>&1 ||
		die "Нет менеджера пакетов apk, а OpenWrt 25.12+ использует его." "The apk package manager is missing; OpenWrt 25.12+ uses it."
	printf '    OpenWrt %s\n' "$rel"
}

check_resources() {
	local dir=/overlay free need mem need_mem
	[ -d /overlay ] || dir=/
	need="$NEED_FREE_KB"
	need_mem="$NEED_MEM_KB"
	if installed $DEPS; then
		need="$NEED_FREE_UPGRADE_KB"
		need_mem="$NEED_MEM_UPGRADE_KB"
	fi
	free="$(df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
	case "$free" in '' | *[!0-9]*) free=0 ;; esac
	[ "$free" -ge "$need" ] ||
		die "Мало места на $dir: свободно $((free / 1024)) МБ, нужно $((need / 1024)) МБ." \
			"Not enough space on $dir: $((free / 1024)) MB free, $((need / 1024)) MB needed."
	mem="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
	case "$mem" in '' | *[!0-9]*) mem=0 ;; esac
	[ "$mem" -ge "$need_mem" ] ||
		die "Мало свободной памяти: доступно $((mem / 1024)) МБ, нужно $((need_mem / 1024)) МБ." \
			"Not enough free memory: $((mem / 1024)) MB available, $((need_mem / 1024)) MB needed."
}

# The clock may only move forward, and only to a time past CLOCK_FLOOR: an answer from an
# unauthenticated NTP server that would move it back is thrown away.
check_clock() {
	local before after servers args s
	before="$(date +%s)"
	[ "$before" -ge "$CLOCK_FLOOR" ] && return 0
	info "Часы роутера отстают ($(date)), синхронизирую по NTP" \
		"The router clock is behind ($(date)); syncing it over NTP"
	servers="$(uci -q get system.ntp.server)"
	[ -n "$servers" ] || servers="0.openwrt.pool.ntp.org 1.openwrt.pool.ntp.org 2.openwrt.pool.ntp.org"
	args=
	for s in $servers; do args="$args -p $s"; done
	# shellcheck disable=SC2086 # one -p per server
	run_with_deadline "$NTP_DEADLINE" ntpd -n -q $args >/dev/null 2>&1
	after="$(date +%s)"
	[ "$after" -ge "$before" ] || date -s "@$before" >/dev/null 2>&1
	[ "$(date +%s)" -ge "$CLOCK_FLOOR" ] ||
		die "Не удалось выставить время, а без него HTTPS не работает. Проверьте интернет и NTP (Система → Система → Синхронизация времени) и запустите снова." \
			"Could not set the clock, and HTTPS does not work without it. Check the Internet connection and NTP (System → System → Time synchronization), then run again."
}

# tunnel_alive: true / false from xray's own probe (observatory), empty while it has no verdict yet;
# false when xray does not answer at all. xray leaves "alive" out when it is false (lab), and has no
# "proxy" entry before its first probe.
tunnel_alive() {
	local vars
	vars="$(wget -q -T 3 -O - "$METRICS_URL" 2>/dev/null </dev/null)" || {
		echo false
		return 0
	}
	printf '%s' "$vars" | jsonfilter -e '@.observatory.proxy' >/dev/null 2>&1 || return 0
	if [ "$(printf '%s' "$vars" | jsonfilter -e '@.observatory.proxy.alive' 2>/dev/null)" = true ]; then
		echo true
	else
		echo false
	fi
}

# Shadow is on with the kill switch, routes the router's own traffic, and its tunnel is down: then the
# router's own downloads (package feeds, GitHub) that Shadow routes are blocked (DESIGN.md 6.7).
shadow_blocks_router() {
	local alive i=0
	[ "$(uci -q get shadow-vpn.main.enabled)" = 1 ] && [ -e /var/run/shadow-vpn/active ] || return 1
	[ "$(uci -q get shadow-vpn.main.kill_switch)" != 0 ] && [ "$(uci -q get shadow-vpn.main.router_traffic)" != 0 ] || return 1
	while :; do
		alive="$(tunnel_alive)"
		[ -n "$alive" ] && break
		[ "$i" -lt "${1:-0}" ] || return 1
		i=$((i + 1))
		sleep 1
	done
	[ "$alive" != true ]
}

TURN_OFF_RU="Выключите Shadow (LuCI → Службы → Shadow → Выключить, или: uci set shadow-vpn.main.enabled=0; uci commit shadow-vpn; /etc/init.d/shadow-vpn reload) и запустите установщик снова; после установки включите его."
TURN_OFF_EN="Turn Shadow off (LuCI → Services → Shadow → Off, or: uci set shadow-vpn.main.enabled=0; uci commit shadow-vpn; /etc/init.d/shadow-vpn reload), run the installer again, then turn it back on."

# Before anything is downloaded. Full mode routes every download through the dead tunnel: stop here. In
# split mode only listed hosts go through it, so try, and explain if a download then fails.
check_tunnel() {
	shadow_blocks_router "$TUNNEL_WAIT" || return 0
	if [ "$(uci -q get shadow-vpn.main.mode)" != selected-rules ]; then
		die "Shadow включён с блокировкой при обрыве туннеля (kill switch), а туннель сейчас не работает, поэтому роутер ничего не может скачать. $TURN_OFF_RU" \
			"Shadow is on with the kill switch and its tunnel is down, so the router cannot download anything. $TURN_OFF_EN"
	fi
}

# net_die <ru> <en>: a download failed; say why when Shadow's kill switch is what blocks the router
net_die() {
	if shadow_blocks_router; then
		die "$1 Shadow включён с блокировкой при обрыве туннеля (kill switch), а туннель не работает: он и блокирует загрузку. $TURN_OFF_RU" \
			"$2 Shadow is on with the kill switch and its tunnel is down: that is what blocks the download. $TURN_OFF_EN"
	fi
	die "$1" "$2"
}

# Indexes and packages go to $WORK/cache, which apk add reuses and the cleanup removes.
apk_update() {
	info "Обновляю списки пакетов" "Updating the package lists"
	mkdir -p "$WORK/cache"
	apk update --cache-dir "$WORK/cache" </dev/null >"$WORK/apk-update.log" 2>&1 || {
		cat "$WORK/apk-update.log" >&2
		warn "apk update завершился с ошибками, пробую продолжить." "apk update reported errors, trying to continue."
	}
}

# fetch <url> <file> [header]: one attempt, certificate checks always on
fetch() {
	rm -f "$2"
	if [ -n "${3:-}" ]; then
		run_with_deadline "$WGET_DEADLINE" wget -q -T "$WGET_TIMEOUT" --header="$3" -O "$2" "$1" </dev/null
	else
		run_with_deadline "$WGET_DEADLINE" wget -q -T "$WGET_TIMEOUT" -O "$2" "$1" </dev/null
	fi
	[ $? -eq 0 ] && [ -s "$2" ]
}

# asset_api_url <name>: the API URL of an asset of the latest release, the second path. github.com's
# redirects for the plain release URL carry a CSP header near uclient-fetch's 4 KB line limit; the API
# redirect does not.
asset_api_url() {
	local url
	[ -s "$WORK/release.json" ] ||
		fetch "$RELEASE_API" "$WORK/release.json" "Accept: application/vnd.github+json" || return 1
	url="$(jsonfilter -i "$WORK/release.json" -e "@.assets[@.name='$1'].url" 2>/dev/null)"
	case "$url" in
	"$ASSET_API_PREFIX"[0-9]*) echo "$url" ;;
	*) return 1 ;;
	esac
}

# release_missing: the source answers that there is no release (HTTP 404 from the GitHub API for the latest
# release: none published yet; or for SHA256SUMS under SHADOW_BASE_URL), as opposed to a network error
release_missing() {
	local url="$RELEASE_API"
	[ -n "$BASE_URL" ] && url="$BASE_URL/SHA256SUMS"
	run_with_deadline "$WGET_DEADLINE" wget -T "$WGET_TIMEOUT" -O /dev/null "$url" </dev/null 2>&1 >/dev/null |
		grep -q '^HTTP error 404'
}

# download <name> [soft]: soft returns 1 instead of stopping the script
download() {
	local name="$1" try=1 url where
	while [ "$try" -le "$WGET_TRIES" ]; do
		[ $(($(date +%s) - DOWNLOAD_START)) -lt "$DOWNLOAD_DEADLINE" ] || break
		if [ -n "$BASE_URL" ]; then
			fetch "$BASE_URL/$name" "$WORK/$name" && return 0
		else
			fetch "$RELEASE_URL/$name" "$WORK/$name" && return 0
			url="$(asset_api_url "$name")" &&
				fetch "$url" "$WORK/$name" "Accept: application/octet-stream" && return 0
		fi
		try=$((try + 1))
		[ "$try" -le "$WGET_TRIES" ] && sleep 3
	done
	[ -n "${2:-}" ] && return 1
	if release_missing; then
		where="${BASE_URL:-https://github.com/$REPO/releases}"
		die "Shadow ещё не опубликован: на $where нет ни одного релиза. Запустите установщик снова, когда релиз появится." \
			"No Shadow release is published yet: $where has none. Run the installer again once there is one."
	fi
	net_die "Не удалось скачать $name. Проверьте доступ к github.com и запустите снова." \
		"Could not download $name. Check access to github.com and run again."
}

# verify <name>: 0 when the file matches its SHA256SUMS line; VERIFY_RU/VERIFY_EN say why not
verify() {
	local want got
	want="$(awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "$WORK/SHA256SUMS")"
	if [ "${#want}" -ne 64 ]; then
		VERIFY_RU="В SHA256SUMS нет записи для $1."
		VERIFY_EN="SHA256SUMS has no entry for $1."
		return 1
	fi
	got="$(sha256sum "$WORK/$1" | cut -d ' ' -f 1)"
	if [ "$got" != "$want" ]; then
		VERIFY_RU="Контрольная сумма $1 не совпадает с SHA256SUMS: файл повреждён или подменён."
		VERIFY_EN="The checksum of $1 does not match SHA256SUMS: the file is damaged or was replaced."
		return 1
	fi
}

# SHA256SUMS, then every package against it. "Latest" can move to a new release between two downloads, so
# an install at that moment can meet old sums with a new package: then everything is fetched once more after
# a pause (the GitHub API listing too) before giving up.
fetch_release() {
	local round=1 p failed
	while :; do
		rm -f "$WORK/release.json"
		DOWNLOAD_START="$(date +%s)"
		download SHA256SUMS
		grep -Evq '^[0-9a-f]{64}  [A-Za-z0-9._+-]+$' "$WORK/SHA256SUMS" &&
			die "SHA256SUMS повреждён." "SHA256SUMS is malformed."
		failed=
		for p in $files; do
			if ! download "$p" soft; then
				failed=download
				VERIFY_RU="Не удалось скачать $p. Проверьте доступ к github.com и запустите снова."
				VERIFY_EN="Could not download $p. Check access to github.com and run again."
				break
			fi
			verify "$p" || { failed=checksum; break; }
		done
		[ -z "$failed" ] && return 0
		[ "$round" -ge 2 ] && break
		round=2
		note "Файлы релиза не сходятся — возможно, как раз вышла новая версия. Скачиваю ещё раз через $RELEASE_SETTLE с." \
			"The release files do not match; a new version may have just been published. Downloading again in $RELEASE_SETTLE s."
		sleep "$RELEASE_SETTLE"
	done
	[ "$failed" = download ] && net_die "$VERIFY_RU" "$VERIFY_EN"
	die "$VERIFY_RU" "$VERIFY_EN"
}

# Russian pages when LuCI is in Russian, when they are installed already, or when the user agrees
want_russian() {
	local lang answer
	installed luci-i18n-shadow-vpn-ru && return 0
	lang="$(uci -q get luci.main.lang)"
	case "$lang" in ru*) return 0 ;; esac
	[ "$lang" = auto ] && installed luci-i18n-base-ru && return 0
	[ -t 0 ] || return 0
	printf '\nУстановить русский перевод страниц Shadow? / Install the Russian translation of the Shadow pages? [Y/n] '
	read -r answer || answer=
	case "$answer" in
	n* | N* | н* | Н*) return 1 ;;
	esac
	return 0
}

do_install() {
	local was_installed=0 was_enabled old_version version files p ru en
	info "Проверяю роутер" "Checking the router"
	check_release
	check_resources
	check_clock
	check_tunnel
	installed shadow-vpn && was_installed=1
	old_version="$(installed_version)"
	was_enabled="$(uci -q get shadow-vpn.main.enabled)"

	WORK="$(mktemp -d /tmp/shadow-vpn-install.XXXXXX)" || die "Не удалось создать временный каталог." "Cannot create a temporary directory."
	apk_update

	files="shadow-vpn.apk luci-app-shadow-vpn.apk"
	want_russian && files="$files luci-i18n-shadow-vpn-ru.apk"

	info "Скачиваю Shadow" "Downloading Shadow"
	if [ -n "$BASE_URL" ]; then
		note "Источник: $BASE_URL (тестовый)" "Source: $BASE_URL (testing)"
	fi
	fetch_release

	info "Устанавливаю пакеты (dnsmasq заменяется на dnsmasq-full)" "Installing the packages (dnsmasq-full replaces dnsmasq)"
	set --
	for p in $files; do set -- "$@" "$WORK/$p"; done
	# apk purges dnsmasq before it installs dnsmasq-full, and the router resolves through dnsmasq:
	# download every package first, so the transaction never needs DNS while dnsmasq is gone
	apk add --cache-dir "$WORK/cache" --cache-predownload --allow-untrusted "$@" </dev/null ||
		net_die "apk add завершился с ошибкой, подробности выше." "apk add failed, see the messages above."
	rm -rf "$WORK/cache"

	# an upgrade keeps Shadow on when it was on
	if [ "$was_enabled" = 1 ] && [ "$(uci -q get shadow-vpn.main.enabled)" != 1 ]; then
		uci -q set shadow-vpn.main.enabled=1 && uci -q commit shadow-vpn
		/etc/init.d/shadow-vpn start
	fi
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null

	version="$(installed_version)"
	if [ "$was_installed" = 0 ]; then
		ru="Shadow $version установлен"
		en="Shadow $version is installed"
	elif [ "$old_version" = "$version" ]; then
		ru="Shadow $version уже установлен"
		en="Shadow $version is already installed"
	elif [ "$(printf '%s\n%s\n' "$old_version" "$version" | sort -V | tail -n 1)" = "$old_version" ]; then
		# the latest release is an older version (a rollback): say so instead of "upgraded"
		ru="Shadow возвращён к версии $version (было $old_version)"
		en="Shadow is downgraded to $version (was $old_version)"
	else
		ru="Shadow обновлён до $version"
		en="Shadow is upgraded to $version"
	fi
	if [ "$(uci -q get shadow-vpn.main.enabled)" = 1 ]; then
		info "Готово: $ru и включён." "Done: $en and is on."
	elif [ "$was_installed" = 0 ]; then
		info "Готово: $ru и выключен. Откройте LuCI → Службы → Shadow, добавьте сервер и включите его." \
			"Done: $en and is off. Open LuCI → Services → Shadow, add a server and turn it on."
	else
		info "Готово: $ru и выключен." "Done: $en and is off."
	fi
}

do_uninstall() {
	local pkgs="" p
	for p in $PACKAGES; do installed "$p" && pkgs="$pkgs $p"; done
	if [ -z "$pkgs" ]; then
		info "Shadow не установлен." "Shadow is not installed."
		return 0
	fi

	info "Выключаю Shadow" "Turning Shadow off"
	if [ -n "$(uci -q get shadow-vpn.main)" ]; then
		uci -q set shadow-vpn.main.enabled=0 && uci -q commit shadow-vpn
	fi
	if [ -x /usr/libexec/shadow-vpn/apply ]; then
		/usr/libexec/shadow-vpn/apply teardown </dev/null ||
			warn "Shadow выключился с ошибкой, продолжаю удаление." "Turning Shadow off reported an error, removing it anyway."
	fi

	info "Удаляю пакеты Shadow (dnsmasq-full остаётся)" "Removing the Shadow packages (dnsmasq-full stays)"
	# dnsmasq-full replaced dnsmasq and serves DNS and DHCP: keep it in the world
	# so it is not removed together with Shadow as an orphan dependency
	if installed dnsmasq-full; then
		apk add --no-network dnsmasq-full </dev/null >/dev/null 2>&1 || apk add dnsmasq-full </dev/null >/dev/null 2>&1 ||
			die "Не удалось закрепить dnsmasq-full, пакеты не удалены." "Could not keep dnsmasq-full; nothing was removed."
	fi
	# shellcheck disable=SC2086 # list of package names
	apk del $pkgs </dev/null ||
		die "apk del завершился с ошибкой, подробности выше." "apk del failed, see the messages above."
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null

	info "Готово: Shadow удалён. Настройки остались в /etc/config/shadow-vpn и /etc/shadow-vpn, удалите их, если они не нужны." \
		"Done: Shadow is removed. Its settings stay in /etc/config/shadow-vpn and /etc/shadow-vpn; delete them if you no longer need them."
}

main() {
	local action=install
	case "${1:-}" in
	'') ;;
	--uninstall) action=uninstall ;;
	-h | --help)
		usage
		return 0
		;;
	*)
		usage >&2
		return 2
		;;
	esac
	case "$BASE_URL" in
	'' | http://* | https://*) ;;
	*) die "SHADOW_BASE_URL должен начинаться с http:// или https://." "SHADOW_BASE_URL must start with http:// or https://." ;;
	esac
	check_root
	trap cleanup EXIT
	trap 'exit 130' INT TERM HUP
	if [ "$action" = uninstall ]; then
		do_uninstall
	else
		do_install
	fi
}

main "$@"
