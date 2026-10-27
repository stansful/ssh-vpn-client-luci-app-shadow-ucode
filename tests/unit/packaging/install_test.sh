#!/bin/bash
# End-to-end test of build/mk_apk.sh and install.sh on the factory Cudy TR3000 25.12.6 rootfs
# (procd as PID 1, the router resolving through its own dnsmasq, as on a real box). Run on the host:
#
#   tests/unit/packaging/install_test.sh
#
# Builds the packages from the current tree; files other areas have not written yet are filled in
# from stubs/ (each one is listed). Serves the build from a throwaway web container and runs
# install.sh with SHADOW_BASE_URL. At the end this install.sh installs the latest release published on
# GitHub, or says that none is published yet, and so does the updater of this tree's build, which also downloads
# that release through both of its paths and is installed over it (PUBLISHED_RELEASE=skip skips that part:
# release.yml sets it only in a run that publishes a new version; every other run checks the published release).
# Needs the lab images (BUILD_ONLY=1 tests/lab/up.sh), Docker and Internet access for the official
# package feed and GitHub. Its containers and network are named
# shv-packaging-* and removed on exit (KEEP=1 keeps them and the work dir for debugging).
# Prints 'ok <name>' / 'not ok <name>: <why>'.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "$HERE/../../.." && pwd)"
ROUTER_IMG="${ROUTER_IMG:-shadow-testenv/tr3000-rootfs:25.12.6}"
WEB_IMG=shadow-testenv/tools:alpine3.22
NET=shv-packaging-net
ROUTER=shv-packaging-router
WEB=shv-packaging-web
ROUTER_IP=198.51.100.2
WEB_IP=198.51.100.10
BASE="http://$WEB_IP"
EPOCH=1792886400
CRON_CMD='/usr/libexec/shadow-vpn/lists refresh due'
UPDATER=/usr/libexec/shadow-vpn/update
UPDATE_CMD="$UPDATER due"
UPDATE_LOCK=/var/lock/shadow-vpn-update.lock
# shellcheck source=../../lab/lib/host.sh
. "$TREE/tests/lab/lib/host.sh"

pass=0
fail=0
ok() { echo "ok $1"; pass=$((pass + 1)); }
nok() { echo "not ok $1: $2"; fail=$((fail + 1)); }
# expect <name> <why> <command...>
expect() {
	local name="$1" why="$2"
	shift 2
	if "$@" >/dev/null 2>&1; then ok "$name"; else nok "$name" "$why"; fi
}
r() { docker exec "$ROUTER" sh -c "$1"; }
contains() { grep -qF -- "$2" "$1"; }

remove_containers() {
	docker rm -f "$ROUTER" "$WEB" >/dev/null 2>&1
	docker network rm "$NET" >/dev/null 2>&1
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/shv-packaging.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
if [ "${KEEP:-0}" = 1 ]; then
	trap 'echo "# kept $ROUTER, $WEB and $WORK"' EXIT
else
	trap 'remove_containers; rm -rf "$WORK"' EXIT
fi
remove_containers

for img in "$ROUTER_IMG" "$WEB_IMG"; do
	docker image inspect "$img" >/dev/null 2>&1 || { echo "missing image $img: run BUILD_ONLY=1 MODE=factory tests/lab/up.sh" >&2; exit 2; }
done

# --- build from a copy of the tree, stubs only where a file does not exist yet
mkdir -p "$WORK/tree" "$WORK/www"
for d in build shadow-vpn luci-app-shadow-vpn; do
	[ -d "$TREE/$d" ] && cp -R "$TREE/$d" "$WORK/tree/"
done
rm -rf "$WORK/tree/out"
cp "$TREE/install.sh" "$WORK/www/install.sh"
: > "$WORK/stubs-used"
(cd "$HERE/stubs" && find . -type f | sed 's|^\./||' | sort) | while read -r f; do
	[ -e "$WORK/tree/$f" ] && continue
	mkdir -p "$(dirname "$WORK/tree/$f")"
	cp "$HERE/stubs/$f" "$WORK/tree/$f"
	echo "$f" >> "$WORK/stubs-used"
	echo "# stub: $f"
done
stub_used() { grep -qx "$1" "$WORK/stubs-used"; }

build() { # build <version> <dir under www>
	OUT="$WORK/www/$2" SOURCE_DATE_EPOCH="$EPOCH" sh "$WORK/tree/build/mk_apk.sh" "$1" >"$WORK/build-$1.log" 2>&1
}
if build 0.1.0 v1; then ok "mk_apk builds 0.1.0"; else nok "mk_apk builds 0.1.0" "$(tail -n 5 "$WORK/build-0.1.0.log")"; exit 1; fi
if build 0.1.1 v2; then ok "mk_apk builds 0.1.1"; else nok "mk_apk builds 0.1.1" "$(tail -n 5 "$WORK/build-0.1.1.log")"; exit 1; fi
mkdir -p "$WORK/www/again"
OUT="$WORK/www/again" SOURCE_DATE_EPOCH="$EPOCH" sh "$WORK/tree/build/mk_apk.sh" 0.1.0 >/dev/null 2>&1
expect "mk_apk is reproducible" "two builds with one SOURCE_DATE_EPOCH differ" \
	cmp "$WORK/www/v1/SHA256SUMS" "$WORK/www/again/SHA256SUMS"
expect "SHA256SUMS lists the three packages" "unexpected SHA256SUMS" \
	test "$(awk '{ print $2 }' "$WORK/www/v1/SHA256SUMS" | tr '\n' ' ')" = "shadow-vpn.apk luci-app-shadow-vpn.apk luci-i18n-shadow-vpn-ru.apk "

# a package whose bytes do not match SHA256SUMS
mkdir -p "$WORK/www/bad"
cp "$WORK/www/v1/"* "$WORK/www/bad/"
printf 'x' >> "$WORK/www/bad/shadow-vpn.apk"

# the first translated single-line msgid of the packaged catalog, for the LuCI lookup below
po="$WORK/tree/luci-app-shadow-vpn/po/ru/shadow-vpn.po"
python3 -I - "$po" > "$WORK/tr-pair" <<'EOF'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
for m in re.finditer(r'(?m)^msgid "((?:[^"\\]|\\.)+)"\nmsgstr "((?:[^"\\]|\\.)+)"\n', text):
    before = text[:m.start()].rstrip('\n').split('\n')[-1]
    if before.startswith('msgctxt') or m.group(1) == m.group(2) or '\\' in m.group(1) + m.group(2):
        continue
    print(m.group(1)); print(m.group(2)); break
EOF
TR_ID="$(sed -n 1p "$WORK/tr-pair")"
TR_STR="$(sed -n 2p "$WORK/tr-pair")"

# --- lab: one network, a web server with the builds, the factory router
docker network create --subnet 198.51.100.0/24 --gateway 198.51.100.1 "$NET" >/dev/null || exit 2
printf 'server {\n\tlisten 80 default_server;\n\troot /srv;\n}\n' > "$WORK/nginx.conf"
# the builds go in as a tar stream, not a bind mount: OrbStack bind mounts can show a stale copy of a fresh file
docker run -d --name "$WEB" --network "$NET" --ip "$WEB_IP" "$WEB_IMG" sh -c 'exec sleep 86400' >/dev/null || exit 2
docker exec -i "$WEB" sh -c 'cat > /etc/nginx/http.d/default.conf' < "$WORK/nginx.conf" || exit 2
(cd "$WORK/www" && COPYFILE_DISABLE=1 tar -cf - .) | docker exec -i "$WEB" sh -c 'mkdir -p /srv /run/nginx && tar -xf - -C /srv' || exit 2
docker exec -d "$WEB" nginx -g 'daemon off;' || exit 2
router_sysctl_args "$WEB_IMG" || exit 2
docker create --name "$ROUTER" --hostname TR3000 \
	--cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
	--security-opt seccomp=unconfined --security-opt apparmor=unconfined \
	"${ROUTER_SYSCTLS[@]}" \
	--network "$NET" --ip "$ROUTER_IP" \
	"$ROUTER_IMG" /sbin/init >/dev/null || exit 2
docker cp "$HERE/router-network" "$ROUTER:/etc/config/network" || exit 2
docker start "$ROUTER" >/dev/null || exit 2

booted=0
for _ in $(seq 1 60); do
	r 'pidof dnsmasq >/dev/null && pidof uhttpd >/dev/null && pidof rpcd >/dev/null' 2>/dev/null && { booted=1; break; }
	sleep 1
done
[ "$booted" = 1 ] || { echo "not ok router boots: no dnsmasq/uhttpd/rpcd after 60 s"; exit 1; }
# Docker bind-mounts its own resolv.conf; a real router resolves through its dnsmasq
r 'umount /etc/resolv.conf 2>/dev/null; rm -f /etc/resolv.conf; ln -s /tmp/resolv.conf /etc/resolv.conf'
resolves=0
for _ in $(seq 1 30); do
	r 'nslookup downloads.openwrt.org 127.0.0.1' >/dev/null 2>&1 && { resolves=1; break; }
	sleep 1
done
[ "$resolves" = 1 ] || { echo "not ok router resolves through its dnsmasq"; exit 1; }
r "wget -q -O /tmp/install.sh $BASE/install.sh" || { echo "not ok router fetches install.sh"; exit 1; }
DHCP_SUM="$(r 'sha256sum /etc/config/dhcp')"

docker exec -i "$ROUTER" sh -c 'cat > /tmp/tr.uc' <<'EOF'
import { load_catalog, change_catalog, translate } from 'luci.core';
load_catalog('ru', '/usr/lib/lua/luci/i18n');
change_catalog('ru');
print(translate(ARGV[0]), '\n');
EOF

# run_install <log> <base> [args...]: install.sh as the one-liner from the README runs it
run_install() {
	local log="$1" base="$2"
	shift 2
	docker exec -e SHADOW_BASE_URL="$base" "$ROUTER" sh -c "sh <(wget -q -O - $BASE/install.sh) $*" >"$log" 2>&1
}
nothing_installed() { ! r 'apk info -e shadow-vpn || apk info -e luci-app-shadow-vpn || apk info -e dnsmasq-full'; }
menu_has_shadow() {
	docker exec "$WEB" sh -c "rm -f /tmp/cj; curl -s -m 10 -c /tmp/cj -o /dev/null -d 'luci_username=root&luci_password=' http://$ROUTER_IP/cgi-bin/luci/ && curl -s -m 10 -b /tmp/cj http://$ROUTER_IP/cgi-bin/luci/admin/menu" >"$WORK/menu.json" 2>/dev/null
	python3 -I -c 'import json, sys
node = json.load(open(sys.argv[1]))
for name in ("admin", "services", "shadow-vpn"):
    node = node.get("children", {}).get(name, {})
sys.exit(0 if node.get("title") == "Shadow" else 1)' "$WORK/menu.json" 2>/dev/null
}
# cron_lines [command]: how many crontab lines run it (default: the lists refresh)
cron_lines() { r "crontab -c /etc/crontabs -l 2>/dev/null | grep -cF '${1:-$CRON_CMD}'"; }
# "<lists lines> <update lines>": "1 1" while Shadow is installed, "0 0" once it is removed
cron_both() { echo "$(cron_lines) $(cron_lines "$UPDATE_CMD")"; }

# --- refusals: nothing may be touched
expect "install.sh passes busybox ash -n" "syntax error" r 'sh -n /tmp/install.sh'

docker exec -u 65534 "$ROUTER" sh /tmp/install.sh >"$WORK/nonroot.log" 2>&1
rc=$?
expect "refuses a non-root user" "rc=$rc: $(tail -n 2 "$WORK/nonroot.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'Run the installer as root' '$WORK/nonroot.log'"

r 'cp /etc/openwrt_release /tmp/openwrt_release.orig && sed -i "s/^DISTRIB_RELEASE=.*/DISTRIB_RELEASE='"'"'24.10.8'"'"'/" /etc/openwrt_release'
docker exec -e SHADOW_BASE_URL="$BASE/v1" "$ROUTER" sh /tmp/install.sh >"$WORK/old.log" 2>&1
rc=$?
r 'cp /tmp/openwrt_release.orig /etc/openwrt_release'
expect "refuses OpenWrt 24.10 in Russian and English" "rc=$rc: $(tail -n 2 "$WORK/old.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'OpenWrt 24.10.8' '$WORK/old.log' && grep -q 'Обновите прошивку' '$WORK/old.log' && grep -q 'Upgrade the firmware' '$WORK/old.log'"
expect "24.10 refusal installs nothing" "something got installed" nothing_installed

r 'mkdir -p /tmp/fakebin
printf "#!/bin/sh\ncase \"\$1\" in +%%s) echo 1600000000 ;; -s) exit 1 ;; *) exec /bin/date \"\$@\" ;; esac\n" > /tmp/fakebin/date
printf "#!/bin/sh\nexit 0\n" > /tmp/fakebin/ntpd
chmod 755 /tmp/fakebin/date /tmp/fakebin/ntpd'
docker exec -e SHADOW_BASE_URL="$BASE/v1" "$ROUTER" sh -c 'PATH=/tmp/fakebin:$PATH sh /tmp/install.sh' >"$WORK/clock.log" 2>&1
rc=$?
expect "aborts when NTP cannot fix a clock before the floor" "rc=$rc: $(tail -n 2 "$WORK/clock.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'Could not set the clock' '$WORK/clock.log'"

# nothing listens on port 81 of the web container: a network error, not "no release"
run_install "$WORK/unreachable.log" "http://$WEB_IP:81"
rc=$?
expect "gives up on an unreachable source" "rc=$rc: $(tail -n 2 "$WORK/unreachable.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'Could not download SHA256SUMS. Check access to github.com' '$WORK/unreachable.log' && ! grep -q 'published' '$WORK/unreachable.log'"

# the source answers 404: nothing is published there (before the first release on GitHub)
run_install "$WORK/missing.log" "$BASE/missing"
rc=$?
expect "says no release is published when the source answers 404, in Russian and English" "rc=$rc: $(tail -n 2 "$WORK/missing.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'No Shadow release is published yet' '$WORK/missing.log' && grep -q 'Shadow ещё не опубликован' '$WORK/missing.log' && ! grep -q 'Check access to github.com' '$WORK/missing.log'"
expect "no-release refusal installs nothing" "something got installed" nothing_installed

run_install "$WORK/bad.log" "$BASE/bad"
rc=$?
expect "refuses a package that does not match SHA256SUMS" "rc=$rc: $(tail -n 2 "$WORK/bad.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'does not match SHA256SUMS' '$WORK/bad.log'"
expect "checksum refusal installs nothing" "something got installed" nothing_installed

# --- fresh install
run_install "$WORK/install.log" "$BASE/v1"
rc=$?
if [ "$rc" = 0 ] && grep -q 'Shadow 0.1.0-r1 is installed and is off' "$WORK/install.log"; then
	ok "installs 0.1.0"
else
	nok "installs 0.1.0" "rc=$rc: $(tail -n 5 "$WORK/install.log")"
fi
expect "every package is downloaded before dnsmasq is purged" "see install.log: no predownload" \
	awk '/Downloading dnsmasq-full/ { d = NR } /Purging dnsmasq/ { p = NR } END { exit !(d && p && d < p) }' "$WORK/install.log"
expect "our packages are installed" "missing" r 'apk info -e shadow-vpn luci-app-shadow-vpn luci-i18n-shadow-vpn-ru'
expect "dependencies come from the official feed" "missing" \
	r 'apk info -e xray-core openssh-client dnsmasq-full kmod-nft-tproxy kmod-nft-socket ucode-mod-socket ucode-mod-digest rpcd-mod-ucode'
expect "dnsmasq-full replaced dnsmasq" "dnsmasq still installed" r '[ ! -e /lib/apk/packages/dnsmasq.list ] && dnsmasq --version | grep -q nftset'
expect "dnsmasq serves DNS after the swap" "no answer" r 'pidof dnsmasq && nslookup openwrt.org 127.0.0.1'
expect "/etc/config/dhcp kept" "changed" test "$(r 'sha256sum /etc/config/dhcp')" = "$DHCP_SUM"
expect "/etc/config/shadow-vpn is not a package file" "packaged" \
	r '! grep -qx /etc/config/shadow-vpn /lib/apk/packages/shadow-vpn.list && [ -s /etc/config/shadow-vpn ]'
expect "Shadow stays off after a fresh install" "enabled or armed" \
	r '[ "$(uci -q get shadow-vpn.main.enabled)" = 0 ] && ! nft list table inet shadow_vpn && ! pidof xray && ! pidof ssh-openssh'
expect "init script enabled at boot (S95)" "no /etc/rc.d/S95shadow-vpn" r '[ -e /etc/rc.d/S95shadow-vpn ]'
expect "packaged files are root-owned and not world-writable" "bad owner or mode" \
	r 'for p in shadow-vpn luci-app-shadow-vpn luci-i18n-shadow-vpn-ru; do while read -r f; do
		ls -ln "$f" | awk "{ exit !(\$3 == 0 && \$4 == 0 && substr(\$1, 9, 1) != \"w\") }" || exit 1
	done < /lib/apk/packages/$p.list; done'
expect "helpers are executable" "not executable" \
	r 'for f in $(grep "^/usr/libexec/shadow-vpn/\|^/etc/init.d/" /lib/apk/packages/shadow-vpn.list); do [ -x "$f" ] || exit 1; done'
expect "both cron lines installed once and cron running" "lines=$(cron_both)" \
	sh -c "[ '$(cron_both)' = '1 1' ] && docker exec $ROUTER pidof crond"
expect "the update line runs 'update due' hourly at :47" "$(r 'crontab -c /etc/crontabs -l' | tr '\n' '|')" \
	r "crontab -c /etc/crontabs -l | grep -qxF '47 * * * * $UPDATE_CMD >/dev/null 2>&1'"
expect "LuCI menu has Services -> Shadow" "no shadow-vpn entry in admin/menu" menu_has_shadow
expect "ru language registered" "luci.languages.ru missing" r '[ "$(uci -q get luci.languages.ru)" = "Русский (Russian)" ]'
if [ -n "$TR_ID" ]; then
	expect "LuCI reads our .lmo ('$TR_ID')" "got '$(r "ucode /tmp/tr.uc '$TR_ID'")'" \
		test "$(r "ucode /tmp/tr.uc '$TR_ID'")" = "$TR_STR"
fi

run_install "$WORK/again.log" "$BASE/v1"
rc=$?
expect "running it again is harmless (one of each cron line)" "rc=$rc, lines=$(cron_both): $(tail -n 3 "$WORK/again.log")" \
	sh -c "[ $rc = 0 ] && [ '$(cron_both)' = '1 1' ] && grep -q 'is already installed and is off' '$WORK/again.log'"

# --- Shadow on with the kill switch and its tunnel down (here: no xray answers on 127.0.0.1:12348): in full mode the
# router cannot download, so install.sh stops before it touches anything and says how to go on
r 'uci set shadow-vpn.main.enabled=1 && uci commit shadow-vpn && mkdir -p /var/run/shadow-vpn && touch /var/run/shadow-vpn/active'
run_install "$WORK/blocked.log" "$BASE/v1"
rc=$?
expect "refuses while the kill switch blocks the router, in Russian and English" "rc=$rc: $(tail -n 3 "$WORK/blocked.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'Shadow is on with the kill switch and its tunnel is down' '$WORK/blocked.log' && grep -q 'Выключите Shadow' '$WORK/blocked.log'"
expect "that refusal downloads nothing" "it went on" sh -c "! grep -q 'Downloading Shadow' '$WORK/blocked.log'"
r 'uci set shadow-vpn.main.kill_switch=0 && uci commit shadow-vpn'
run_install "$WORK/fallback.log" "$BASE/v1"
rc=$?
expect "no refusal without the kill switch" "rc=$rc: $(tail -n 3 "$WORK/fallback.log")" \
	sh -c "[ $rc = 0 ] && ! grep -q 'kill switch' '$WORK/fallback.log'"
r 'uci set shadow-vpn.main.enabled=0 && uci set shadow-vpn.main.kill_switch=1 && uci commit shadow-vpn && rm -f /var/run/shadow-vpn/active'

# --- apk del without install.sh, on the factory world: /etc/apk/world still names the image's plain dnsmasq,
# which dnsmasq-full provides. Removing our packages must not swap dnsmasq-full back to dnsmasq (that swap
# would purge the running dnsmasq first and then need DNS to download its replacement).
expect "the world after install.sh still names dnsmasq, not dnsmasq-full (the case under test)" \
	"$(r 'grep dnsmasq /etc/apk/world' | tr '\n' ' ')" r 'grep -qx dnsmasq /etc/apk/world && ! grep -qx dnsmasq-full /etc/apk/world'
r 'uci set shadow-vpn.main.enabled=1 && uci commit shadow-vpn'
r 'apk del luci-i18n-shadow-vpn-ru luci-app-shadow-vpn shadow-vpn </dev/null' >"$WORK/apkdel.log" 2>&1
rc=$?
expect "apk del of our packages exits 0" "rc=$rc: $(tail -n 3 "$WORK/apkdel.log")" test "$rc" = 0
expect "apk del: our packages are gone" "still installed" \
	r '! apk info -e shadow-vpn && ! apk info -e luci-app-shadow-vpn && ! apk info -e luci-i18n-shadow-vpn-ru'
expect "apk del keeps dnsmasq-full (no swap back to dnsmasq)" "$(grep -i dnsmasq "$WORK/apkdel.log" | tr '\n' ' ')" \
	r 'apk info -e dnsmasq-full && [ ! -e /lib/apk/packages/dnsmasq.list ] && dnsmasq --version | grep -q nftset'
expect "apk del: DNS still works" "no answer" r 'pidof dnsmasq && nslookup openwrt.org 127.0.0.1'
expect "apk del: /etc/config/dhcp kept" "changed" test "$(r 'sha256sum /etc/config/dhcp')" = "$DHCP_SUM"
expect "apk del: Shadow is recorded off (a later install starts off)" "enabled=$(r 'uci -q get shadow-vpn.main.enabled')" \
	r '[ "$(uci -q get shadow-vpn.main.enabled)" = 0 ]'
expect "apk del: both cron lines and the fw4 include removed" "lines=$(cron_both)" \
	sh -c "[ '$(cron_both)' = '0 0' ] && ! docker exec $ROUTER uci -q get firewall.shadow_vpn"
if menu_has_shadow; then nok "apk del: LuCI menu entry gone" "still in admin/menu"; else ok "apk del: LuCI menu entry gone"; fi

run_install "$WORK/reinstall.log" "$BASE/v1"
rc=$?
expect "install.sh after apk del installs 0.1.0 again, off" "rc=$rc: $(tail -n 3 "$WORK/reinstall.log")" \
	sh -c "[ $rc = 0 ] && grep -q 'Shadow 0.1.0-r1 is installed and is off' '$WORK/reinstall.log'"
expect "...with one of each cron line again" "lines=$(cron_both)" test "$(cron_both)" = "1 1"

# --- a new latest release published while install.sh downloads: old sums with a new package. install.sh pauses
# and fetches everything again; the release is consistent again meanwhile.
docker exec "$WEB" sh -c 'mkdir -p /srv/flux && cp /srv/v1/* /srv/flux/ && printf x >> /srv/flux/shadow-vpn.apk'
( run_install "$WORK/flux.log" "$BASE/flux"; echo "rc=$?" >> "$WORK/flux.log" ) &
flux_pid=$!
seen=0
for _ in $(seq 1 120); do
	grep -q 'Downloading again' "$WORK/flux.log" 2>/dev/null && { seen=1; break; }
	sleep 1
done
docker exec "$WEB" cp /srv/v1/shadow-vpn.apk /srv/flux/shadow-vpn.apk
wait "$flux_pid"
expect "a new latest release during the download: fetched again, then installed" "$(tail -n 4 "$WORK/flux.log" | tr '\n' ' ')" \
	sh -c "[ $seen = 1 ] && grep -qx 'rc=0' '$WORK/flux.log' && grep -q 'Shadow 0.1.0-r1 is already installed' '$WORK/flux.log'"

# --- upgrade keeps Shadow on. The router is made to look like one with a build from before the updater: only the
# lists cron line (the upgrade from the published release below checks the same while that release has no updater).
r 'uci set shadow-vpn.main.enabled=1 && uci commit shadow-vpn'
r "crontab -c /etc/crontabs -l | grep -vF '$UPDATE_CMD' | crontab -c /etc/crontabs -"
run_install "$WORK/upgrade.log" "$BASE/v2"
rc=$?
if [ "$rc" = 0 ]; then ok "upgrades to 0.1.1"; else nok "upgrades to 0.1.1" "rc=$rc: $(tail -n 5 "$WORK/upgrade.log")"; fi
expect "upgrade installed 0.1.1-r1" "$(r 'apk list -I shadow-vpn 2>/dev/null')" \
	r 'apk list -I shadow-vpn 2>/dev/null | grep -q "^shadow-vpn-0.1.1-r1 "'
expect "upgrade keeps Shadow on" "enabled=$(r 'uci -q get shadow-vpn.main.enabled')" \
	sh -c "[ \"\$(docker exec $ROUTER uci -q get shadow-vpn.main.enabled)\" = 1 ] && grep -q 'upgraded to 0.1.1-r1 and is on' '$WORK/upgrade.log'"
expect "upgrade keeps the lists line and adds the update line (one of each)" "lines=$(cron_both)" test "$(cron_both)" = "1 1"
# the package scripts started detached jobs (busybox start-stop-daemon -b keeps descriptors above 2): none got the lock
expect "the upgrade leaves the update lock free" "held after install.sh" r "flock -n $UPDATE_LOCK true"

# --- an update from LuCI or at night holds the updater's lock: install.sh does not run in the middle of it
r "mkdir -p /var/lock && rm -f /tmp/holder.pid"
docker exec -d "$ROUTER" sh -c "exec 9>>$UPDATE_LOCK && flock 9 && echo \$\$ > /tmp/holder.pid && exec sleep 120"
for _ in $(seq 1 50); do r '[ -s /tmp/holder.pid ]' && break; sleep 0.2; done
run_install "$WORK/locked.log" "$BASE/v2"
rc=$?
expect "refuses while an update runs, in Russian and English" "rc=$rc: $(tail -n 3 "$WORK/locked.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'Shadow is being updated right now' '$WORK/locked.log' && grep -q 'Shadow сейчас обновляется' '$WORK/locked.log'"
run_install "$WORK/locked-uninstall.log" "$BASE/v2" --uninstall
rc=$?
expect "--uninstall refuses too, and removes nothing" "rc=$rc: $(tail -n 3 "$WORK/locked-uninstall.log")" \
	sh -c "[ $rc -ne 0 ] && grep -q 'Shadow is being updated right now' '$WORK/locked-uninstall.log' && docker exec $ROUTER apk info -e shadow-vpn >/dev/null"
r 'kill "$(cat /tmp/holder.pid)"; rm -f /tmp/holder.pid'

# --- the release moved back to an older version (a rollback): said so, not "upgraded"
run_install "$WORK/downgrade.log" "$BASE/v1"
rc=$?
expect "a downgrade says downgraded" "rc=$rc: $(tail -n 3 "$WORK/downgrade.log")" \
	sh -c "[ $rc = 0 ] && grep -q 'Shadow is downgraded to 0.1.0-r1 (was 0.1.1-r1)' '$WORK/downgrade.log' && ! grep -q 'upgraded to' '$WORK/downgrade.log'"
run_install "$WORK/reupgrade.log" "$BASE/v2"
rc=$?
expect "and back up to 0.1.1" "rc=$rc: $(tail -n 3 "$WORK/reupgrade.log")" sh -c "[ $rc = 0 ] && grep -q 'upgraded to 0.1.1-r1' '$WORK/reupgrade.log'"
if stub_used shadow-vpn/files/usr/libexec/shadow-vpn/apply; then
	expect "upgrade does not tear Shadow down" "apply teardown ran on upgrade" r '! grep -q "^apply teardown" /tmp/shadow-vpn-stub.log'
fi

# --- uninstall
run_install "$WORK/uninstall.log" "$BASE/v2" --uninstall
rc=$?
if [ "$rc" = 0 ]; then ok "uninstalls"; else nok "uninstalls" "rc=$rc: $(tail -n 5 "$WORK/uninstall.log")"; fi
expect "our packages are gone" "still installed" \
	r '! apk info -e shadow-vpn && ! apk info -e luci-app-shadow-vpn && ! apk info -e luci-i18n-shadow-vpn-ru'
expect "dnsmasq-full stays, in the world" "dnsmasq-full removed" r 'apk info -e dnsmasq-full && grep -qx dnsmasq-full /etc/apk/world'
expect "DNS still works after uninstall" "no answer" r 'pidof dnsmasq && nslookup openwrt.org 127.0.0.1'
expect "orphaned xray-core removed" "xray-core still installed" r '! apk info -e xray-core'
expect "both cron lines removed" "lines=$(cron_both)" test "$(cron_both)" = "0 0"
expect "Shadow is off and its settings are kept" "config missing or on" r '[ "$(uci -q get shadow-vpn.main.enabled)" = 0 ]'
if menu_has_shadow; then nok "LuCI menu entry gone after uninstall" "still in admin/menu"; else ok "LuCI menu entry gone after uninstall"; fi
if stub_used shadow-vpn/files/usr/libexec/shadow-vpn/apply; then
	expect "uninstall tears Shadow down (apply teardown)" "$(r 'cat /tmp/shadow-vpn-stub.log')" \
		r 'grep -qx "apply teardown" /tmp/shadow-vpn-stub.log'
fi

run_install "$WORK/uninstall2.log" "$BASE/v2" --uninstall
rc=$?
expect "uninstall again says not installed" "rc=$rc" sh -c "[ $rc = 0 ] && grep -q 'Shadow is not installed' '$WORK/uninstall2.log'"

# --- the published release (DESIGN.md 11). Routers run install.sh from the default branch with the packages of
# the latest GitHub release, so this install.sh must install that release, fetched from GitHub the way a router
# does (no SHADOW_BASE_URL); before the first release it must say that none is published. Only a release.yml run
# that publishes a new version sets PUBLISHED_RELEASE=skip: the release it publishes replaces that one, and a
# broken latest release must not block the release that fixes it. Every other run checks it: ci.yml, and
# release.yml on a push to the default branch whose version is released already (or whose gate failed).
# The same holds for the updater (DESIGN.md 11): this tree's updater asks GitHub the way a router does, its download
# step fetches the published release through both of its paths, and the updater of the published release, once
# there is one, installs this tree's build.
REPO="$(sed -n 's/^REPO=//p' "$TREE/install.sh")"
RATE_LIMITED='GitHub refused the request: too many requests from this address. Try again in an hour.'

# json_field <file> <key>: a top-level field of the JSON object on the last line of <file> (a string bare, anything
# else as JSON), '<no JSON>' when that line is none
json_field() {
	python3 -I - "$1" "$2" <<'EOF'
import json, sys
lines = [l for l in open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines() if l.strip()]
try:
    v = json.loads(lines[-1]).get(sys.argv[2])
except Exception:
    v = '<no JSON>'
print(v if isinstance(v, str) else json.dumps(v))
EOF
}

# release_json <dir> <version> <base URL>: <dir>/release.json shaped like GitHub's release API, with the fields the
# updater reads, for SHA256SUMS and the files it lists, as the updater finds it under <base URL>
release_json() {
	python3 -I - "$1" "$2" "$3" "$REPO" <<'EOF'
import hashlib, json, os, sys, time
d, v, base, repo = sys.argv[1:5]
names = ['SHA256SUMS'] + [l.split()[1] for l in open(os.path.join(d, 'SHA256SUMS')) if l.strip()]
assets = []
for i, n in enumerate(names):
    data = open(os.path.join(d, n), 'rb').read()
    assets.append({'name': n, 'url': 'https://api.github.com/repos/%s/releases/assets/%d' % (repo, 900001 + i),
                   'size': len(data), 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()})
with open(os.path.join(d, 'release.json'), 'w') as f:
    json.dump({'tag_name': v, 'name': v, 'html_url': '%s/releases/tag/%s' % (base, v), 'draft': False,
               'prerelease': False, 'published_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
               'body': 'Test release %s.' % v, 'assets': assets}, f)
EOF
}

# github_check: this tree's updater asks GitHub for the latest release (no base URL); its stdout in gh-check.out
github_check() {
	docker exec "$ROUTER" "$UPDATER" check </dev/null >"$WORK/gh-check.out" 2>"$WORK/gh-check.err"
}
gh() { json_field "$WORK/gh-check.out" "$1"; }

if [ "${PUBLISHED_RELEASE:-check}" = skip ]; then
	ok "the published release # SKIP PUBLISHED_RELEASE=skip"
else
	# github.com redirects releases/latest to releases/tag/<tag>, or to releases when none is published; a
	# repository that is not public (yet) answers 404. No API call: its rate limit is per address.
	latest="$(docker exec "$WEB" curl -sL -m 60 -o /dev/null -w '%{http_code} %{url_effective}' "https://github.com/$REPO/releases/latest")"
	case "$latest" in
	"200 https://github.com/$REPO/releases/tag/"?*) tag="${latest##*/}" ;;
	"200 https://github.com/$REPO/releases" | "404 "*) tag= ;;
	*) tag=unknown ;;
	esac
	if [ "$tag" = unknown ]; then
		nok "github.com answers for the latest release of $REPO" "$latest"
	elif [ -z "$tag" ]; then
		run_install "$WORK/published.log" ""
		rc=$?
		expect "no release of $REPO on GitHub yet: install.sh says so, in Russian and English" "rc=$rc: $(tail -n 2 "$WORK/published.log")" \
			sh -c "[ $rc -ne 0 ] && grep -q 'No Shadow release is published yet' '$WORK/published.log' && grep -q 'Shadow ещё не опубликован' '$WORK/published.log' && ! grep -q 'Check access to github.com' '$WORK/published.log'"
		expect "...and installs nothing" "something got installed" r '! apk info -e shadow-vpn && ! apk info -e luci-app-shadow-vpn'
		run_install "$WORK/tree.log" "$BASE/v2"
		rc=$?
		expect "this tree's build installs, for its updater" "rc=$rc: $(tail -n 3 "$WORK/tree.log")" test "$rc" = 0
		github_check
		rc=$?
		if [ "$(gh error)" = "$RATE_LIMITED" ]; then
			ok "update check against GitHub # SKIP GitHub's rate limit for this address"
		else
			expect "...and its update check says so too" "rc=$rc: $(cat "$WORK/gh-check.out")" \
				test "$rc $(gh ok) $(gh error)" = "1 false No Shadow release is published yet."
		fi
	else
		run_install "$WORK/published.log" ""
		rc=$?
		expect "this install.sh installs the latest release $tag from GitHub" "rc=$rc: $(tail -n 3 "$WORK/published.log")" \
			sh -c "[ $rc = 0 ] && grep -Eq 'Shadow ${tag#v}-r[0-9]+ is installed and is off' '$WORK/published.log'"
		expect "...all three packages of $tag" "$(r 'apk list -I 2>/dev/null' | grep shadow-vpn | tr '\n' ' ')" \
			r "apk info -e shadow-vpn luci-app-shadow-vpn luci-i18n-shadow-vpn-ru && apk list -I shadow-vpn 2>/dev/null | grep -q '^shadow-vpn-${tag#v}-r'"
		expect "...with the lists cron line" "lines=$(cron_both)" test "$(cron_lines)" = 1

		# this tree's build as the release after $tag: the updater of $tag installs it from a base URL when $tag has
		# one (an installed updater of any older version keeps installing later releases), else install.sh does.
		# Either way the router ends with both cron lines: an upgrade from a release with the lists line only adds
		# the update line.
		pub="${tag#v}"
		next="${pub%.*}.$((${pub##*.} + 1))"
		if build "$next" next && release_json "$WORK/www/next" "$next" "$BASE/next" &&
			(cd "$WORK/www" && COPYFILE_DISABLE=1 tar -cf - next) | docker exec -i "$WEB" tar -xf - -C /srv; then
			ok "this tree's build as $next, served with a release.json"
		else
			nok "this tree's build as $next, served with a release.json" "$(tail -n 5 "$WORK/build-$next.log")"
		fi
		if r "[ -x $UPDATER ]"; then
			docker exec -e SHADOW_BASE_URL="$BASE/next" "$ROUTER" "$UPDATER" install </dev/null >"$WORK/pub-update.out" 2>"$WORK/pub-update.err"
			rc=$?
			expect "the updater of $tag installs this tree's build $next from a base URL" "rc=$rc: $(cat "$WORK/pub-update.out")" \
				test "$rc $(json_field "$WORK/pub-update.out" ok) $(json_field "$WORK/pub-update.out" to)" = "0 true $next"
		else
			run_install "$WORK/pub-upgrade.log" "$BASE/next"
			rc=$?
			expect "install.sh upgrades $tag, which has no updater, to this tree's build $next" "rc=$rc: $(tail -n 3 "$WORK/pub-upgrade.log")" \
				sh -c "[ $rc = 0 ] && grep -q 'upgraded to $next-r1' '$WORK/pub-upgrade.log'"
		fi
		expect "...$next-r1 is installed" "$(r 'apk list -I shadow-vpn 2>/dev/null')" \
			r "apk list -I shadow-vpn 2>/dev/null | grep -q '^shadow-vpn-$next-r1 '"
		expect "...with one of each cron line" "lines=$(cron_both)" test "$(cron_both)" = "1 1"

		# this tree's updater asks GitHub's API the way a router does: $tag is the latest release, older than $next
		github_check
		rc=$?
		if [ "$(gh error)" = "$RATE_LIMITED" ]; then
			ok "update check against GitHub # SKIP GitHub's rate limit for this address"
		else
			expect "update check against GitHub: the latest release is $tag" "rc=$rc: $(cat "$WORK/gh-check.out")" \
				test "$rc $(gh ok) $(gh latest) $(gh installed) $(gh available)" = "0 true $pub $next false"
			expect "...one JSON line on stdout, nothing else" "$(cat "$WORK/gh-check.out")" test "$(grep -c '' "$WORK/gh-check.out")" = 1
		fi

		# update.uc's download step for $tag through each of its two paths (install.sh's): 1 the tag's download URL,
		# 2 the asset API URL after the download URL answered 404. A fake apk database says 0.0.1 is installed, so
		# $tag is newer; stub commands keep the rest off the router: apk keeps the files it is given, with the
		# SHA256SUMS they were checked against, and rpcd's reload does nothing. The install then ends in "did not
		# install", after every download was checked.
		limited=0
		for path in 1 2; do
			docker exec -i "$ROUTER" sh -s "$path" >"$WORK/dl$path.out" 2>&1 <<'EOF'
D=/tmp/shv-dl$1
rm -rf "$D"
mkdir -p "$D/bin" "$D/kept" "$D/run" "$D/etc"
printf 'P:shadow-vpn\nV:0.0.1-r1\n\nP:luci-app-shadow-vpn\nV:0.0.1-r1\n\nP:luci-i18n-shadow-vpn-ru\nV:0.0.1-r1\n' > "$D/installed"
ln -s /bin/df "$D/bin/df"
printf '#!/bin/sh\nexit 0\n' > "$D/bin/rpcd"
cat > "$D/bin/apk" <<STUB
#!/bin/sh
# install_test.sh: keeps what "apk add" is given, and the SHA256SUMS next to it; "apk update" does nothing
[ "\$1" = add ] || exit 0
for a; do
	case "\$a" in *.apk) cp "\$a" "\${a%/*}/SHA256SUMS" $D/kept/ ;; esac
done
STUB
cat > "$D/bin/uclient-fetch" <<STUB
#!/bin/sh
# install_test.sh: the real uclient-fetch, every URL logged; on path 2 GitHub's download URLs answer 404
for a; do url="\$a"; done
echo "\$url" >> $D/urls
case "$1:\$url" in
2:https://github.com/*/releases/download/*) echo "HTTP error 404" >&2; exit 8 ;;
esac
exec /bin/uclient-fetch "\$@"
STUB
chmod 755 "$D/bin/apk" "$D/bin/rpcd" "$D/bin/uclient-fetch"
cat > "$D/dl.uc" <<STUB
import { install } from 'shadow-vpn.update';
print(sprintf('%J\n', install({ bin: '$D/bin', run: '$D/run', etc: '$D/etc', lock: '$D/lock', db: '$D/installed',
	mode: 'manual', blocked: () => false })));
STUB
ucode "$D/dl.uc"
EOF
			if [ "$(json_field "$WORK/dl$path.out" error)" = "$RATE_LIMITED" ]; then
				ok "download step, path $path # SKIP GitHub's rate limit for this address"
				limited=1
				continue
			fi
			expect "download step, path $path: every file of $tag downloaded and checked" "$(tail -n 3 "$WORK/dl$path.out")" \
				test "$(json_field "$WORK/dl$path.out" from) $(json_field "$WORK/dl$path.out" to) $(json_field "$WORK/dl$path.out" error)" = \
					"0.0.1 $pub The package manager did not install Shadow $pub."
			expect "download step, path $path: the packages match $tag's SHA256SUMS" "$(r "ls /tmp/shv-dl$path/kept" | tr '\n' ' ')" \
				r "cd /tmp/shv-dl$path/kept && grep -q '  shadow-vpn.apk\$' SHA256SUMS && grep '\.apk\$' SHA256SUMS > apk.sums && sha256sum -c apk.sums"
		done
		if [ "$limited" = 0 ]; then
			expect "download step, path 1: every file from the tag's download URL" "$(r 'cat /tmp/shv-dl1/urls' | tr '\n' ' ')" \
				r "[ -s /tmp/shv-dl1/urls ] && ! grep -v -e '^https://api.github.com/repos/$REPO/releases/latest\$' -e '^https://github.com/$REPO/releases/download/$tag/' /tmp/shv-dl1/urls"
			n="$(r "grep -c '\.apk\$' /tmp/shv-dl2/kept/apk.sums" 2>/dev/null | tr -cd '0-9')"
			expect "download step, path 2: SHA256SUMS and the $n packages from the asset API" "$(r 'cat /tmp/shv-dl2/urls' | tr '\n' ' ')" \
				test "$(r "grep -c '^https://api.github.com/repos/$REPO/releases/assets/[0-9]*\$' /tmp/shv-dl2/urls")" -ge "$((${n:-0} + 1))"
			expect "download step: both paths gave the same files" "they differ" \
				r 'cd /tmp/shv-dl1/kept && for f in *.apk SHA256SUMS; do cmp -s "$f" "/tmp/shv-dl2/kept/$f" || exit 1; done'
		fi
	fi
fi

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]
