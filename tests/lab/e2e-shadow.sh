#!/bin/bash
# Shadow for OpenWrt in the lab: build, install with install.sh, and the scenario checks of each stage.
#
#   tests/lab/e2e-shadow.sh                  # install + stage1
#   tests/lab/e2e-shadow.sh install stage1   # pick stages (install, stage1, stage2, stage3)
#   tests/lab/e2e-shadow.sh stage2.ssh       # one group of stage2 (see stage2() below)
#   tests/lab/e2e-shadow.sh stage3.boot      # one group of stage3 (see stage3() below)
#   SKIP_BUILD=1 tests/lab/e2e-shadow.sh     # install out/ as it is
#
# stage3 power-cycles the router (docker kill + docker start), never a graceful shutdown: OpenWrt's
# K90umount would remount the Docker host's shared cgroup2 read-only (tests/lab/README.md).
#
# Needs a lab from ./up.sh (MODE=deps). Re-runnable: every stage sets up what it needs and says what it
# leaves behind. Prints "ok <name>" / "not ok <name>: <why>" and "# measured <what>: <value>" lines and exits
# 1 when a check failed. Every wait is a poll with a deadline; measured times are printed, never asserted
# tightly (only generous bounds that mean "broken", not "slow").
#
# web echoes "src=<ip>" (TCP) and "udp-src=<ip>" (UDP :7777): 203.0.113.2 = direct, 203.0.113.20 = tunnelled.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TREE="$(cd "$HERE/../.." && pwd)"
STATE="$HERE/state"
ROOT_PW="${ROOT_PW:-shadow-lab}"          # throwaway LuCI password of the lab router (up.sh)
PKGSRV=shadow-pkgsrv
PKGSRV_IP=203.0.113.30
BASE_URL="http://$PKGSRV_IP"
LABEL="com.shadow.testenv=1"
DIRECT_SRC="src=203.0.113.2 "
TUNNEL_SRC="src=203.0.113.20 "
RUN=/var/run/shadow-vpn
LIBEXEC=/usr/libexec/shadow-vpn
PUBLIC_NAME=example.com                  # a public name for tunnel DNS (the lab zone is unknown to DoH)

pass=0
fail=0

ok() { pass=$((pass + 1)); echo "ok $1"; }
nok() { fail=$((fail + 1)); echo "not ok $1: $(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)"; }
measure() { echo "# measured $1: $2"; }
note() { echo "# $*"; }

# check <name> <expected substring> <actual>
check() {
	if { printf '%s' "$3"; } 2>/dev/null | grep -qF -- "$2"; then ok "$1"; else nok "$1" "want '$2', got '$3'"; fi
}

# check_not <name> <unexpected substring> <actual>
check_not() {
	if { printf '%s' "$3"; } 2>/dev/null | grep -qF -- "$2"; then nok "$1" "did not want '$2', got '$3'"; else ok "$1"; fi
}

# expect <name> <command...>: the command succeeds
expect() {
	local name="$1"
	shift
	local out
	if out="$("$@" 2>&1)"; then ok "$name"; else nok "$name" "${out:-command failed}"; fi
}

# expect_soon <seconds> <name> <command...>: the command succeeds within that many seconds (polled)
expect_soon() {
	local secs="$1" name="$2"
	shift 2
	if poll "$secs" "$@"; then ok "$name"; else nok "$name" "$("$@" 2>&1 | tail -3 | tr '\n' ' ')${POLL_MS:+(polled $POLL_MS ms)}"; fi
}

R() { docker exec shadow-router sh -c "$1" 2>&1; }
C() { docker exec shadow-client sh -c "$1" 2>&1; }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }

# rpc <method> [json]: the LuCI rpc object on the router (JSON args via stdin, never in argv)
rpc() {
	local args="${2:-}"
	[ -n "$args" ] || args='{}'
	printf '%s' "$args" | docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn "$1" "$(cat)"' _ "$1" 2>&1
}

status_field() { rpc status | jq -r "$1" 2>/dev/null; }

# poll <seconds> <command...>: runs the command every POLL_SLEEP (0.3 s) until it succeeds; POLL_MS = time it took
poll() {
	local secs="$1" start end
	shift
	start=$(now_ms)
	end=$((start + secs * 1000))
	while :; do
		if "$@" >/dev/null 2>&1; then
			POLL_MS=$(($(now_ms) - start))
			return 0
		fi
		[ "$(now_ms)" -ge "$end" ] && break
		sleep "${POLL_SLEEP:-0.3}"
	done
	POLL_MS=$(($(now_ms) - start))
	return 1
}

# job_wait <json from an rpc that returned { job }> [seconds, default 90]: waits for the job; prints its final JSON
job_wait() {
	local id
	id="$(printf '%s' "$1" | jq -r '.job // empty' 2>/dev/null)"
	[ -n "$id" ] || { echo "no job: $1"; return 1; }
	poll "${2:-90}" job_done "$id"
	rpc job_status "{\"id\":\"$id\"}"
}
# done or failed: a call that fails is no answer (rpcd re-executes itself while an update installs)
job_done() { case "$(rpc job_status "{\"id\":\"$1\"}" | jq -r .state 2>/dev/null)" in done | failed) return 0 ;; esac; return 1; }

applied_gen() { R "cat $RUN/applied 2>/dev/null" | tr -d '\n'; }
converged_since() { local g; g="$(applied_gen)"; [ -n "$g" ] && [ "$g" != "$1" ]; }
phase_is() { [ "$(status_field .phase)" = "$1" ]; }
tunnel_up() { [ "$(rpc status | jq -r '"\(.phase) \(.tunnel.alive)"')" = "connected true" ]; }
inactive() { R "[ ! -e $RUN/active ]" >/dev/null; }
last_check_ok() { [ "$(R "jsonfilter -i $RUN/check.json -e @.ok 2>/dev/null")" = true ]; }

# pid of a procd instance of ours (xray, ssh), empty when there is none
inst_pid() {
	R 'ubus call service list "{\"name\":\"shadow-vpn\"}"' | jq -r --arg i "$1" '."shadow-vpn".instances[$i].pid // empty' 2>/dev/null
}
inst_restarted() { local p; p="$(inst_pid "$1")"; [ -n "$p" ] && [ "$p" != "$2" ]; }

# wait_up <old applied gen> <what> [<instance> <its pid before>]: a converge applied since, the instance was
# restarted (so the old process's status cannot answer for the new one), then phase connected, tunnel alive
wait_up() {
	local old="$1" what="$2" inst="${3:-}" old_pid="${4:-}" t0
	t0=$(now_ms)
	if ! poll 60 converged_since "$old"; then
		nok "$what: converge applied" "$(rpc status | jq -c '{phase,message,attention}')"
		return 1
	fi
	if [ -n "$inst" ] && ! poll 60 inst_restarted "$inst" "$old_pid"; then
		nok "$what: $inst restarted" "pid still ${old_pid:-none}"
		return 1
	fi
	if poll 60 tunnel_up; then
		ok "$what: connected, tunnel alive"
		measure "$what -> connected and tunnel alive" "$(($(now_ms) - t0)) ms"
		return 0
	fi
	nok "$what: connected, tunnel alive" "$(rpc status | jq -c '{phase,message,tunnel,attention}')"
	return 1
}

# set_main k=v...: what LuCI's Settings form does (uci commit + config.change -> procd reload -> job converge)
set_main() {
	local kv cmd=""
	for kv in "$@"; do cmd="$cmd uci set shadow-vpn.main.$kv;"; done
	R "$cmd uci commit shadow-vpn; reload_config" >/dev/null
}

main_opt() { R "uci -q get shadow-vpn.main.$1" | tr -d '\n'; }

curl_c() { C "curl -s -m 8 $1"; }
public_name_resolves() { C "dig +short +time=3 +tries=1 $PUBLIC_NAME A" | grep -qE '^[0-9.]+$'; }
udp_c() { C "echo hi | socat -T 3 - UDP4:$1 2>&1"; }
udp_says() { udp_c "$1" | grep -qF -- "$2"; }
pings() { C "ping -c 1 -W 2 $1" | grep -q ' 0% packet loss'; }

# check_ping <name> <addr>: an echo reply arrives (one request per try until the deadline)
check_ping() {
	if poll 10 pings "$2"; then ok "$1"; else nok "$1" "$(C "ping -c 2 -W 2 $2" | tail -2)"; fi
	return 0
}

# check_udp <name> <addr:port> <expected reply>: UDP may lose a datagram (the first one of a new tunnel
# session, say), so a new one is sent until the deadline
check_udp() {
	if poll 15 udp_says "$2" "$3"; then
		ok "$1"
		[ "$POLL_MS" -gt 3500 ] && measure "$1: answered after" "$POLL_MS ms"
	else
		nok "$1" "want '$3', got '$(udp_c "$2")'"
	fi
	return 0
}

# ---- lab --------------------------------------------------------------------------------------------

lab_ready() {
	local c
	for c in shadow-router shadow-client shadow-web shadow-vpn; do
		[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || {
			echo "lab is not up ($c missing): run tests/lab/up.sh" >&2
			exit 2
		}
	done
	R 'command -v xray >/dev/null' >/dev/null || { echo "router has no xray: run up.sh with MODE=deps" >&2; exit 2; }
	# up.sh made shadow-web the lab ISP resolver with a UDP echo per address and the port-forward peer
	# 198.51.100.10, routed by the router; shadow-vpn may block the router with nft. An older lab lacks them.
	if ! R 'grep -q 203.0.113.10 /tmp/resolv.conf.d/resolv.conf.auto' >/dev/null ||
		! docker exec shadow-web sh -c 'netstat -lnu | grep -q "203.0.113.11:7777 " && ip -4 addr show dev eth0 | grep -q 198.51.100.10' \
			>/dev/null 2>&1 ||
		! R 'ip route | grep -q "^198.51.100.10 via 203.0.113.10"' >/dev/null ||
		! docker inspect -f '{{.HostConfig.CapAdd}}' shadow-vpn | grep -q NET_ADMIN; then
		echo "the lab was created by an older up.sh: run tests/lab/down.sh && tests/lab/up.sh" >&2
		exit 2
	fi
}

# pkgsrv_start [dir]: serves the packages of <dir> (default out/) and install.sh at $BASE_URL. For the updater
# (stage3_update) also <dir>/release.json and the tag directories <dir>/X.Y.Z/ where they exist: the base URL
# layout of DESIGN.md 11 (<base>/release.json and <base>/<name> for the latest release, <base>/<tag>/... for a tag).
pkgsrv_start() {
	local dir="${1:-$TREE/out}"
	docker rm -f "$PKGSRV" >/dev/null 2>&1
	docker run -d --name "$PKGSRV" --label "$LABEL" --network name=shadow-wan,ip=$PKGSRV_IP \
		shadow-testenv/tools:alpine3.22 sh -c 'mkdir -p /srv /run/nginx
			printf "server { listen 80 default_server; root /srv; location / { try_files \$uri =404; } }\n" \
				> /etc/nginx/http.d/default.conf
			exec nginx -g "daemon off;"' >/dev/null || return 1
	# streamed, not bind-mounted: OrbStack bind mounts may show a stale copy of a fresh build (and the package
	# server needs no path the Docker host shares)
	# shellcheck disable=SC2046 # the names ls finds, none with a space
	(cd "$dir" && COPYFILE_DISABLE=1 tar -cf - SHA256SUMS ./*.apk $(ls -d release.json [0-9]*.[0-9]*.[0-9]* 2>/dev/null)) |
		docker exec -i "$PKGSRV" tar -xf - -C /srv || return 1
	docker exec -i "$PKGSRV" sh -c 'cat > /srv/install.sh' < "$TREE/install.sh" || return 1
	poll 15 R "wget -q -O /dev/null $BASE_URL/SHA256SUMS"
}

pkgsrv_stop() { docker rm -f "$PKGSRV" >/dev/null 2>&1; }

# ---- stage: install -----------------------------------------------------------------------------------

stage_install() {
	echo "== install: build, serve out/ on the lab WAN, install.sh with SHADOW_BASE_URL"
	local was_installed=0 was_enabled out t0 rc

	if [ "${SKIP_BUILD:-0}" != 1 ]; then
		out="$("$TREE/build/mk_apk.sh" 2>&1)" && ok "install: build/mk_apk.sh" || { nok "install: build/mk_apk.sh" "$out"; return 1; }
	fi

	R 'apk info -e shadow-vpn' >/dev/null && was_installed=1
	was_enabled="$(main_opt enabled)"
	if [ "$was_installed" = 0 ]; then
		# a reused lab may still carry the LuCI design mock: none of its files may survive the install
		R 'rm -rf /www/luci-static/resources/view/shadow-vpn /www/luci-static/resources/shadow-vpn
		   rm -f /usr/share/luci/menu.d/luci-app-shadow-vpn.json /usr/share/rpcd/acl.d/luci-app-shadow-vpn.json
		   rm -f /tmp/luci-indexcache.*; rm -rf /tmp/luci-modulecache' >/dev/null
		note "fresh install (no shadow-vpn package before)"
	else
		note "upgrade/reinstall (shadow-vpn installed before, enabled=${was_enabled:-?})"
	fi

	# the router and the LAN before (an upgrade of a Shadow that is on: its tunnel carries the downloads)
	local before_tables
	before_tables="$(R 'nft list tables | sort' | tr '\n' ' ')"
	if [ "$was_enabled" != 1 ]; then
		check "install: LAN reaches the web directly before" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
	elif ! poll 60 tunnel_up; then
		note "Shadow is on but its tunnel is down: with the kill switch the router cannot download; turning it off first"
		enable false >/dev/null
		was_enabled=0
	fi

	expect "install: package server on the lab WAN" pkgsrv_start
	t0=$(now_ms)
	out="$(R "wget -q -O /tmp/install.sh $BASE_URL/install.sh && SHADOW_BASE_URL=$BASE_URL sh /tmp/install.sh </dev/null; echo rc=\$?")"
	measure "install.sh run" "$(($(now_ms) - t0)) ms"
	pkgsrv_stop
	check "install: install.sh exits 0" "rc=0" "$out"
	check "install: install.sh reports the result" "Done: Shadow" "$out"

	expect "install: packages installed" R 'apk info -e shadow-vpn luci-app-shadow-vpn luci-i18n-shadow-vpn-ru dnsmasq-full xray-core openssh-client'
	check "install: the installed helpers are the ones just built" "$(R 'md5sum < /usr/libexec/shadow-vpn/apply' | cut -c1-32)" \
		"$(md5 -q "$TREE/shadow-vpn/files/usr/libexec/shadow-vpn/apply" 2>/dev/null || md5sum < "$TREE/shadow-vpn/files/usr/libexec/shadow-vpn/apply")"

	if [ "$was_installed" = 0 ]; then
		check "install: a fresh install leaves Shadow off" "0" "$(main_opt enabled)"
		expect "install: no nft table" R '! nft list table inet shadow_vpn >/dev/null 2>&1'
		expect "install: no policy rule" R '! ip rule | grep -q "lookup 106"'
		expect "install: no dnsmasq file" R '! ls /tmp/dnsmasq.*.d/shadow-vpn.conf >/dev/null 2>&1'
		expect "install: no procd instances" R '! ubus call service list "{\"name\":\"shadow-vpn\"}" | grep -q running'
		check "install: rpc status says off" "false disconnected" "$(rpc status | jq -r '"\(.enabled) \(.phase)"')"
		check "install: firewall tables unchanged" "$before_tables" "$(R 'nft list tables | sort' | tr '\n' ' ')"
	else
		check "install: an upgrade keeps enabled=$was_enabled" "$was_enabled" "$(main_opt enabled)"
		if [ "$was_enabled" = 1 ]; then
			if poll 60 tunnel_up; then ok "install: after the upgrade the tunnel is up again"
			else nok "install: after the upgrade the tunnel is up again" "$(rpc status | jq -c '{phase,message,tunnel}')"; fi
		fi
	fi

	expect "install: fw4 include registered" R '[ "$(uci -q get firewall.shadow_vpn.path)" = /usr/libexec/shadow-vpn/fw4-hook ]'
	expect "install: chain-pre accept rule active in fw4" R 'nft list chain inet fw4 input | grep -q "meta mark & 0x00400000 == 0x00400000 accept"'
	expect "install: list refresh cron line" R 'crontab -l | grep -q "/usr/libexec/shadow-vpn/lists refresh due"'
	expect "install: no design mock left" R '[ ! -e /www/luci-static/resources/shadow-vpn/mock.js ]'

	# LuCI from the LAN side, like a browser
	C 'rm -f /tmp/cj; curl -s -m 10 -c /tmp/cj -o /dev/null -d "luci_username=root&luci_password='"$ROOT_PW"'" http://192.168.77.1/cgi-bin/luci/' >/dev/null
	check "install: LuCI menu has Services -> Shadow with six tabs" "Shadow overview,ssh,xray,routing,log,settings" \
		"$(C 'curl -s -m 10 -b /tmp/cj http://192.168.77.1/cgi-bin/luci/admin/menu' |
			jq -r '.children.admin.children.services.children["shadow-vpn"] | "\(.title) \(.children | keys_unsorted | join(","))"' 2>&1)"
	check "install: the Overview page loads" "200" \
		"$(C 'curl -s -m 10 -b /tmp/cj -o /dev/null -w %{http_code} http://192.168.77.1/cgi-bin/luci/admin/services/shadow-vpn/overview')"
	check "install: the Russian catalog is installed" "shadow-vpn.ru.lmo" "$(R 'ls /usr/lib/lua/luci/i18n/')"

	# the router and the LAN after
	[ "$was_enabled" != 1 ] &&
		check "install: LAN still reaches the web directly" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
	check "install: LAN DNS still answers" "203.0.113.11" "$(C 'dig +short +time=2 +tries=2 tunnel.shadow.lab')"
	check_ping "install: LAN ping still works" 203.0.113.10
}

# ---- stage 1 helpers ------------------------------------------------------------------------------------

server_sid() { rpc servers | jq -r --arg n "$1" '.servers[] | select(.name == $n) | .sid' | head -1; }
key_sid() { rpc keys | jq -r --arg n "$1" '.keys[] | select(.name == $n) | .sid' | head -1; }
profile_sid() { rpc profiles | jq -r --arg n "$1" '.profiles[] | select(.name == $n) | .sid' | head -1; }

# The lab servers: "Lab password" (password auth) and "Lab key" (the router key from state/).
ssh_servers() {
	local sid out ksid
	sid="$(server_sid 'Lab password')"
	out="$(jq -n --arg sid "$sid" --arg pw "$(cat "$STATE/ssh.pw")" \
		'{sid: $sid, values: {name: "Lab password", host: "203.0.113.20", port: "22", username: "vpnuser", auth: "password",
		  keepalive: "15", fingerprint: "", note: ""}, password: $pw}' | docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn server_save "$(cat)"')"
	SSH_PW_SID="$(printf '%s' "$out" | jq -r '.sid // empty')"
	[ -n "$SSH_PW_SID" ] && ok "ssh: server with a password saved" || nok "ssh: server with a password saved" "$out"

	ksid="$(key_sid 'Lab key')"
	out="$(jq -n --arg sid "$ksid" --rawfile text "$STATE/router_id_ed25519" '{sid: $sid, name: "Lab key", text: $text, passphrase: ""}' |
		docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn key_save "$(cat)"')"
	ksid="$(printf '%s' "$out" | jq -r '.sid // empty')"
	check "ssh: private key saved" "ed25519 openssh" "$(printf '%s' "$out" | jq -r '"\(.key.type) \(.key.format)"')"

	sid="$(server_sid 'Lab key')"
	out="$(jq -n --arg sid "$sid" --arg k "$ksid" \
		'{sid: $sid, values: {name: "Lab key", host: "203.0.113.20", port: "22", username: "vpnuser", auth: "key", key: $k,
		  keepalive: "15", fingerprint: "", note: ""}}' | docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn server_save "$(cat)"')"
	SSH_KEY_SID="$(printf '%s' "$out" | jq -r '.sid // empty')"
	[ -n "$SSH_KEY_SID" ] && ok "ssh: server with a key saved" || nok "ssh: server with a key saved" "$out"
}

# the user domain rule tunnel.shadow.lab, enabled, exactly once
domain_rule() {
	local sid
	sid="$(rpc rules | jq -r '.rules[] | select(.type == "domain" and .value == "tunnel.shadow.lab") | .sid' | head -1)"
	if [ -z "$sid" ]; then
		rpc rule_add '{"type":"domain","value":"tunnel.shadow.lab"}' | jq -e .sid >/dev/null
	else
		rpc rule_set "{\"sid\":\"$sid\",\"enabled\":true}" | jq -e .ok >/dev/null
	fi
}

# direct list fixture: the real list is downloaded from GitHub; here it names the lab's direct host
direct_list() {
	if [ "$1" = on ]; then
		R 'ucode -e '"'"'import { store } from "shadow-vpn.lists"; let r = store("direct", [ "direct.shadow.lab" ]); exit(r?.count == 1 ? 0 : 1);'"'" >/dev/null &&
			rpc list_set '{"kind":"direct","enabled":true}' | jq -e .job >/dev/null
	else
		rpc list_set '{"kind":"direct","enabled":false}' >/dev/null
		R 'rm -f /etc/shadow-vpn/lists/direct.lst /etc/shadow-vpn/lists/direct.sha256' >/dev/null
	fi
}

# Starts a DNS probe on the client: one query every ~0.1 s until stop_dns_probe; "<uptime> <answer|FAIL>".
start_dns_probe() {
	C 'rm -f /tmp/dnsprobe.stop /tmp/dnsprobe.log' >/dev/null
	docker exec -d shadow-client sh -c 'while [ ! -e /tmp/dnsprobe.stop ]; do
		a=$(dig +short +time=1 +tries=1 '"$1"' @192.168.77.1 2>/dev/null | grep -E "^[0-9.]+$" | head -1)
		read up _ < /proc/uptime; echo "$up ${a:-FAIL}" >> /tmp/dnsprobe.log; sleep 0.1; done'
}

# Stops it and prints "<queries> <failed> <longest gap between two answers in ms>"
stop_dns_probe() {
	C 'touch /tmp/dnsprobe.stop; sleep 1.5; cat /tmp/dnsprobe.log' |
		awk '{ n++ } $2 == "FAIL" { f++ } $2 != "FAIL" { if (last != "") { g = ($1 - last) * 1000; if (g > max) max = g } last = $1 }
			END { printf "%d %d %d\n", n, f, max }'
}

# set_enabled through rpc; waits for the job; prints the job JSON
enable() {
	local r
	r="$(rpc set_enabled "{\"enabled\":$1}")"
	job_wait "$r"
}

# The data plane is gone: table, rules, routes, dnsmasq file, procd instances, active flag.
check_off() {
	local what="$1"
	# the teardown removes "active" first and restarts dnsmasq last: let it finish before looking
	poll 30 settled
	expect "$what: nft table gone" R '! nft list table inet shadow_vpn >/dev/null 2>&1'
	expect "$what: policy rules gone" R '! ip rule | grep -q "lookup 106" && ! ip -6 rule | grep -q "lookup 106"'
	expect "$what: table 106 routes gone" R '[ -z "$(ip route show table 106 2>/dev/null)" ]'
	expect "$what: dnsmasq files gone" R '! ls /tmp/dnsmasq.*.d/shadow-vpn.conf /tmp/dnsmasq.*.d/.shadow-vpn.servers >/dev/null 2>&1'
	expect_soon 15 "$what: dnsmasq runs" dnsmasq_up
	expect "$what: no procd instances" R '! ubus call service list "{\"name\":\"shadow-vpn\"}" | grep -q "\"running\": true"'
	expect "$what: active flag gone" inactive
}

# ---- stage 1 -------------------------------------------------------------------------------------------

stage1_ssh_split() {
	echo "== stage1: SSH, split mode, user domain rule tunnel.shadow.lab"
	local gen r t0 probe

	ssh_servers
	# Off first, so the On below is a real cold start
	[ "$(main_opt enabled)" = 1 ] && enable false >/dev/null
	rpc select "{\"transport\":\"ssh\",\"sid\":\"$SSH_PW_SID\"}" >/dev/null
	expect "ssh split: domain rule tunnel.shadow.lab" domain_rule
	direct_list off
	# tunnel DNS resolves through DoH at 1.1.1.1, which cannot know the lab zone (tests/lab/README.md)
	set_main mode=selected-rules tunnel_dns=0 kill_switch=1 ssh_udp=reject
	poll 30 R "[ ! -e $RUN/pending ] && flock -n /var/lock/shadow-vpn.lock true" >/dev/null

	gen="$(applied_gen)"
	start_dns_probe tunnel.shadow.lab
	t0=$(now_ms)
	r="$(enable true)"
	measure "ssh split: set_enabled(true) job" "$(($(now_ms) - t0)) ms"
	check "ssh split: set_enabled(true) job completes" '"state": "done"' "$r"
	wait_up "$gen" "ssh split (password)"
	probe="$(stop_dns_probe)"
	measure "ssh split: DNS during On (queries failed longest-gap-ms)" "$probe"

	check "ssh split: tunnel.shadow.lab goes through the tunnel" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	check "ssh split: direct.shadow.lab stays direct" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
	check "ssh split: https to a tunnelled name" "200" "$(C 'curl -sk -m 8 -o /dev/null -w %{http_code} https://tunnel.shadow.lab/')"
	check "ssh split: the user set is filled by dnsmasq" "203.0.113.11" "$(R 'nft list set inet shadow_vpn user4')"
	expect "ssh split: the dnsmasq file is readable by dnsmasq" R 'ls -l /tmp/dnsmasq.*.d/shadow-vpn.conf | grep -q "^-rw-r--r--"'
	expect "ssh split: one file, no servers-file of ours" R '! ls /tmp/dnsmasq.*.d/.shadow-vpn.servers >/dev/null 2>&1 && ! grep -q servers-file /tmp/dnsmasq.*.d/shadow-vpn.conf'
	check_not "ssh split: dnsmasq read our file" "cannot read" "$(R 'logread | grep shadow-vpn.conf | tail -3')"
	check_ping "ssh split: ping to a tunnelled address works (ICMP goes direct)" 203.0.113.11
	check "ssh split: UDP to a tunnelled address is rejected over SSH" "refused" "$(udp_c 203.0.113.11:7777)"
	check_udp "ssh split: UDP to a direct address works" 203.0.113.10:7777 "udp-src=203.0.113.2"

	r="$(rpc status)"
	check "ssh split: status connected over ssh" "connected ssh Lab password" "$(printf '%s' "$r" | jq -r '"\(.phase) \(.transport) \(.target.name)"')"
	check "ssh split: tunnel.alive from xray metrics" "true number" "$(printf '%s' "$r" | jq -r '"\(.tunnel.alive) \(.tunnel.delay_ms | type)"')"
	# ssh-up starts the check about a second after the session is up: poll for its result
	if poll 30 last_check_ok; then
		ok "ssh split: check after connect succeeded"
	else
		nok "ssh split: check after connect succeeded" "$(R "cat $RUN/check.json")"
	fi
	measure "ssh split: observatory delay" "$(printf '%s' "$r" | jq -r .tunnel.delay_ms) ms"

	t0=$(now_ms)
	r="$(job_wait "$(rpc check)")"
	measure "ssh split: rpc check job" "$(($(now_ms) - t0)) ms ($(printf '%s' "$r" | jq -r '"\(.result.outcome) \(.result.ms) ms"'))"
	check "ssh split: rpc check through the tunnel" "true" "$(printf '%s' "$r" | jq -r .result.ok)"

	# the same over LuCI's JSON-RPC endpoint from the LAN, with a root session (ACL)
	local sess
	sess="$(jq -nc --arg pw "$ROOT_PW" '{jsonrpc: "2.0", id: 1, method: "call",
			params: [ "00000000000000000000000000000000", "session", "login", { username: "root", password: $pw } ]}' |
		ubus_http | jq -r '.result[1].ubus_rpc_session // empty')"
	check "ssh split: LuCI JSON-RPC status from the LAN" "connected" \
		"$(jq -nc --arg s "$sess" '{jsonrpc: "2.0", id: 2, method: "call", params: [ $s, "luci.shadow-vpn", "status", {} ]}' |
			ubus_http | jq -r '.result[1].phase // .error.message')"
}

# JSON-RPC body on stdin -> LuCI's /ubus endpoint, from the LAN client
ubus_http() { docker exec -i shadow-client curl -s -m 10 -H 'Content-Type: application/json' --data-binary @- http://192.168.77.1/ubus; }

stage1_ssh_key() {
	echo "== stage1: SSH with a private key"
	local gen pid
	gen="$(applied_gen)"
	pid="$(inst_pid ssh)"
	rpc select "{\"transport\":\"ssh\",\"sid\":\"$SSH_KEY_SID\"}" >/dev/null
	wait_up "$gen" "ssh key" ssh "$pid"
	check "ssh key: status names the key server" "Lab key" "$(status_field .target.name)"
	check "ssh key: ssh logged in with the key" 'using "publickey"' "$(R "grep Authenticated $RUN/ssh.$SSH_KEY_SID.log")"
	check "ssh key: tunnel.shadow.lab goes through the tunnel" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	check "ssh key: direct.shadow.lab stays direct" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
}

# An encrypted PKCS#8 key hides its algorithm: saved with type 'unknown', OpenSSH logs in with it.
# The key and its throwaway passphrase live in shadow-vpn:/tmp/pk8 (made once, its public half authorized).
stage1_ssh_pkcs8() {
	echo "== stage1: SSH with an encrypted PKCS#8 key"
	local out ksid sid gen pid
	docker exec shadow-vpn sh -c 'umask 077; mkdir -p /tmp/pk8
		[ -s /tmp/pk8/pass ] || head -c 12 /dev/urandom | od -An -tx1 | tr -d " \n" > /tmp/pk8/pass
		[ -s /tmp/pk8/key ] || ssh-keygen -q -t rsa -b 2048 -m PKCS8 -N "$(cat /tmp/pk8/pass)" -C shadow-lab-pkcs8 -f /tmp/pk8/key
		grep -qF "$(cat /tmp/pk8/key.pub)" /home/vpnuser/.ssh/authorized_keys || cat /tmp/pk8/key.pub >> /home/vpnuser/.ssh/authorized_keys' >/dev/null 2>&1
	check "pkcs8: the lab key is an encrypted PKCS#8 file" "-----BEGIN ENCRYPTED PRIVATE KEY-----" "$(docker exec shadow-vpn head -1 /tmp/pk8/key 2>&1)"

	ksid="$(key_sid 'Lab pkcs8')"
	out="$(jq -n --arg sid "$ksid" --arg text "$(docker exec shadow-vpn cat /tmp/pk8/key)" --arg pp "$(docker exec shadow-vpn cat /tmp/pk8/pass)" \
		'{sid: $sid, name: "Lab pkcs8", text: $text, passphrase: $pp}' | docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn key_save "$(cat)"')"
	ksid="$(printf '%s' "$out" | jq -r '.sid // empty')"
	check "pkcs8: key_save keeps it with type unknown" "unknown pkcs8 true" "$(printf '%s' "$out" | jq -r '"\(.key.type) \(.key.format) \(.key.encrypted)"')"
	check "pkcs8: the keys list shows it" "unknown" "$(rpc keys | jq -r --arg k "$ksid" '.keys[] | select(.sid == $k) | .type')"

	sid="$(server_sid 'Lab pkcs8')"
	out="$(jq -n --arg sid "$sid" --arg k "$ksid" \
		'{sid: $sid, values: {name: "Lab pkcs8", host: "203.0.113.20", port: "22", username: "vpnuser", auth: "key", key: $k,
		  keepalive: "15", fingerprint: "", note: ""}}' | docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn server_save "$(cat)"')"
	sid="$(printf '%s' "$out" | jq -r '.sid // empty')"
	[ -n "$sid" ] && ok "pkcs8: server saved" || nok "pkcs8: server saved" "$out"

	gen="$(applied_gen)"
	pid="$(inst_pid ssh)"
	rpc select "{\"transport\":\"ssh\",\"sid\":\"$sid\"}" >/dev/null
	wait_up "$gen" "pkcs8" ssh "$pid"
	check "pkcs8: ssh logged in with the key (passphrase from askpass)" 'using "publickey"' "$(R "grep Authenticated $RUN/ssh.$sid.log")"
	check "pkcs8: tunnel.shadow.lab goes through the tunnel" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
}

stage1_ssh_full() {
	echo "== stage1: SSH, full mode, tunnel DNS on"
	local gen probe
	gen="$(applied_gen)"
	set_main mode=proxy-all tunnel_dns=1
	wait_up "$gen" "ssh full"

	check "ssh full: tunnel.shadow.lab goes through the tunnel" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	check "ssh full: direct.shadow.lab goes through the tunnel too" "$TUNNEL_SRC" "$(curl_c http://direct.shadow.lab/)"
	# 403 is LuCI's login page: it answered, so the request stayed local
	check "ssh full: the router's LuCI (local) stays local" "luci" "$(C 'curl -s -m 8 http://192.168.77.1/cgi-bin/luci/')"
	check_ping "ssh full: ping works (ICMP is never tunnelled or rejected)" 203.0.113.10
	check "ssh full: UDP is rejected over SSH" "refused" "$(udp_c 203.0.113.10:7777)"
	check "ssh full: the router's own traffic goes through the tunnel" "$TUNNEL_SRC" "$(R 'curl -s -m 8 http://tunnel.shadow.lab/')"
	expect "ssh full: dnsmasq uses no-resolv with the tunnel as default upstream" \
		R 'grep -qx no-resolv /tmp/dnsmasq.*.d/shadow-vpn.conf && grep -qx "server=127.0.0.1#5300" /tmp/dnsmasq.*.d/shadow-vpn.conf'
	# the router's time servers never wait for the tunnel: a router without a battery clock boots with an
	# old time, and TLS and VMess fail until NTP has set it
	expect "ssh full: the NTP server names go to the WAN DNS, not the tunnel" \
		R 'ntp="$(uci -q get system.ntp.server | cut -d " " -f 1)"; [ -n "$ntp" ] &&
		   grep "^server=/" /tmp/dnsmasq.*.d/shadow-vpn.conf | grep -F "/$ntp/" | grep -q "/203.0.113.10$" &&
		   ! grep "^nftset=" /tmp/dnsmasq.*.d/shadow-vpn.conf | grep -qF "/$ntp/"'
	check "ssh full: no dns_bootstrap attention with a plain WAN DNS" "[]" \
		"$(rpc status | jq -c '[.attention[] | select(.code == "dns_bootstrap")]')"
	if poll 20 public_name_resolves; then ok "ssh full: tunnel DNS answers a public name"
	else nok "ssh full: tunnel DNS answers a public name" "$(C "dig +time=3 +tries=1 $PUBLIC_NAME A")"; fi
	# the first lookup through the tunnel also opens the DoH connection: poll, do not race it
	if poll 20 R "nslookup -port=5300 $PUBLIC_NAME 127.0.0.1 2>&1 | grep -q '^Name:'"; then
		ok "ssh full: xray's DNS inbound answers"
		measure "ssh full: xray DNS inbound answered within" "$POLL_MS ms"
	else
		nok "ssh full: xray's DNS inbound answers" "$(R "nslookup -port=5300 $PUBLIC_NAME 127.0.0.1 2>&1")"
	fi
	if poll 10 docker exec shadow-vpn sh -c 'ss -tnH state established dst 1.1.1.1 | grep -q ":443"'; then
		ok "ssh full: DoH to 1.1.1.1 leaves from the VPN server"
	else
		nok "ssh full: DoH to 1.1.1.1 leaves from the VPN server" "$(docker exec shadow-vpn ss -tn)"
	fi
	check_not "ssh full: ...and not from the router" "1.1.1.1:443" "$(R 'netstat -tn 2>/dev/null | grep ESTABLISHED')"
	check "ssh full: no dns_upstream_leak for per-domain servers" "[]" "$(rpc status | jq -c '[.attention[] | select(.code == "dns_upstream_leak")]')"

	echo "== stage1: SSH, full mode with the direct list"
	gen="$(applied_gen)"
	if direct_list on; then ok "ssh full: direct list fixture on"; else nok "ssh full: direct list fixture on" "store or list_set failed"; fi
	wait_up "$gen" "ssh full + direct list"
	check "ssh full: a direct-list name stays direct" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
	check "ssh full: other names still go through the tunnel" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	check "ssh full: the direct set is filled" "203.0.113.10" "$(R 'nft list set inet shadow_vpn direct4')"
	gen="$(applied_gen)"
	direct_list off
	poll 30 converged_since "$gen"

	echo "== stage1: dns_upstream_leak attention"
	gen="$(applied_gen)"
	# committed without a dnsmasq reload, so dnsmasq never really uses it
	R 'uci add_list dhcp.@dnsmasq[0].server=9.9.9.9; uci commit dhcp; /usr/libexec/shadow-vpn/job converge >/dev/null' >/dev/null
	poll 30 converged_since "$gen"
	check "ssh full: a plain UCI upstream raises dns_upstream_leak" "9.9.9.9" \
		"$(rpc status | jq -r '.attention[] | select(.code == "dns_upstream_leak") | .message')"
	gen="$(applied_gen)"
	R 'uci del_list dhcp.@dnsmasq[0].server=9.9.9.9; uci commit dhcp; /usr/libexec/shadow-vpn/job converge >/dev/null' >/dev/null
	poll 30 converged_since "$gen"
	check "ssh full: the attention goes once the upstream is removed" "[]" \
		"$(rpc status | jq -c '[.attention[] | select(.code == "dns_upstream_leak")]')"
}

# one profile per link in state/links.txt; name = the link's fragment (vmess: its "ps")
XRAY_LINKS="lab-reality-vision lab-xhttp-reality lab-vmess-ws lab-trojan-tls lab-hy2 lab-vless-kcp"

stage1_xray() {
	echo "== stage1: Xray, full mode, every link type"
	local out name sid gen r pid

	out="$(jq -n --rawfile t "$STATE/links.txt" '{text: $t, source: "import"}' |
		docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn profiles_import "$(cat)"')"
	check "xray: the six lab links import" "0" "$(printf '%s' "$out" | jq -r '.failed')"

	docker exec shadow-vpn sh -c ': > /tmp/xray-access.log' 2>/dev/null
	for name in $XRAY_LINKS; do
		sid="$(profile_sid "$name")"
		[ -n "$sid" ] || { nok "xray $name: profile exists" "no profile named $name"; continue; }
		gen="$(applied_gen)"
		pid="$(inst_pid xray)"
		r="$(rpc select "{\"transport\":\"xray\",\"sid\":\"$sid\"}")"
		check "xray $name: selected" "true" "$(printf '%s' "$r" | jq -r .ok)"
		wait_up "$gen" "xray $name" xray "$pid" || continue
		check "xray $name: status names the profile" "$name" "$(status_field .target.name)"
		check "xray $name: TCP goes through the tunnel" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
		check "xray $name: https (sniffed TLS) through the tunnel" "200" "$(C 'curl -sk -m 8 -o /dev/null -w %{http_code} https://tunnel.shadow.lab/')"
		check_udp "xray $name: UDP goes through the tunnel" 203.0.113.10:7777 "udp-src=203.0.113.20"
		check_ping "xray $name: ping works" 203.0.113.10
	done

	if poll 20 public_name_resolves; then ok "xray: tunnel DNS answers a public name"
	else nok "xray: tunnel DNS answers a public name" "$(C "dig +time=3 +tries=1 $PUBLIC_NAME A")"; fi
	if poll 10 docker exec shadow-vpn grep -q 'accepted tcp:1.1.1.1:443' /tmp/xray-access.log; then
		ok "xray: DoH to 1.1.1.1 went through the VPN server"
	else
		nok "xray: DoH to 1.1.1.1 went through the VPN server" "$(docker exec shadow-vpn tail -3 /tmp/xray-access.log)"
	fi
}

stage1_off_on() {
	echo "== stage1: Off and On"
	local r t0 probe gen

	start_dns_probe tunnel.shadow.lab
	t0=$(now_ms)
	r="$(enable false)"
	measure "off: set_enabled(false) job" "$(($(now_ms) - t0)) ms"
	check "off: set_enabled(false) job completes" '"state": "done"' "$r"
	poll 30 inactive
	check_off "off"
	probe="$(stop_dns_probe)"
	measure "off: DNS during Off (queries failed longest-gap-ms)" "$probe"
	if [ "$(echo "$probe" | awk '{ print ($3 < 10000) }')" = 1 ]; then ok "off: DNS never down for long"; else nok "off: DNS never down for long" "$probe"; fi
	check "off: status disconnected" "false disconnected" "$(rpc status | jq -r '"\(.enabled) \(.phase)"')"
	check "off: listed names resolve normally" "203.0.113.11" "$(C 'dig +short +time=2 +tries=2 tunnel.shadow.lab')"
	check "off: tunnel.shadow.lab is direct again" "$DIRECT_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	if poll 20 public_name_resolves; then ok "off: public names resolve"
	else nok "off: public names resolve" "$(C "dig +time=3 +tries=1 $PUBLIC_NAME A")"; fi

	gen="$(applied_gen)"
	start_dns_probe tunnel.shadow.lab
	t0=$(now_ms)
	r="$(enable true)"
	check "on: set_enabled(true) job completes" '"state": "done"' "$r"
	wait_up "$gen" "on again"
	probe="$(stop_dns_probe)"
	measure "on: DNS during On (queries failed longest-gap-ms)" "$probe"
	if [ "$(echo "$probe" | awk '{ print ($3 < 10000) }')" = 1 ]; then ok "on: DNS never down for long"; else nok "on: DNS never down for long" "$probe"; fi
	# the sets start empty after Off: dnsmasq fills them only when it runs with our file
	C 'dig +short +time=2 +tries=2 tunnel.shadow.lab' >/dev/null
	check "on: dnsmasq file in effect (the user set fills again)" "203.0.113.11" "$(R 'nft list set inet shadow_vpn user4')"
	check "on: tunnel.shadow.lab goes through the tunnel again" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
}

stage1() {
	stage1_ssh_split
	stage1_ssh_key
	stage1_ssh_pkcs8
	stage1_ssh_full
	stage1_xray
	stage1_off_on
}

# ---- stage 2 helpers: failure handling ------------------------------------------------------------------

V() { docker exec shadow-vpn sh -c "$1" 2>&1; }
W() { docker exec shadow-web sh -c "$1" 2>&1; }

# The VPN server goes away for the router: "drop" (unreachable, nothing answers) or "refuse" (TCP to the
# given port is reset at once, as when sshd or xray is stopped). An nft table on shadow-vpn (NET_ADMIN, up.sh).
vpn_block() {
	local rule="ip saddr 203.0.113.2 drop"
	[ "$1" = refuse ] && rule="ip saddr 203.0.113.2 tcp dport ${2:-22} reject with tcp reset"
	V "nft delete table inet lab_block 2>/dev/null; nft add table inet lab_block &&
	   nft add chain inet lab_block input '{ type filter hook input priority -10; policy accept; }' &&
	   nft add rule inet lab_block input $rule"
}
vpn_unblock() { V 'nft delete table inet lab_block 2>/dev/null; true' >/dev/null; }

# What http://<host>/ answers the LAN client: the echo line ("src=<ip> ..."), or rc=<curl exit code>
probe_http() { C "out=\$(curl -s -m ${2:-3} http://$1/); rc=\$?; [ -n \"\$out\" ] && echo \"\$out\" || echo rc=\$rc"; }
tunnelled() { probe_http "$1" | grep -qF "$TUNNEL_SRC"; }
goes_direct() { probe_http "$1" | grep -qF "$DIRECT_SRC"; }
# refused or cut at once (curl 7 refused, 52 empty reply, 56 reset), not a hang and not an answer
blocked_fast() { case "$(probe_http "$1" 2)" in rc=7|rc=52|rc=56) return 0 ;; esac; return 1; }
alive_is() { [ "$(status_field .tunnel.alive)" = "$1" ]; }
phase_code_is() { [ "$(rpc status | jq -r '"\(.phase) \(.code)"')" = "$1" ]; }
has_attention() { rpc status | jq -e --arg c "$1" '[.attention[] | select(.code == $c)] | length > 0' >/dev/null; }
gate_is() { [ "$(R "cat $RUN/gate 2>/dev/null" | tr -d '\n')" = "$1" ]; }
dns_conf() { R 'cat /tmp/dnsmasq.*.d/shadow-vpn.conf 2>/dev/null'; }
dns_via_tunnel() { dns_conf | grep -qx 'server=127.0.0.1#5300'; }
dns_normal() { dns_conf | grep -qx 'no-resolv' && ! dns_conf | grep -q '127.0.0.1#5300'; }
dnsmasq_up() { R 'pidof dnsmasq >/dev/null'; }
lan_dns_ok() { C 'dig +short +time=1 +tries=1 direct.shadow.lab' | grep -qx 203.0.113.10; }
lan_dhcp_ok() { C 'udhcpc -n -q -t 2 -T 1 -i eth0 -s /bin/true' >/dev/null; }
settled() { R "[ ! -e $RUN/pending ] && flock -n /var/lock/shadow-vpn.lock true" >/dev/null; }

# converge_after <what> <command...>: runs the change and waits until a converge applied it and settled
converge_after() {
	local what="$1" gen
	shift
	gen="$(applied_gen)"
	"$@" >/dev/null
	if poll 60 converged_since "$gen" && poll 30 settled; then return 0; fi
	nok "$what: converge applied" "$(rpc status | jq -c '{phase,message,attention}')"
	return 1
}

# a name no resolver has seen yet, and whether the lab ISP resolver got it from the router (= not tunnelled)
fresh_name() { echo "e2e-$1-$(date +%s)$RANDOM.example.com"; }
web_saw() { W "grep -c 'query\\[A\\] $1 from 203.0.113.2' /tmp/dnsmasq-web.log" | tr -d '\n'; }
# the name got an answer (a fresh name under example.com has no address: NOERROR/NXDOMAIN is an answer;
# a dead resolver path times out or fails)
answers() { C "dig +time=2 +tries=1 $1 A" | grep -qE 'status: (NOERROR|NXDOMAIN)'; }
doh_direct() { answers "$(fresh_name doh)"; R 'netstat -tn 2>/dev/null | grep -qE "203\.0\.113\.2:[0-9]+ +1\.1\.1\.1:443 +ESTABLISHED"'; }

rule_sid() { rpc rules | jq -r --arg t "$1" --arg v "$2" '.rules[] | select(.type == $t and .value == $v) | .sid' | head -1; }
rule_on() {
	local sid
	sid="$(rule_sid "$1" "$2")"
	if [ -n "$sid" ]; then rpc rule_set "{\"sid\":\"$sid\",\"enabled\":true}"; else rpc rule_add "{\"type\":\"$1\",\"value\":\"$2\"}"; fi
}
rule_off() {
	local sid
	for sid in $(rpc rules | jq -r --arg t "$1" --arg v "$2" '.rules[] | select(.type == $t and .value == $v) | .sid'); do
		rpc rule_delete "{\"sid\":\"$sid\"}"
	done
}

# select_wait <transport> <sid> <what>: select, then wait for the restarted instance and a live tunnel
select_wait() {
	local gen pid inst=xray key=xray_profile
	[ "$1" = ssh ] && inst=ssh key=ssh_server
	if [ "$(rpc status | jq -r --arg k "$key" '"\(.transport) \(.selected[$k])"')" = "$1 $2" ]; then
		if poll 60 tunnel_up; then ok "$3: connected, tunnel alive (already selected)"; return 0; fi
		nok "$3: connected, tunnel alive" "$(rpc status | jq -c '{phase,message,tunnel}')"
		return 1
	fi
	gen="$(applied_gen)"
	pid="$(inst_pid "$inst")"
	rpc select "{\"transport\":\"$1\",\"sid\":\"$2\"}" >/dev/null
	wait_up "$gen" "$3" "$inst" "$pid"
}

# set_main, and a converge of its own: reload_config does nothing when the values were set already
set_main_converge() { set_main "$@"; R "$LIBEXEC/job converge" >/dev/null; }

# observe <seconds> <command...>: the command holds every 2 s for that long (a window, not a race)
observe() {
	local end=$(($(now_ms) + $1 * 1000))
	shift
	while [ "$(now_ms)" -lt "$end" ]; do
		"$@" >/dev/null 2>&1 || return 1
		sleep 2
	done
}
inst_pid_is() { [ "$(inst_pid "$1")" = "$2" ]; }
no_ssh_process() { [ "$(ssh_procs)" = 0 ]; }

# main_wait <what> k=v...: Settings change (procd reload -> converge), then a live tunnel
main_wait() {
	local what="$1"
	shift
	converge_after "$what" set_main_converge "$@" || return 1
	if poll 60 tunnel_up; then return 0; fi
	nok "$what: connected, tunnel alive" "$(rpc status | jq -c '{phase,message,tunnel,attention}')"
	return 1
}

pw_server_save() {
	jq -n --arg sid "$1" --arg pw "$2" --arg fp "${3:-}" \
		'{sid: $sid, values: {name: "Lab password", host: "203.0.113.20", port: "22", username: "vpnuser", auth: "password",
		  keepalive: "15", fingerprint: $fp, note: ""}, password: $pw}' |
		docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn server_save "$(cat)"'
}
failed_passwords() { docker logs shadow-vpn 2>&1 | grep -c 'Failed password for vpnuser'; }

# An xray that rejects the running config, as after an upgrade to a version that does: a wrapper around the
# real binary that fails "run" (and "run -test") with xray's config-error exit code while the flag exists.
xray_rejecting() {
	R '[ -e /usr/bin/xray.real ] || cp -p /usr/bin/xray /usr/bin/xray.real' >/dev/null
	docker exec -i shadow-router sh -c 'cat > /usr/bin/xray.e2e && chmod 755 /usr/bin/xray.e2e && mv /usr/bin/xray.e2e /usr/bin/xray' <<'EOF'
#!/bin/sh
# e2e-shadow.sh stage2: an xray that rejects the running config while /tmp/e2e-xray-rejects exists
if [ -e /tmp/e2e-xray-rejects ] && [ "$1" = run ]; then
	echo "Failed to start: main: failed to load config files: [/var/run/shadow-vpn/xray.json] > infra/conf: e2e: this xray rejects the config" >&2
	exit 23
fi
exec /usr/bin/xray.real "$@"
EOF
	R 'touch /tmp/e2e-xray-rejects' >/dev/null
}
# xray-run's quick-exit count (RUN/xray.quick: <count> <uptime of the last start> <tested>) has run out
xray_quiet() { R "read -r q last t < $RUN/xray.quick && read -r up _ < /proc/uptime && [ \$((\${up%.*} - last)) -ge 31 ]" >/dev/null; }
xray_restore() { R '[ -e /usr/bin/xray.real ] && mv /usr/bin/xray.real /usr/bin/xray; rm -f /tmp/e2e-xray-rejects; true' >/dev/null; }

# Leftovers of an interrupted run; also the end of stage 2.
stage2_cleanup() {
	vpn_unblock
	xray_restore
	R 'f=$(ls /tmp/dnsmasq.*.d/zz-e2e.conf 2>/dev/null) && rm -f $f
	   [ "$(uci -q get dhcp.@dnsmasq[0].serversfile)" = /tmp/e2e-adblock.servers ] && { uci delete dhcp.@dnsmasq[0].serversfile; uci commit dhcp; reload_config; }
	   uci -q get firewall.e2e_pf >/dev/null && { uci delete firewall.e2e_pf; uci commit firewall; fw4 -q reload; }
	   true' >/dev/null
	# the original host keys of the VPN server (kept by the host-key swap)
	V '[ -d /etc/ssh/orig ] || exit 0
	   cmp -s /etc/ssh/orig/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key ||
	   { cp -p /etc/ssh/orig/ssh_host_* /etc/ssh/; kill -HUP $(pgrep -f "[/]usr/sbin/sshd -D"); }' >/dev/null
	rule_off ip 203.0.113.12 >/dev/null
	rule_off device 192.168.77.10 >/dev/null
	rule_off domain rollback-e2e.test >/dev/null
}

# ---- stage 2: failure handling ---------------------------------------------------------------------------

stage2_setup() {
	echo "== stage2: setup (lab servers, profiles and rule as stage1 leaves them)"
	stage2_cleanup
	ssh_servers
	local out
	out="$(jq -n --rawfile t "$STATE/links.txt" '{text: $t, source: "import"}' |
		docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn profiles_import "$(cat)"')"
	check "stage2: the lab links are there" "0" "$(printf '%s' "$out" | jq -r '.failed')"
	expect "stage2: domain rule tunnel.shadow.lab" domain_rule
	VISION_SID="$(profile_sid lab-reality-vision)"
	TROJAN_SID="$(profile_sid lab-trojan-tls)"
	[ "$(main_opt enabled)" = 1 ] || enable true >/dev/null
}

stage2_killswitch_xray() {
	echo "== stage2: kill switch, Xray (VLESS REALITY Vision), full mode, tunnel DNS, the server goes away"
	local t0 name r

	if direct_list on; then ok "kill switch xray: direct list fixture on"; else nok "kill switch xray: direct list fixture on" "store or list_set failed"; fi
	main_wait "kill switch xray: settings" mode=proxy-all tunnel_dns=1 kill_switch=1 ipv6=0 router_traffic=1
	select_wait xray "$VISION_SID" "kill switch xray: reality-vision" || return
	check "kill switch xray: tunnelled before" "$TUNNEL_SRC" "$(probe_http tunnel.shadow.lab)"

	vpn_block drop
	t0=$(now_ms)
	if poll 60 alive_is false; then
		ok "kill switch xray: the tunnel is seen dead"
		measure "kill switch xray: server unreachable -> tunnel.alive false" "$POLL_MS ms"
	else
		nok "kill switch xray: the tunnel is seen dead" "$(rpc status | jq -c .tunnel)"
	fi
	if poll 30 blocked_fast tunnel.shadow.lab; then
		ok "kill switch xray: tunnelled destinations are refused at once"
		measure "kill switch xray: server unreachable -> tunnelled connections refused at once" "$(($(now_ms) - t0)) ms"
	else
		nok "kill switch xray: tunnelled destinations are refused at once" "$(probe_http tunnel.shadow.lab)"
	fi
	[ "$(($(now_ms) - t0))" -le 30000 ] && ok "kill switch xray: detected within 30 s (target ~10 s)" ||
		nok "kill switch xray: detected within 30 s (target ~10 s)" "$(($(now_ms) - t0)) ms"
	check_not "kill switch xray: a tunnelled name never goes direct" "$DIRECT_SRC" \
		"$(probe_http tunnel.shadow.lab; probe_http tunnel.shadow.lab; probe_http 203.0.113.11)"
	check "kill switch xray: direct-list names keep working" "$DIRECT_SRC" "$(probe_http direct.shadow.lab)"
	check_ping "kill switch xray: ping keeps working" 203.0.113.11
	check_not "kill switch xray: tunnelled UDP gets no answer" "udp-src" "$(udp_c 203.0.113.11:7777)"
	check_not "kill switch xray: the router's own tunnelled traffic is blocked too" "src=" "$(R 'curl -s -m 3 http://tunnel.shadow.lab/')"
	name="$(fresh_name ks)"
	if answers "$name"; then nok "kill switch xray: a tunnelled name does not resolve" "$name got an answer"; else ok "kill switch xray: a tunnelled name does not resolve"; fi
	check "kill switch xray: ...and its lookup never reached the ISP resolver" "0" "$(web_saw "$name")"
	check "kill switch xray: lab names keep their per-domain resolver" "203.0.113.11" "$(C 'dig +short +time=2 +tries=1 tunnel.shadow.lab')"

	vpn_unblock
	t0=$(now_ms)
	if poll 90 tunnelled tunnel.shadow.lab; then
		ok "kill switch xray: the tunnel resumes on its own"
		measure "kill switch xray: server back -> tunnelled again" "$POLL_MS ms"
	else
		nok "kill switch xray: the tunnel resumes on its own" "$(probe_http tunnel.shadow.lab) $(rpc status | jq -c .tunnel)"
	fi
	poll 30 alive_is true && ok "kill switch xray: tunnel.alive true again" || nok "kill switch xray: tunnel.alive true again" "$(rpc status | jq -c .tunnel)"
	if poll 20 public_name_resolves; then ok "kill switch xray: tunnel DNS answers again"; else nok "kill switch xray: tunnel DNS answers again" "$(C "dig +time=3 +tries=1 $PUBLIC_NAME A")"; fi
}

stage2_fallback_xray() {
	echo "== stage2: fallback mode (kill switch off), Xray, the server goes away"
	local t0 name

	main_wait "fallback xray: kill switch off" kill_switch=0 || return
	check "fallback xray: xray falls back to direct" '"fallbackTag": "direct"' "$(R "grep fallbackTag $RUN/xray.json")"
	check "fallback xray: tunnelled before" "$TUNNEL_SRC" "$(probe_http tunnel.shadow.lab)"

	vpn_block drop
	if poll 60 goes_direct tunnel.shadow.lab; then
		ok "fallback xray: tunnelled destinations go direct"
		measure "fallback xray: server unreachable -> tunnelled destinations direct" "$POLL_MS ms"
	else
		nok "fallback xray: tunnelled destinations go direct" "$(probe_http tunnel.shadow.lab)"
	fi
	check_udp "fallback xray: tunnelled UDP goes direct" 203.0.113.11:7777 "udp-src=203.0.113.2"
	check "fallback xray: direct-list names keep working" "$DIRECT_SRC" "$(probe_http direct.shadow.lab)"
	# DNS for tunnelled names: xray's DoH follows the balancer, so it goes out directly from the router
	name="$(fresh_name fb)"
	if poll 20 answers "$name"; then ok "fallback xray: tunnelled names keep resolving"; else nok "fallback xray: tunnelled names keep resolving" "$(C "dig +time=3 +tries=1 $name A")"; fi
	if poll 15 doh_direct; then ok "fallback xray: ...through DoH from the router itself, not the tunnel"
	else nok "fallback xray: ...through DoH from the router itself, not the tunnel" "$(R 'netstat -tn 2>/dev/null | grep 1.1.1.1')"; fi
	check "fallback xray: lab names keep their per-domain resolver" "203.0.113.11" "$(C 'dig +short +time=2 +tries=1 tunnel.shadow.lab')"

	vpn_unblock
	if poll 90 tunnelled tunnel.shadow.lab; then
		ok "fallback xray: server back -> tunnelled again"
		measure "fallback xray: server back -> tunnelled again" "$POLL_MS ms"
	else
		nok "fallback xray: server back -> tunnelled again" "$(probe_http tunnel.shadow.lab)"
	fi
	check_udp "fallback xray: UDP tunnelled again" 203.0.113.11:7777 "udp-src=203.0.113.20"
}

stage2_xray_crash() {
	echo "== stage2: xray killed (kill -9) and an xray that rejects its config"
	local pid t0 out ms rc name starts ipid

	# kill -9 in fallback mode: procd brings it back within ~5 s, too soon for the gate to open
	pid="$(inst_pid xray)"
	R "kill -9 \$(pidof xray)" >/dev/null
	out="$(C 'curl -s -m 20 -o /dev/null -w "%{time_total}" http://tunnel.shadow.lab/; echo " rc=$?"')"
	ms="$(echo "$out" | awk '{ printf "%d", $1 * 1000 }')"
	rc="${out##*rc=}"
	measure "xray killed: a tunnelled connection fails after" "$ms ms (curl rc=$rc)"
	check "xray killed: tunnelled TCP is reset (connection refused)" "rc=7" "$out"
	[ "${ms:-99999}" -lt 3000 ] && ok "xray killed: no hang" || nok "xray killed: no hang" "$out"
	check "xray killed: tunnelled UDP is refused" "refused" "$(udp_c 203.0.113.11:7777)"
	t0=$(now_ms)
	if poll 60 inst_restarted xray "$pid" && poll 60 tunnelled tunnel.shadow.lab; then
		ok "xray killed: procd respawns it and the tunnel is back"
		measure "xray killed -> tunnelled again" "$(($(now_ms) - t0)) ms"
	else
		nok "xray killed: procd respawns it and the tunnel is back" "$(probe_http tunnel.shadow.lab) $(rpc status | jq -c '{phase,tunnel}')"
	fi
	expect "xray killed: the gate stayed closed (back within 10 s)" gate_is ""

	# a crash loop with a config xray rejects, fallback mode: fatal, no endless restarts, gate open. xray-run
	# counts quick exits within 30 s of a start: after a quiet half minute the loop starts from a clean count
	# (the gate then opens by the 10 s outage rule, ~15 s after the crash, before the fatal parks it)
	if poll 60 xray_quiet; then ok "xray rejects its config: xray's last start is 31 s old (clean quick-exit count)"
	else nok "xray rejects its config: xray's last start is 31 s old" "$(R "cat $RUN/xray.quick; cut -d' ' -f1 /proc/uptime")"; fi
	xray_rejecting
	log_mark crash-loop
	R "kill -9 \$(pidof xray xray.real)" >/dev/null
	t0=$(now_ms)
	if poll 60 gate_is accept; then
		ok "xray rejects its config: fallback mode opens the gate"
		measure "xray crash loop (fallback mode) -> gate open" "$POLL_MS ms"
	else
		nok "xray rejects its config: fallback mode opens the gate" "gate=$(R "cat $RUN/gate") $(rpc status | jq -c '{phase,message}')"
	fi
	if poll 60 has_attention xray_config; then
		ok "xray rejects its config: fatal attention"
		measure "xray crash loop -> fatal attention" "$(($(now_ms) - t0)) ms"
	else
		nok "xray rejects its config: fatal attention" "$(rpc status | jq -c '{phase,message,attention}')"
	fi
	check "xray rejects its config: error state with xray's reason" "error xray_config" "$(rpc status | jq -r '"\(.phase) \(.code)"')"
	check "xray rejects its config: ...in the message" "e2e: this xray rejects the config" "$(status_field .message)"
	if poll 30 goes_direct tunnel.shadow.lab; then ok "xray rejects its config: tunnelled destinations go direct"
	else nok "xray rejects its config: tunnelled destinations go direct" "$(probe_http tunnel.shadow.lab)"; fi
	if poll 30 dns_normal; then ok "xray rejects its config: dnsmasq switched to the normal upstream"
	else nok "xray rejects its config: dnsmasq switched to the normal upstream" "$(dns_conf | grep server=)"; fi
	measure "xray crash loop -> DNS on the normal upstream" "$(($(now_ms) - t0)) ms"
	name="$(fresh_name gate)"
	poll 20 answers "$name" && ok "xray rejects its config: tunnelled names resolve" || nok "xray rejects its config: tunnelled names resolve" "$name"
	check "xray rejects its config: ...through the normal upstream" "1" "$(web_saw "$name" | awk '{ print ($1 > 0) }')"
	ipid="$(inst_pid xray)"
	starts="$(R 'logread | grep -c "e2e: this xray rejects"')"
	if observe 30 inst_pid_is xray "$ipid"; then ok "xray rejects its config: the instance stays parked for 30 s"
	else nok "xray rejects its config: the instance stays parked for 30 s" "pid $ipid -> $(inst_pid xray)"; fi
	check "xray rejects its config: no restarts meanwhile" "0" "$(($(R 'logread | grep -c "e2e: this xray rejects"') - starts))"
	converge_after "xray rejects its config: a plain converge" R "$LIBEXEC/job converge" &&
		check "xray rejects its config: a plain converge keeps it parked, the error shown" "error xray_config $ipid" \
			"$(rpc status | jq -r '"\(.phase) \(.code)"') $(inst_pid xray)"

	# fixed (the old xray back), then Connect again
	R 'rm -f /tmp/e2e-xray-rejects' >/dev/null
	t0=$(now_ms)
	rpc set_enabled '{"enabled":true}' >/dev/null
	if poll 60 tunnelled tunnel.shadow.lab && poll 30 gate_is "" && poll 30 dns_via_tunnel; then
		ok "xray rejects its config: Connect again after the fix recovers (gate closed, tunnel DNS back)"
		measure "Connect again after the xray fatal -> tunnelled" "$(($(now_ms) - t0)) ms"
	else
		nok "xray rejects its config: Connect again after the fix recovers" "gate=$(R "cat $RUN/gate") $(rpc status | jq -c '{phase,message}')"
	fi
	poll 30 tunnel_up
	check "xray rejects its config: attention gone" "[]" "$(rpc status | jq -c '[.attention[] | select(.code == "xray_config")]')"
	xray_restore

	main_wait "xray crash: kill switch back on" kill_switch=1
}

stage2_quic() {
	local kind="${1:-vision}"
	echo "== stage2: QUIC (UDP 443) in $kind"
	case "$kind" in
	vision)
		check "quic vision: UDP 443 to a tunnelled address is rejected" "refused" "$(udp_c 203.0.113.11:443)"
		check_udp "quic vision: other UDP is tunnelled" 203.0.113.11:7777 "udp-src=203.0.113.20" ;;
	trojan)
		check_udp "quic trojan: UDP 443 is tunnelled (no Vision)" 203.0.113.11:443 "udp-src=203.0.113.20" ;;
	ssh)
		check "quic ssh: UDP 443 to a tunnelled address is rejected" "refused" "$(udp_c 203.0.113.11:443)" ;;
	esac
}

stage2_routing_edits() {
	echo "== stage2: routing edits while connected (Xray, split mode)"
	local pid lines

	direct_list off
	main_wait "edits: split mode" mode=selected-rules tunnel_dns=0 kill_switch=1 || return
	converge_after "edits: ip rule" rule_on ip 203.0.113.12
	poll 30 tunnelled 203.0.113.12
	check "edits: the domain rule tunnels its name" "$TUNNEL_SRC" "$(probe_http tunnel.shadow.lab)"
	check "edits: the IP rule tunnels its address" "$TUNNEL_SRC" "$(probe_http 203.0.113.12)"
	check "edits: other names stay direct" "$DIRECT_SRC" "$(probe_http direct.shadow.lab)"
	pid="$(inst_pid xray)"

	rule_off domain tunnel.shadow.lab >/dev/null
	if poll 30 goes_direct tunnel.shadow.lab; then ok "edits: a removed domain rule stops tunnelling"; measure "edits: domain rule removed -> direct" "$POLL_MS ms"
	else nok "edits: a removed domain rule stops tunnelling" "$(probe_http tunnel.shadow.lab)"; fi
	domain_rule >/dev/null
	if poll 30 tunnelled tunnel.shadow.lab; then ok "edits: an added domain rule tunnels at once"; measure "edits: domain rule added -> tunnelled" "$POLL_MS ms"
	else nok "edits: an added domain rule tunnels at once" "$(probe_http tunnel.shadow.lab)"; fi

	rule_off ip 203.0.113.12 >/dev/null
	if poll 30 goes_direct 203.0.113.12; then ok "edits: a removed IP rule stops tunnelling"; measure "edits: IP rule removed -> direct" "$POLL_MS ms"
	else nok "edits: a removed IP rule stops tunnelling" "$(probe_http 203.0.113.12)"; fi
	rule_on ip 203.0.113.12 >/dev/null
	if poll 30 tunnelled 203.0.113.12; then ok "edits: an added IP rule tunnels at once"; measure "edits: IP rule added -> tunnelled" "$POLL_MS ms"
	else nok "edits: an added IP rule tunnels at once" "$(probe_http 203.0.113.12)"; fi

	rule_on device 192.168.77.10 >/dev/null
	if poll 30 tunnelled direct.shadow.lab; then ok "edits: an added device rule tunnels the device"; measure "edits: device rule added -> tunnelled" "$POLL_MS ms"
	else nok "edits: an added device rule tunnels the device" "$(probe_http direct.shadow.lab)"; fi
	rule_off device 192.168.77.10 >/dev/null
	if poll 30 goes_direct direct.shadow.lab; then ok "edits: a removed device rule stops tunnelling"; measure "edits: device rule removed -> direct" "$POLL_MS ms"
	else nok "edits: a removed device rule stops tunnelling" "$(probe_http direct.shadow.lab)"; fi
	poll 30 settled
	check "edits: no xray restart for any of them" "$pid" "$(inst_pid xray)"
	converge_after "edits: ip rule off" rule_off ip 203.0.113.12

	# a profile switch restarts xray with the new outbound
	lines="$(V 'wc -l < /tmp/xray-access.log' | tr -d ' \n')"
	select_wait xray "$TROJAN_SID" "edits: profile switch to trojan" || return
	check "edits: the new outbound is trojan" '"protocol": "trojan"' "$(R "grep '\"protocol\": \"trojan\"' $RUN/xray.json")"
	check "edits: traffic uses it" "$TUNNEL_SRC" "$(probe_http tunnel.shadow.lab)"
	check "edits: ...the server sees the trojan inbound" "[trojan-tls" "$(V "tail -n +$((lines + 1)) /tmp/xray-access.log | grep 'tunnel.shadow.lab:80'")"
	stage2_quic trojan
	select_wait xray "$VISION_SID" "edits: profile switch back to reality-vision"
}

stage2_both_sets() {
	echo "== stage2: one address in both the proxy and the direct set"
	R 'ucode -e '"'"'import { store } from "shadow-vpn.lists"; store("proxy", [ "web.shadow.lab" ]); store("direct", [ "direct.shadow.lab" ]);'"'" >/dev/null
	converge_after "both sets: proxy list" rpc list_set '{"kind":"proxy","enabled":true}'
	converge_after "both sets: direct list" rpc list_set '{"kind":"direct","enabled":true}'
	C 'dig +short +time=2 +tries=1 web.shadow.lab; dig +short +time=2 +tries=1 direct.shadow.lab' >/dev/null
	check "both sets: 203.0.113.10 is in proxy4" "203.0.113.10" "$(R 'nft list set inet shadow_vpn proxy4')"
	check "both sets: ...and in direct4" "203.0.113.10" "$(R 'nft list set inet shadow_vpn direct4')"
	check "both sets: the shared address goes to the tunnel" "$TUNNEL_SRC" "$(probe_http direct.shadow.lab)"
	converge_after "both sets: proxy list off" rpc list_set '{"kind":"proxy","enabled":false}'
	direct_list off
	R 'rm -f /etc/shadow-vpn/lists/proxy.lst /etc/shadow-vpn/lists/proxy.sha256' >/dev/null
}

pf_ok() { W 'timeout 5 socat -T 2 - TCP:203.0.113.2:9000,bind=198.51.100.10,connect-timeout=3 </dev/null' | grep -q 'pf-peer=198.51.100.10'; }

stage2_port_forward() {
	echo "== stage2: a LAN port forward (WAN 9000 -> shadow-client:9000, peer shadow-web)"
	C 'netstat -lnt | grep -q ":9000 "' >/dev/null ||
		docker exec -d shadow-client sh -c 'socat TCP-LISTEN:9000,fork,reuseaddr SYSTEM:"echo pf-peer=\$SOCAT_PEERADDR"'
	R 'uci set firewall.e2e_pf=redirect; uci set firewall.e2e_pf.name=e2e-pf; uci set firewall.e2e_pf.src=wan
	   uci set firewall.e2e_pf.src_dport=9000; uci set firewall.e2e_pf.dest=lan; uci set firewall.e2e_pf.dest_ip=192.168.77.10
	   uci set firewall.e2e_pf.dest_port=9000; uci set firewall.e2e_pf.proto=tcp; uci set firewall.e2e_pf.target=DNAT
	   uci commit firewall; fw4 -q reload' >/dev/null

	main_wait "port forward: full mode" mode=proxy-all || return
	if poll 15 pf_ok; then ok "port forward: works in full mode"; else nok "port forward: works in full mode" "$(W 'timeout 5 socat -T 2 - TCP:203.0.113.2:9000,bind=198.51.100.10,connect-timeout=3 </dev/null 2>&1')"; fi
	converge_after "port forward: device rule" rule_on device 192.168.77.10
	if poll 15 pf_ok; then ok "port forward: works with a device rule for the client (full mode)"; else nok "port forward: works with a device rule for the client (full mode)" "no reply"; fi
	main_wait "port forward: split mode" mode=selected-rules
	check "port forward: the device rule tunnels the client" "$TUNNEL_SRC" "$(probe_http direct.shadow.lab)"
	if poll 15 pf_ok; then ok "port forward: works with a device rule (split mode)"; else nok "port forward: works with a device rule (split mode)" "no reply"; fi
	converge_after "port forward: device rule off" rule_off device 192.168.77.10
	R 'uci delete firewall.e2e_pf; uci commit firewall; fw4 -q reload' >/dev/null
}

stage2_dnsmasq() {
	echo "== stage2: dnsmasq with its own servers-file, and a DNS file dnsmasq rejects"
	local probe t0

	main_wait "dnsmasq: full mode, tunnel DNS" mode=proxy-all tunnel_dns=1 || return
	check_not "dnsmasq: our conf names no servers-file" "servers-file" "$(dns_conf)"
	# an ad blocker gives the instance its own servers-file while Shadow runs and restarts dnsmasq itself
	log_mark own-servers-file
	R 'echo "server=/adblock-e2e.test/203.0.113.10" > /tmp/e2e-adblock.servers; chmod 644 /tmp/e2e-adblock.servers
	   uci set dhcp.@dnsmasq[0].serversfile=/tmp/e2e-adblock.servers; uci commit dhcp; /etc/init.d/dnsmasq restart' >/dev/null 2>&1
	if poll 20 lan_dns_ok; then ok "dnsmasq: starts with its own servers-file next to ours"; else nok "dnsmasq: starts with its own servers-file next to ours" "$(R 'logread | grep dnsmasq | tail -3')"; fi
	check_not "dnsmasq: no repeated-keyword refusal" "repeated" "$(since_mark "$LOG_MARK" | grep dnsmasq)"
	expect "dnsmasq: its servers-file is in use" R 'grep -q "^servers-file=/tmp/e2e-adblock.servers" /var/etc/dnsmasq.conf.*'
	check "dnsmasq: tunnelled traffic still tunnelled" "$TUNNEL_SRC" "$(probe_http tunnel.shadow.lab)"
	if poll 20 public_name_resolves; then ok "dnsmasq: tunnel DNS still answers"; else nok "dnsmasq: tunnel DNS still answers" "no answer"; fi
	converge_after "dnsmasq: converge with it (reload trigger on dhcp)" R 'reload_config'
	if poll 20 lan_dns_ok; then ok "dnsmasq: still up after our converge"; else nok "dnsmasq: still up after our converge" "no answer"; fi
	R 'uci delete dhcp.@dnsmasq[0].serversfile; uci commit dhcp; reload_config' >/dev/null
	poll 20 lan_dns_ok

	# a conf-dir file of the user's that clashes with ours: dnsmasq refuses to start with both
	R 'echo max-ttl=600 > $(ls -d /tmp/dnsmasq.*.d | head -1)/zz-e2e.conf' >/dev/null
	start_dns_probe direct.shadow.lab
	t0=$(now_ms)
	rpc rule_add '{"type":"domain","value":"rollback-e2e.test"}' >/dev/null
	if poll 60 has_attention dns_rejected; then
		ok "dnsmasq rejected: attention dns_rejected"
		measure "dnsmasq rejected -> rolled back" "$(($(now_ms) - t0)) ms"
	else
		nok "dnsmasq rejected: attention dns_rejected" "$(rpc status | jq -c '{phase,message,attention}')"
	fi
	probe="$(stop_dns_probe)"
	measure "dnsmasq rejected: LAN DNS during the rollback (queries failed longest-gap-ms)" "$probe"
	if [ "$(echo "$probe" | awk '{ print ($3 < 15000) }')" = 1 ]; then ok "dnsmasq rejected: DNS back within seconds"; else nok "dnsmasq rejected: DNS back within seconds" "$probe"; fi
	# the rollback raises the attention, then the converge to off tears down and restarts dnsmasq again
	poll 30 settled
	expect_soon 15 "dnsmasq rejected: dnsmasq runs" dnsmasq_up
	if poll 15 lan_dns_ok; then ok "dnsmasq rejected: LAN DNS answers"; else nok "dnsmasq rejected: LAN DNS answers" "no answer"; fi
	if poll 20 lan_dhcp_ok; then ok "dnsmasq rejected: LAN DHCP answers"; else nok "dnsmasq rejected: LAN DHCP answers" "no lease"; fi
	expect_soon 30 "dnsmasq rejected: our file is gone" R '! ls /tmp/dnsmasq.*.d/shadow-vpn.conf >/dev/null 2>&1'
	expect_soon 30 "dnsmasq rejected: the data plane is torn down" R '! nft list table inet shadow_vpn >/dev/null 2>&1'
	check "dnsmasq rejected: error state says why" "DNS configuration rejected" "$(status_field .message)"
	check "dnsmasq rejected: direct traffic unaffected" "$DIRECT_SRC" "$(probe_http direct.shadow.lab)"

	R 'rm -f /tmp/dnsmasq.*.d/zz-e2e.conf' >/dev/null
	rule_off domain rollback-e2e.test >/dev/null
	local gen
	gen="$(applied_gen)"
	rpc set_enabled '{"enabled":true}' >/dev/null
	wait_up "$gen" "dnsmasq rejected: Connect again once the clash is gone"
	check "dnsmasq rejected: tunnelled again" "$TUNNEL_SRC" "$(probe_http tunnel.shadow.lab)"
}

# log_mark <name>: a unique line in logd (logread keeps earlier runs); since_mark <mark>: the lines after it
log_mark() { LOG_MARK="e2e-shadow-$1-$(date +%s)-$RANDOM"; R "logger -t e2e-shadow $LOG_MARK" >/dev/null; }
since_mark() { R "logread | sed -n '/ $1\$/,\$p'"; }
ssh_backoff_at_least() { since_mark "$1" | grep -qE 'Reconnecting in (3[2-9]|[4-6][0-9]) s'; }
ssh_procs() { R 'pidof ssh-openssh | wc -w' | tr -d ' \n'; }

stage2_ssh() {
	echo "== stage2: SSH failures (password server, split mode)"
	local sid t0 f0 ipid seen i fp gen

	sid="$(server_sid 'Lab password')"
	main_wait "ssh: split mode" mode=selected-rules tunnel_dns=0 kill_switch=1
	select_wait ssh "$sid" "ssh: Lab password" || return

	# a change that rewrites only xray.json (kill switch, IPv6, log level) restarts xray alone: ssh keeps
	# its session, and the phase stays Connected (main_wait polls for it) instead of a "Connecting…" that
	# only the next ssh-up would end
	ipid="$(inst_pid ssh)"
	main_wait "ssh: kill switch off, ssh session kept" kill_switch=0 || return
	same "ssh: an xray-only change does not restart ssh" "$ipid" "$(inst_pid ssh)"
	check "ssh: ...and the tunnel check is offered (phase connected)" "connected" "$(status_field .phase)"
	main_wait "ssh: kill switch back on" kill_switch=1 || return

	# kill switch: sshd refuses (stopped)
	vpn_block refuse 22
	t0=$(now_ms)
	if poll 60 alive_is false; then ok "ssh kill switch: the tunnel is seen dead"; measure "ssh: sshd refusing -> tunnel.alive false" "$POLL_MS ms"
	else nok "ssh kill switch: the tunnel is seen dead" "$(rpc status | jq -c .tunnel)"; fi
	if poll 30 blocked_fast tunnel.shadow.lab; then ok "ssh kill switch: tunnelled destinations are refused at once"
	else nok "ssh kill switch: tunnelled destinations are refused at once" "$(probe_http tunnel.shadow.lab)"; fi
	check_not "ssh kill switch: never direct" "$DIRECT_SRC" "$(probe_http tunnel.shadow.lab; probe_http 203.0.113.11)"
	check "ssh kill switch: direct names keep working" "$DIRECT_SRC" "$(probe_http direct.shadow.lab)"
	# ssh-run writes "connecting" for the moment before each refused attempt: poll, do not sample once
	expect_soon 30 "ssh kill switch: reconnecting" phase_is reconnecting
	observe 10 true    # let the outage last a while, so ssh backs off
	vpn_unblock
	if poll 120 tunnelled tunnel.shadow.lab; then ok "ssh kill switch: server back -> the tunnel resumes on its own"; measure "ssh: sshd back after ~15 s -> tunnelled again" "$POLL_MS ms (ssh backoff + observatory)"
	else nok "ssh kill switch: server back -> the tunnel resumes on its own" "$(rpc status | jq -c '{phase,message,tunnel}')"; fi

	# WAN up reconnects at once instead of waiting out the backoff
	log_mark backoff
	vpn_block refuse 22
	if poll 180 ssh_backoff_at_least "$LOG_MARK"; then
		ok "wan up: ssh backed off to 32 s or more"
		vpn_unblock
		t0=$(now_ms)
		R 'ifup wan' >/dev/null
		if poll 60 phase_is connected; then
			ok "wan up: ssh reconnects"
			measure "wan up: ifup wan -> ssh connected" "$POLL_MS ms (the backoff left was 30 s or more)"
			[ "$POLL_MS" -lt 20000 ] && ok "wan up: at once, not after the backoff" || nok "wan up: at once, not after the backoff" "$POLL_MS ms"
		else
			nok "wan up: ssh reconnects" "$(rpc status | jq -c '{phase,message}')"
		fi
		if poll 60 tunnelled tunnel.shadow.lab; then measure "wan up: ifup wan -> tunnelled" "$(($(now_ms) - t0)) ms"; else nok "wan up: tunnelled again" "$(probe_http tunnel.shadow.lab)"; fi
	else
		nok "wan up: ssh backed off to 32 s or more" "$(R 'logread | grep "Reconnecting in" | tail -2')"
	fi
	vpn_unblock
	poll 60 tunnel_up

	# a wrong password: fatal at the first rejection, nothing retries
	f0="$(failed_passwords)"
	t0=$(now_ms)
	pw_server_save "$sid" "wrong-$(date +%s)" >/dev/null
	if poll 60 phase_code_is "error auth"; then ok "ssh wrong password: fatal error state"; measure "ssh wrong password -> error" "$POLL_MS ms"
	else nok "ssh wrong password: fatal error state" "$(rpc status | jq -c '{phase,code,message}')"; fi
	check "ssh wrong password: the desktop's message" "SSH authentication failed: password auth rejected" "$(status_field .message)"
	expect "ssh wrong password: attention ssh_fatal" has_attention ssh_fatal
	ipid="$(inst_pid ssh)"
	if observe 60 no_ssh_process; then ok "ssh wrong password: no ssh process for a minute"
	else nok "ssh wrong password: no ssh process for a minute" "$(R 'ps | grep [s]sh-openssh')"; fi
	check "ssh wrong password: one attempt only" "1" "$(($(failed_passwords) - f0))"
	check "ssh wrong password: the instance stays parked" "$ipid" "$(inst_pid ssh)"
	converge_after "ssh wrong password: a plain converge" R "$LIBEXEC/job converge" &&
		check "ssh wrong password: a plain converge does not retry, the error stays shown" "error auth 1" \
			"$(rpc status | jq -r '"\(.phase) \(.code)"') $(($(failed_passwords) - f0))"
	pw_server_save "$sid" "$(cat "$STATE/ssh.pw")" >/dev/null
	t0=$(now_ms)
	rpc set_enabled '{"enabled":true}' >/dev/null
	if poll 60 tunnelled tunnel.shadow.lab; then ok "ssh wrong password: fixed + Connect again works"; measure "ssh: password fixed, Connect again -> tunnelled" "$POLL_MS ms"
	else nok "ssh wrong password: fixed + Connect again works" "$(rpc status | jq -c '{phase,message}')"; fi
	poll 30 tunnel_up
	check "ssh wrong password: attention gone once connected" "[]" "$(rpc status | jq -c '[.attention[] | select(.code == "ssh_fatal")]')"

	# the server's host key changes: refused with the mismatch; "Pin this key" then works
	# pgrep patterns in brackets, so they never match this shell's own command line
	V 'mkdir -p /etc/ssh/orig; [ -e /etc/ssh/orig/ssh_host_ed25519_key ] || cp -p /etc/ssh/ssh_host_* /etc/ssh/orig/
	   rm -f /etc/ssh/ssh_host_*; ssh-keygen -A >/dev/null; kill -HUP $(pgrep -f "[/]usr/sbin/sshd -D")
	   for p in $(pgrep -f "[s]shd-session: vpnuser"); do kill $p; done' >/dev/null
	fp="$(V 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' | awk '{ print $2 }')"
	if poll 60 phase_code_is "error hostkey"; then ok "ssh host key changed: refused, fatal"
	else nok "ssh host key changed: refused, fatal" "$(rpc status | jq -c '{phase,code,message}')"; fi
	check "ssh host key changed: the mismatch message" "SSH server host key does not match the key Shadow trusted" "$(status_field .message)"
	check "ssh host key changed: names the new fingerprint" "$fp" "$(status_field .message)"
	check "ssh host key changed: status.hostkey shows it" "changed $fp" "$(rpc status | jq -r '"\(.hostkey.kind) \(.hostkey.got)"')"
	check_not "ssh host key changed: never direct" "$DIRECT_SRC" "$(probe_http tunnel.shadow.lab)"
	t0=$(now_ms)
	# the page passes the fingerprint it showed; a key seen after that is not pinned in its place
	pin_args="$(jq -nc --arg s "$sid" '{sid: $s, fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}')"
	check "ssh host key changed: a fingerprint the page did not show is not pinned" "The server key changed since this page was loaded" \
		"$(rpc hostkey_pin "$pin_args" | jq -r .error)"
	pin_args="$(jq -nc --arg s "$sid" --arg f "$fp" '{sid: $s, fingerprint: $f}')"
	check "ssh host key changed: Pin this key" "$fp" "$(rpc hostkey_pin "$pin_args" | jq -r .fingerprint)"
	if poll 60 tunnelled tunnel.shadow.lab; then ok "ssh host key changed: connects with the pinned key"; measure "ssh: Pin this key (rpc included) -> tunnelled" "$(($(now_ms) - t0)) ms"
	else nok "ssh host key changed: connects with the pinned key" "$(rpc status | jq -c '{phase,message}')"; fi
	check "ssh host key changed: the new key is trusted" "$fp" "$(rpc servers | jq -r --arg s "$sid" '.servers[] | select(.sid == $s) | .hostkey.trusted.fingerprint')"
	# the lab's own key back, and trust on first use again for later stages
	V 'cp -p /etc/ssh/orig/ssh_host_* /etc/ssh/; kill -HUP $(pgrep -f "[/]usr/sbin/sshd -D")' >/dev/null
	gen="$(applied_gen)"
	pw_server_save "$sid" "$(cat "$STATE/ssh.pw")" "" >/dev/null
	poll 60 converged_since "$gen"
	if poll 60 tunnelled tunnel.shadow.lab && poll 30 tunnel_up; then ok "ssh host key: pin cleared, the original key trusted again"
	else nok "ssh host key: pin cleared, the original key trusted again" "$(rpc status | jq -c '{phase,message}')"; fi

	stage2_quic ssh
}

heal_ok() {
	R 'nft list chain inet shadow_vpn gate >/dev/null 2>&1 && ip rule | grep -q "lookup 106" &&
	   ip route show table 106 | grep -q "^local default" && nft list set inet shadow_vpn server4 | grep -q 203.0.113.20' >/dev/null &&
		tunnelled tunnel.shadow.lab &&
		R 'nft list set inet shadow_vpn user4' | grep -q 203.0.113.11
}

stage2_heal() {
	echo "== stage2: healing after firewall and network restarts (SSH, split mode)"
	local cmd name

	for cmd in 'fw4 reload' '/etc/init.d/firewall stop; /etc/init.d/firewall start' '/etc/init.d/network restart'; do
		name="heal ($cmd)"
		R "$cmd" >/dev/null 2>&1
		if poll 60 heal_ok; then
			ok "$name: table, rules, local route, server address and dnsmasq sets back; tunnelled again"
			measure "$name -> healed" "$POLL_MS ms"
		else
			nok "$name: healed" "$(R 'nft list chain inet shadow_vpn gate >/dev/null 2>&1 && echo table || echo no-table; ip rule | grep -c "lookup 106"; ip route show table 106') $(probe_http tunnel.shadow.lab)"
		fi
		check "$name: direct traffic fine" "$DIRECT_SRC" "$(probe_http direct.shadow.lab)"
		poll 30 tunnel_up
	done
}

# The state stage1 leaves, for the next stage: Xray lab-vless-kcp, full mode, tunnel DNS, kill switch.
stage2_end() {
	echo "== stage2: back to the stage1 end state"
	stage2_cleanup
	direct_list off
	main_wait "end: full mode, tunnel DNS, kill switch" mode=proxy-all tunnel_dns=1 kill_switch=1 ssh_udp=reject ipv6=0
	select_wait xray "$(profile_sid lab-vless-kcp)" "end: lab-vless-kcp"
	check "end: tunnelled" "$TUNNEL_SRC" "$(probe_http tunnel.shadow.lab)"
	check "end: no attention left" "[]" "$(rpc status | jq -c '[.attention[].code]')"
}

stage2() {
	stage2_setup
	stage2_killswitch_xray
	stage2_fallback_xray
	stage2_xray_crash
	stage2_quic vision
	stage2_routing_edits
	stage2_both_sets
	stage2_port_forward
	stage2_dnsmasq
	stage2_ssh
	stage2_heal
	stage2_end
}

# ---- stage 3 helpers: boot, upgrade, removal, LuCI -----------------------------------------------------

BOOT_MARK=/tmp/e2e-boot-done
LAB_SECRETS="ssh.pw trojan.pw hy2.pw uuid"
# every method of luci.shadow-vpn (CONTRACTS.md §9), sorted; stage3_luci calls each of them
LUCI_METHODS="attention_dismiss check hostkey_forget hostkey_pin job_status key_delete key_save key_show keys leases list_refresh \
list_set list_view lists logs logs_clear profile_delete profile_link profile_pin profile_rename profiles profiles_delete_unpinned \
profiles_import rule_add rule_delete rule_set rules rules_export rules_import select server_delete server_save servers \
set_enabled settings_set status update_check update_install update_status "

# same <name> <want> <got>: exact equality, and <want> must not be empty
same() { if [ -n "$2" ] && [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "want '$2', got '$3'"; fi; }

host_md5() { md5 -q "$1" 2>/dev/null || md5sum < "$1" | cut -c1-32; }

# push <host file> <router path> <mode>: streamed (docker cp cannot see procd's /tmp; bind mounts go stale)
push() { docker exec -i shadow-router sh -c 'cat > "$1.e2e" && chmod "$2" "$1.e2e" && mv "$1.e2e" "$1"' _ "$2" "$3" < "$1"; }

installed_version() { R 'apk list -I shadow-vpn 2>/dev/null' | sed -n 's/^shadow-vpn-\([^ ]*\) .*/\1/p'; }
next_version() { local v; v="$(cat "$TREE/build/VERSION")"; echo "${v%.*}.$((${v##*.} + 1))"; }
main_is() { [ "$(main_opt "$1")" = "$2" ]; }

# install_sh <dir> [--uninstall]: the real way: the lab package server serves <dir> and install.sh, the router
# fetches install.sh and runs it. INSTALL_OUT = its output (ends with rc=<exit code>), INSTALL_MS = run time.
install_sh() {
	local dir="$1" t0
	shift
	INSTALL_OUT="the package server did not start"
	pkgsrv_start "$dir" || { pkgsrv_stop; return 1; }
	t0=$(now_ms)
	INSTALL_OUT="$(R "wget -q -O /tmp/install.sh $BASE_URL/install.sh && SHADOW_BASE_URL=$BASE_URL sh /tmp/install.sh $* </dev/null; echo rc=\$?")"
	INSTALL_MS=$(($(now_ms) - t0))
	pkgsrv_stop
}

dhcp_state() { R 'uci -q show dhcp.@dnsmasq[0] | sort'; }

# shadow_on <what>: Shadow is turned on (from off when it was on) and connects
shadow_on() {
	local gen r
	if main_is enabled 1; then
		enable false >/dev/null
		poll 30 inactive
	fi
	gen="$(applied_gen)"
	r="$(enable true)"
	check "$1: set_enabled(true) completes" '"state": "done"' "$r"
	wait_up "$gen" "$1: Shadow on"
}

# A lab-only init script that marks the end of the boot sequence: procd's rcS runs init scripts one at a
# time in name order, so the last S99 one runs after every other (Shadow's S95 included).
boot_marker() {
	docker exec -i shadow-router sh -c 'cat > /etc/init.d/zz-e2e-boot && chmod 755 /etc/init.d/zz-e2e-boot && /etc/init.d/zz-e2e-boot enable' <<'EOS'
#!/bin/sh /etc/rc.common
# e2e-shadow.sh stage3 (lab only): the last S99 script, so it marks the end of the boot sequence
START=99
boot() {
	touch /tmp/e2e-boot-done
}
start() {
	:
}
EOS
}

booted() { R "[ -e $BOOT_MARK ] && pidof dnsmasq >/dev/null && pidof rpcd >/dev/null && pidof uhttpd >/dev/null" >/dev/null; }

# power_cycle <what>: the router loses power and boots again (docker kill + docker start: no userland shutdown
# runs at all). Never a graceful one: OpenWrt's K90umount remounts the Docker host's shared cgroup2 read-only, and
# then no container can start or be exec'd until that host (OrbStack's VM, a Linux machine) restarts
# (tests/lab/README.md).
power_cycle() {
	local t0
	if R 'ls /etc/rc.d/K*umount' >/dev/null 2>&1; then
		nok "$1: power cycle" "K90umount is enabled on the router (lab from an older up.sh): refusing"
		return 1
	fi
	R sync >/dev/null
	t0=$(now_ms)
	if ! docker kill shadow-router >/dev/null 2>&1 || ! docker start shadow-router >/dev/null 2>&1; then
		nok "$1: power cycle" "docker kill/start failed: $(docker ps -a --filter name=shadow-router --format '{{.Status}}')"
		return 1
	fi
	if poll 120 booted; then
		measure "$1: power on -> boot sequence done" "$(($(now_ms) - t0)) ms"
		return 0
	fi
	nok "$1: the router boots again" "$(docker ps -a --filter name=shadow-router --format '{{.Status}}')"
	return 1
}

# /etc/config/shadow-vpn and every file under /etc/shadow-vpn, with their md5 (no contents)
etc_sums() { R 'cd / && md5sum etc/config/shadow-vpn $(find etc/shadow-vpn -type f | sort)'; }
etc_secret_sums() { R 'cd / && md5sum $(find etc/shadow-vpn -type f | sort)'; }

REPO="$(sed -n 's/^REPO=//p' "$TREE/install.sh")"
UPDATE_LOCK=/var/lock/shadow-vpn-update.lock
# the updater's record of its automatic attempts (flash), the one file under /etc/shadow-vpn an update may write
UPDATE_AUTO=/etc/shadow-vpn/update.state

host_sha256() { { sha256sum < "$1" 2>/dev/null || shasum -a 256 < "$1"; } | cut -c1-64; }

# release_json <dir> <version>: <dir>/release.json in the shape of GitHub's release API, with the fields the updater
# reads (tag_name, html_url, published_at, body, assets[].name/url/size/digest), for SHA256SUMS and the files it
# lists. Under a base URL the updater keeps html_url only below that URL and takes every file from the base URL,
# never from the assets' API urls.
release_json() {
	local dir="$1" v="$2" f n=0
	for f in SHA256SUMS $(awk '{ print $2 }' "$dir/SHA256SUMS"); do
		n=$((n + 1))
		jq -n --arg name "$f" --arg url "https://api.github.com/repos/$REPO/releases/assets/$((900000 + n))" \
			--argjson size "$(wc -c < "$dir/$f" | tr -d ' ')" --arg digest "sha256:$(host_sha256 "$dir/$f")" \
			'{name: $name, url: $url, size: $size, digest: $digest, state: "uploaded"}'
	done | jq -s --arg v "$v" --arg page "$BASE_URL/releases/tag/$v" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{tag_name: $v, name: $v, html_url: $page, draft: false, prerelease: false, published_at: $at,
		  body: "Lab release \($v).", assets: .}' > "$dir/release.json"
}

# broken_build <version> <out dir>: a build of this tree whose xray never starts (its xray-run exits at once), and
# nothing else changed: its init script declares the same instances, so procd keeps the xray that runs over the
# package's post-install, and only the updater's own restart of the instances (DESIGN.md 11.1) runs the new code.
broken_build() {
	local src rc
	src="$(mktemp -d "${TMPDIR:-/tmp}/shv-e2e-broken.XXXXXX")" || return 1
	cp -R "$TREE/build" "$TREE/shadow-vpn" "$TREE/luci-app-shadow-vpn" "$src/" &&
		printf '#!/bin/sh\n# e2e-shadow.sh stage3 update: a broken build, its xray never starts\nexit 1\n' \
			> "$src/shadow-vpn/files/usr/libexec/shadow-vpn/xray-run" &&
		OUT="$2" "$src/build/mk_apk.sh" "$1"
	rc=$?
	rm -rf "$src"
	return "$rc"
}

# Leftovers of an interrupted stage3_update, also its end: the package server, the base URL hook, the updater's
# state (a new run builds the same versions: an announced version would raise no banner, an automatic attempt
# would count on) and its banners, the log level it raised; cron runs again.
update_cleanup() {
	pkgsrv_stop
	R "rm -rf $RUN/update.base_url $RUN/update.json $RUN/update.run.json $RUN/update.work $UPDATE_AUTO
	   /etc/init.d/cron start" >/dev/null
	rpc attention_dismiss '{"id":"update_available"}' >/dev/null
	rpc attention_dismiss '{"id":"update_failed"}' >/dev/null
	if [ "$(main_opt log_level)" != warning ]; then
		set_main log_level=warning
		poll 30 settled
	fi
}

# the instance's pid in procd (empty while it does not run)
instance_pid() { R "ubus call service list '{\"name\":\"shadow-vpn\"}'" | jq -r ".[\"shadow-vpn\"].instances.$1.pid // empty" 2>/dev/null; }

# the update lock is free, no run file, no work dir
update_idle() { R "flock -n $UPDATE_LOCK true && [ ! -e $RUN/update.run.json ] && [ ! -e $RUN/update.work ]"; }

# check_lan_direct <what>: Shadow is off and the LAN works without it (DNS, the web directly)
check_lan_direct() {
	if poll 20 lan_dns_ok; then ok "$1: LAN DNS answers"; else nok "$1: LAN DNS answers" "no answer"; fi
	check "$1: the LAN reaches the web directly" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
}

# What a removal must leave: our packages gone, the router and the LAN fine.
removed_checks() {
	expect "$1: our packages are gone" R '! apk info -e shadow-vpn && ! apk info -e luci-app-shadow-vpn && ! apk info -e luci-i18n-shadow-vpn-ru'
	expect "$1: dnsmasq-full stays" R 'apk info -e dnsmasq-full && dnsmasq --version | grep -q nftset'
	expect "$1: nft table, policy rules and our dnsmasq file gone" \
		R '! nft list table inet shadow_vpn >/dev/null 2>&1 && ! ip rule | grep -q "lookup 106" && ! ls /tmp/dnsmasq.*.d/shadow-vpn.conf >/dev/null 2>&1'
	expect "$1: no procd instances of ours" R '! ubus call service list "{\"name\":\"shadow-vpn\"}" | grep -q "\"running\": true"'
	# the pre-deinstall teardown must not declare the service again (its triggers would call removed files)
	expect "$1: the procd service and its triggers are gone" R '! ubus call service list "{\"name\":\"shadow-vpn\"}" 2>/dev/null | grep -q "\"shadow-vpn\""'
	expect "$1: fw4 include and the chain-pre accept rule gone" \
		R '! uci -q get firewall.shadow_vpn && ! nft list chain inet fw4 input | grep -q "0x00400000"'
	expect "$1: cron line gone" R '! crontab -l 2>/dev/null | grep -q shadow-vpn'
	expect "$1: LuCI files gone" R '[ ! -e /www/luci-static/resources/view/shadow-vpn/overview.js ] &&
		[ ! -e /usr/share/luci/menu.d/luci-app-shadow-vpn.json ] && [ ! -e /usr/share/rpcd/ucode/luci.shadow-vpn ]'
	expect "$1: settings kept" R '[ "$(uci -q get shadow-vpn.main)" = shadow ] && [ -d /etc/shadow-vpn/secrets ]'
	expect "$1: the router resolves" R 'nslookup direct.shadow.lab 127.0.0.1 | grep -q 203.0.113.10'
	if poll 15 lan_dns_ok; then ok "$1: LAN DNS answers"; else nok "$1: LAN DNS answers" "no answer"; fi
	if poll 20 lan_dhcp_ok; then ok "$1: LAN DHCP answers"; else nok "$1: LAN DHCP answers" "no lease"; fi
	check "$1: the LAN reaches the web directly" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
	check_ping "$1: LAN ping works" 203.0.113.10
}

# ---- stage 3: boot, upgrade, removal, LuCI -------------------------------------------------------------

stage3_setup() {
	echo "== stage3: setup (Shadow from out/ installed and off, lab servers and profiles)"
	local v out
	stage2_cleanup
	# the lab never runs OpenWrt's K90umount (README); a router from an older up.sh still has it
	if R 'ls /etc/rc.d/K*umount' >/dev/null 2>&1; then
		R '/etc/init.d/umount disable; rm -f /etc/rc.d/K*umount' >/dev/null
		note "disabled K90umount on the router (it came from an older up.sh)"
	fi
	# an interrupted stage3 may have left Shadow removed or a newer build installed
	v="$(cat "$TREE/build/VERSION")-r1"
	if [ "$(installed_version)" != "$v" ]; then
		note "installed: '$(installed_version)', out/ has $v: installing out/"
		[ -n "$(installed_version)" ] && install_sh "$TREE/out" --uninstall
		install_sh "$TREE/out"
		check "stage3: Shadow $v installed from out/" "rc=0" "$INSTALL_OUT"
	fi
	update_cleanup
	if main_is enabled 1; then
		enable false >/dev/null
		poll 30 inactive
	fi
	ssh_servers
	out="$(jq -n --rawfile t "$STATE/links.txt" '{text: $t, source: "import"}' |
		docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn profiles_import "$(cat)"')"
	check "stage3: the lab links are there" "0" "$(printf '%s' "$out" | jq -r '.failed')"
	expect "stage3: domain rule tunnel.shadow.lab" domain_rule
	direct_list off
	v="{\"transport\":\"xray\",\"sid\":\"$(profile_sid lab-vless-kcp)\"}"
	rpc select "$v" >/dev/null
	set_main mode=proxy-all tunnel_dns=1 kill_switch=1 ipv6=0 router_traffic=1 ssh_udp=reject autostart=1 update=notify
	poll 30 settled
	expect "stage3: boot marker installed" boot_marker
	DHCP_BEFORE="$(dhcp_state)"
}

stage3_boot() {
	echo "== stage3: init script (restart, reload) and boot (power cuts): autostart, an interrupted Off, autostart=0"
	local gen

	# 0) restart and reload through the init script keep Shadow on and connected
	shadow_on "boot" || return
	gen="$(applied_gen)"
	R '/etc/init.d/shadow-vpn restart' >/dev/null
	wait_up "$gen" "init: after a Shadow restart"
	converge_after "init: Shadow reload" R '/etc/init.d/shadow-vpn reload'
	if poll 60 tunnel_up; then ok "init: after a Shadow reload, connected"; else nok "init: after a Shadow reload, connected" "$(rpc status | jq -c '{phase,message}')"; fi
	check "init: still enabled" "1" "$(main_opt enabled)"

	# 1) autostart=1: Shadow comes back on and reconnects
	check "boot: autostart is on" "1" "$(main_opt autostart)"
	power_cycle "boot autostart=1" || return
	if poll 90 tunnel_up; then
		ok "boot autostart=1: Shadow is on and connected again"
		measure "boot autostart=1: boot done -> connected, tunnel alive" "$POLL_MS ms"
	else
		nok "boot autostart=1: Shadow is on and connected again" "$(rpc status | jq -c '{enabled,phase,message,tunnel}')"
	fi
	if poll 60 tunnelled tunnel.shadow.lab; then ok "boot autostart=1: LAN traffic tunnelled again"
	else nok "boot autostart=1: LAN traffic tunnelled again" "$(probe_http tunnel.shadow.lab)"; fi
	check "boot autostart=1: still enabled" "1" "$(main_opt enabled)"

	# 2) an Off cut short by a power loss: enabled=0 committed, nothing torn down yet
	R 'uci set shadow-vpn.main.enabled=0; uci commit shadow-vpn' >/dev/null
	expect "interrupted off: still armed before the power cut" R "[ -e $RUN/active ]"
	power_cycle "interrupted off" || return
	check "interrupted off: Shadow stays off" "0" "$(main_opt enabled)"
	check "interrupted off: rpc status says off" "false disconnected" "$(rpc status | jq -r '"\(.enabled) \(.phase)"')"
	poll 30 inactive
	check_off "interrupted off"
	check_lan_direct "interrupted off"

	# 3) autostart=0: the boot turns an enabled Shadow off for real
	shadow_on "autostart=0" || return
	R 'uci set shadow-vpn.main.autostart=0; uci commit shadow-vpn' >/dev/null
	power_cycle "boot autostart=0" || return
	if poll 60 main_is enabled 0; then ok "boot autostart=0: the boot turned Shadow off (enabled=0)"
	else nok "boot autostart=0: the boot turned Shadow off (enabled=0)" "enabled=$(main_opt enabled)"; fi
	check "boot autostart=0: rpc status says off" "false disconnected" "$(rpc status | jq -r '"\(.enabled) \(.phase)"')"
	poll 30 inactive
	check_off "boot autostart=0"
	check_lan_direct "boot autostart=0"
	R 'uci set shadow-vpn.main.autostart=1; uci commit shadow-vpn' >/dev/null
}

stage3_luci() {
	echo "== stage3: LuCI: every rpc method with the router's real data, the pages over HTTP, Russian"
	local out r sid ksid sel pins p p1 p2 n before after fp endpoint ru v js sess f link1 link2 upid

	if ! main_is enabled 1; then
		r="$(enable true)"
		check "luci: Shadow on" '"state": "done"' "$r"
	fi
	poll 90 tunnel_up || { nok "luci: Shadow connected first" "$(rpc status | jq -c '{phase,message}')"; return; }

	# the methods the router offers are exactly the ones this group calls (a new one cannot go untested)
	check "rpc: the router offers the 39 methods tested here" "$LUCI_METHODS" \
		"$(R 'ubus -v list luci.shadow-vpn' | sed -n 's/^[[:space:]]*"\([a-z_]*\)":.*/\1/p' | LC_ALL=C sort | tr '\n' ' ')"

	# status
	out="$(rpc status)"
	check "rpc status: on, armed, connected over xray" "true true connected xray" \
		"$(printf '%s' "$out" | jq -r '"\(.enabled) \(.active) \(.phase) \(.transport)"')"
	same "rpc status: versions.shadow is the installed package" "$(installed_version)" "$(printf '%s' "$out" | jq -r .versions.shadow)"
	check "rpc status: the xray-core version" "26." "$(printf '%s' "$out" | jq -r .versions.xray)"
	check "rpc status: the openssh-client version" "10." "$(printf '%s' "$out" | jq -r .versions.openssh)"
	check "rpc status: memory of the running xray" "true" \
		"$(printf '%s' "$out" | jq -r '(.memory.xray_kb // 0) > 0 and (.memory.total_kb // 0) > 0')"
	check "rpc status: tunnel alive with a delay" "true number" "$(printf '%s' "$out" | jq -r '"\(.tunnel.alive) \(.tunnel.delay_ms | type)"')"
	check "rpc status: routing summary" "proxy-all 1" "$(printf '%s' "$out" | jq -r '"\(.routing.mode) \(.routing.rules.domain)"')"
	check "rpc status: the selected profile" "lab-vless-kcp" "$(printf '%s' "$out" | jq -r .target.name)"

	# select
	sel="$(profile_sid lab-vless-kcp)"
	# JSON with a comma goes through a variable: macOS bash 3.2 brace-expands "{...,...}" inside a "$(...)" argument
	r="{\"transport\":\"xray\",\"sid\":\"$sel\"}"
	check "rpc select: the selected profile again" "true" "$(rpc select "$r" | jq -r .ok)"
	check "rpc select: an unknown profile is refused" "Proxy profile does not exist." \
		"$(rpc select '{"transport":"xray","sid":"p_000000000000"}' | jq -r .error)"

	# servers, server_save, server_delete, hostkey_forget, hostkey_pin
	check "rpc servers: the lab servers" "true" \
		"$(rpc servers | jq -r '[.servers[].name] | (index("Lab password") != null) and (index("Lab key") != null)')"
	sid="$(rpc server_save "$(jq -nc '{values: {name: "E2E temp", host: "203.0.113.99", port: "22", username: "e2e",
		auth: "password", keepalive: "15", fingerprint: "", note: "stage3"}, password: "e2e-temp-password"}')" | jq -r '.sid // empty')"
	if [ -n "$sid" ]; then ok "rpc server_save: a new server"; else nok "rpc server_save: a new server" "no sid"; fi
	check "rpc servers: it is listed, with its password, not selected" "true false" \
		"$(rpc servers | jq -r --arg s "$sid" '.servers[] | select(.sid == $s) | "\(.has_password) \(.selected)"')"
	check "rpc server_save: field errors" "host" "$(rpc server_save "$(jq -nc '{values: {name: "E2E bad", host: "bad host!",
		port: "22", username: "e2e", auth: "password", keepalive: "15"}}')" | jq -r '.errors | keys | join(",")')"
	check "rpc hostkey_forget" "true" "$(rpc hostkey_forget "{\"sid\":\"$sid\"}" | jq -r .ok)"
	pin_args="$(jq -nc --arg s "$sid" '{sid: $s, fingerprint: "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}')"
	check "rpc hostkey_pin: nothing seen yet" "No server key has been seen yet" "$(rpc hostkey_pin "$pin_args" | jq -r .error)"
	check "rpc server_delete" "true" "$(rpc server_delete "{\"sid\":\"$sid\"}" | jq -r .ok)"
	check "rpc servers: it is gone" "0" "$(rpc servers | jq -r --arg s "$sid" '[.servers[] | select(.sid == $s)] | length')"
	# "Pin this key" with the key ssh really saw, then trust on first use again
	sid="$(server_sid 'Lab password')"
	if select_wait ssh "$sid" "rpc hostkey_pin: Lab password connected"; then
		fp="$(rpc servers | jq -r --arg s "$sid" '.servers[] | select(.sid == $s) | .hostkey.seen.fingerprint // empty')"
		pin_args="$(jq -nc --arg s "$sid" --arg f "$fp" '{sid: $s, fingerprint: $f}')"
		same "rpc hostkey_pin: pins the key ssh saw" "$fp" "$(rpc hostkey_pin "$pin_args" | jq -r .fingerprint)"
		if poll 60 tunnel_up; then ok "rpc hostkey_pin: connected with the pin"; else nok "rpc hostkey_pin: connected with the pin" "$(rpc status | jq -c '{phase,message}')"; fi
		pw_server_save "$sid" "$(cat "$STATE/ssh.pw")" "" >/dev/null
		fp="$(rpc servers | jq -r --arg s "$sid" '.servers[] | select(.sid == $s) | "[\(.fingerprint)]"')"
		same "rpc hostkey_pin: the pin cleared again (trust on first use)" "[]" "$fp"
	fi
	select_wait xray "$sel" "luci: back to lab-vless-kcp"

	# keys, key_show, key_save, key_delete
	ksid="$(key_sid 'Lab key')"
	check "rpc keys: the lab key, used by a server" "ed25519 openssh true" \
		"$(rpc keys | jq -r --arg k "$ksid" '.keys[] | select(.sid == $k) | "\(.type) \(.format) \(.used > 0)"')"
	check "rpc key_show: the stored private key" "-----BEGIN OPENSSH PRIVATE KEY-----" \
		"$(rpc key_show "{\"sid\":\"$ksid\"}" | jq -r '.text // .error' | head -1)"
	check "rpc key_delete: a key in use is refused" "used by at least one SSH configuration" \
		"$(rpc key_delete "{\"sid\":\"$ksid\"}" | jq -r .error)"
	out="$(V 'rm -f /tmp/e2e-k /tmp/e2e-k.pub; ssh-keygen -q -t ed25519 -N "" -C e2e-temp -f /tmp/e2e-k && cat /tmp/e2e-k; rm -f /tmp/e2e-k /tmp/e2e-k.pub')"
	out="$(jq -n --arg text "$out" '{name: "E2E temp key", text: $text, passphrase: ""}' |
		docker exec -i shadow-router sh -c 'ubus -t 30 call luci.shadow-vpn key_save "$(cat)"')"
	ksid="$(printf '%s' "$out" | jq -r '.sid // empty')"
	check "rpc key_save: a new key" "ed25519 openssh false" "$(printf '%s' "$out" | jq -r '"\(.key.type) \(.key.format) \(.key.encrypted)"')"
	check "rpc key_delete: an unused key" "true" "$(rpc key_delete "{\"sid\":\"${ksid:-k_000000000000}\"}" | jq -r .ok)"
	check "rpc keys: it is gone" "0" "$(rpc keys | jq -r --arg k "$ksid" '[.keys[] | select(.sid == $k)] | length')"

	# profiles, profiles_import, profile_rename, profile_link, profile_pin, profiles_delete_unpinned, profile_delete
	out="$(rpc profiles)"
	n="$(printf '%s' "$out" | jq '.profiles | length')"
	check "rpc profiles: the lab profiles, lab-vless-kcp selected" "lab-vless-kcp" "$(printf '%s' "$out" | jq -r '.profiles[] | select(.selected) | .name')"
	pins="$(printf '%s' "$out" | jq -r '.profiles[] | select(.pinned | not) | .sid')"
	for p in $pins; do rpc profile_pin "{\"sid\":\"$p\",\"pinned\":true}" >/dev/null; done
	link1='trojan://e2e-temp-1@203.0.113.99:443?security=tls&sni=example.com&type=tcp#e2e-temp-1'
	link2='trojan://e2e-temp-2@203.0.113.98:443?security=tls&sni=example.com&type=tcp#e2e-temp-2'
	out="$(rpc profiles_import "$(jq -nc --arg t "$link1
$link2" '{text: $t, source: "manual"}')")"
	check "rpc profiles_import: two new links" "2 0 0" "$(printf '%s' "$out" | jq -r '"\(.added) \(.updated) \(.failed)"')"
	p1="$(profile_sid e2e-temp-1)"
	p2="$(profile_sid e2e-temp-2)"
	r="{\"sid\":\"$p1\",\"name\":\"e2e temp renamed\"}"
	check "rpc profile_rename" "e2e temp renamed" "$(rpc profile_rename "$r" | jq -r .name)"
	same "rpc profile_link: the stored link, unchanged by the rename" "$link1" "$(rpc profile_link "{\"sid\":\"$p1\"}" | jq -r .link)"
	r="{\"sid\":\"$p1\",\"pinned\":true}"
	check "rpc profile_pin" "true" "$(rpc profile_pin "$r" | jq -r .ok)"
	check "rpc profiles_delete_unpinned: only the unpinned one goes" "true 1" "$(rpc profiles_delete_unpinned | jq -r '"\(.ok) \(.deleted)"')"
	check "rpc profiles: e2e-temp-2 gone, the pinned one kept" "0 1" \
		"$(rpc profiles | jq -r --arg a "$p2" --arg b "$p1" '"\([.profiles[] | select(.sid == $a)] | length) \([.profiles[] | select(.sid == $b)] | length)"')"
	check "rpc profile_delete" "true" "$(rpc profile_delete "{\"sid\":\"$p1\"}" | jq -r .ok)"
	for p in $pins; do rpc profile_pin "{\"sid\":\"$p\",\"pinned\":false}" >/dev/null; done
	same "rpc profiles: the lab profiles as before" "$n" "$(rpc profiles | jq '.profiles | length')"
	check "rpc profiles: their pins as before" "$(printf '%s' "$pins" | sort | tr '\n' ' ')" \
		"$(rpc profiles | jq -r '.profiles[] | select(.pinned | not) | .sid' | sort | tr '\n' ' ')"

	# lists, list_refresh (the real download from GitHub), list_view, list_set
	check "rpc lists: both lists off" "false false" "$(rpc lists | jq -r '"\(.proxy.enabled) \(.direct.enabled)"')"
	r="$(job_wait "$(rpc list_refresh '{"kind":"direct"}')")"
	check "rpc list_refresh: downloads the real Russian-services list" "done" "$(printf '%s' "$r" | jq -r .state)"
	check "rpc list_view: the downloaded domains" "true" "$(rpc list_view '{"kind":"direct"}' | jq -r '(.domains | length) > 5')"
	check "rpc lists: its count and time" "true" "$(rpc lists | jq -r '.direct.count > 5 and .direct.updated != null')"
	r="$(job_wait "$(rpc list_set '{"kind":"direct","enabled":false}')")"
	check "rpc list_set: a converge job" "done" "$(printf '%s' "$r" | jq -r .state)"
	R 'rm -f /etc/shadow-vpn/lists/direct.lst /etc/shadow-vpn/lists/direct.sha256' >/dev/null
	check "rpc list_view: a list never downloaded" "0" "$(rpc list_view '{"kind":"proxy"}' | jq '.domains | length')"

	# rules, rule_add, rule_set, rules_export, rules_import, rule_delete
	before="$(rpc rules | jq -c '[.rules[] | {id, type, value, enabled}] | sort_by(.id)')"
	out="$(rpc rule_add '{"type":"domain","value":"e2e-temp.test"}')"
	sid="$(printf '%s' "$out" | jq -r '.sid // empty')"
	check "rpc rule_add" "e2e-temp.test" "$(printf '%s' "$out" | jq -r '.value // .error')"
	check "rpc rule_add: a duplicate is refused" "This rule already exists." "$(rpc rule_add '{"type":"domain","value":"E2E-temp.test"}' | jq -r .error)"
	check "rpc rule_add: an invalid value is refused" "true" "$(rpc rule_add '{"type":"ip","value":"300.1.1.1"}' | jq -r '(.error // "") != ""')"
	r="{\"sid\":\"$sid\",\"enabled\":false}"
	check "rpc rule_set: off" "true false" \
		"$(rpc rule_set "$r" | jq -r .ok) $(rpc rules | jq -r --arg s "$sid" '.rules[] | select(.sid == $s) | .enabled')"
	out="$(rpc rules_export | jq -r .json)"
	check "rpc rules_export: desktop JSON with both rules" "true" \
		"$(printf '%s' "$out" | jq -r '[.[].value] | (index("tunnel.shadow.lab") != null) and (index("e2e-temp.test") != null)')"
	r="$(rpc rules_import "$(jq -nc '{text: ([{type: "domain", value: "dry.test"}, {type: "process.name", value: "chrome.exe"},
		{type: "ip", value: "10.0.0.0/08"}] | tojson), apply: false}')")"
	check "rpc rules_import: a dry run counts, skips the desktop app rule" "3 2 1" \
		"$(printf '%s' "$r" | jq -r '"\(.total) \(.imported) \(.skipped.apps)"')"
	after="$(rpc rules | jq -c '[.rules[] | {id, type, value, enabled}] | sort_by(.id)')"
	r="$(rpc rules_import "$(jq -nc --arg t "$out" '{text: $t, apply: true}')")"
	same "rpc rules_import: the export applied back" "$(printf '%s' "$out" | jq length)" "$(printf '%s' "$r" | jq -r .imported)"
	same "rpc rules_import: ...gives the same rules (ids kept)" "$after" "$(rpc rules | jq -c '[.rules[] | {id, type, value, enabled}] | sort_by(.id)')"
	sid="$(rule_sid domain e2e-temp.test)"
	check "rpc rule_delete" "true" "$(rpc rule_delete "{\"sid\":\"$sid\"}" | jq -r .ok)"
	same "rpc rules: as before" "$before" "$(rpc rules | jq -c '[.rules[] | {id, type, value, enabled}] | sort_by(.id)')"

	# leases, check, job_status, logs, attention_dismiss, settings_set
	check "rpc leases: the DHCP leases" "array" "$(rpc leases | jq -r '.leases | type')"
	r="$(job_wait "$(rpc check)")"
	check "rpc check: the tunnel check passes" "true" "$(printf '%s' "$r" | jq -r .result.ok)"
	measure "rpc check" "$(printf '%s' "$r" | jq -r '"\(.result.outcome) \(.result.ms) ms"')"
	check "rpc job_status: an unknown job" "Job not found." "$(rpc job_status '{"id":"1-1"}' | jq -r .error)"
	out="$(rpc logs '{"lines":300}')"
	check "rpc logs: Shadow's and xray's lines" "true" "$(printf '%s' "$out" | jq -r '[.lines[] | select(test("shadow-vpn|xray"))] | length > 0')"
	r=ok
	for f in $LAB_SECRETS; do
		[ -s "$STATE/$f" ] && printf '%s' "$out" | grep -qF -- "$(cat "$STATE/$f")" && r="$f"
	done
	if [ "$r" = ok ]; then ok "rpc logs: no lab secret in the lines"; else nok "rpc logs: no lab secret in the lines" "the secret from state/$r appears"; fi
	check "rpc logs_clear: the mark is logged" "true" "$(rpc logs_clear | jq -r .ok)"
	check "rpc logs: the lines start at the Clear mark" "luci: log view cleared" \
		"$(rpc logs '{"lines":300}' | jq -r '.lines[0] // ""' | sed 's/^.* shadow-vpn: //')"
	check "rpc attention_dismiss: a bad id is refused" "Invalid arguments." "$(rpc attention_dismiss '{"id":"../x"}' | jq -r .error)"
	endpoint="$(main_opt check_endpoint)"
	check "rpc settings_set: check endpoint and auto-refresh" "true" \
		"$(rpc settings_set "$(jq -nc --arg e "$endpoint" '{values: {check_endpoint: $e, lists_refresh: "24"}}')" | jq -r .ok)"
	check "rpc settings_set: a bad endpoint" "check_endpoint" "$(rpc settings_set '{"values":{"check_endpoint":"no port"}}' | jq -r '.errors | keys | join(",")')"
	check "rpc settings_set: an unknown setting" "Unknown setting." "$(rpc settings_set '{"values":{"e2e":"1"}}' | jq -r .errors.e2e)"
	same "rpc settings_set: the endpoint as before" "$endpoint" "$(main_opt check_endpoint)"

	# update_status, update_check, update_install. Never against GitHub (stage3_update serves releases in the lab):
	# here an update in progress makes both refuse. The base URL hook names the stopped package server, so even a
	# job they started by mistake could not reach GitHub; cron is stopped meanwhile, as the hourly "update due"
	# removes a run file it finds (it holds the lock, so no install runs).
	v="$(installed_version)"
	out="$(rpc update_status)"
	check "rpc update_status: mode, the installed version, nothing running" "notify ${v%-r*} null" \
		"$(printf '%s' "$out" | jq -r '"\(.mode) \(.installed) \(.running)"')"
	check "rpc update_status: the router's time and zone" "true" \
		"$(printf '%s' "$out" | jq -r '(.clock.time | test("^[0-2][0-9]:[0-5][0-9]$")) and (.clock.zone | type == "string" and length > 0)')"
	check "rpc update_status: the check, last and automatic results are null or of their types" "true" \
		"$(printf '%s' "$out" | jq -r '(.latest == null or (.latest | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))) and
			(.checked_age == null or (.checked_age | type) == "number") and ([.last, .auto] | all(. == null or type == "object"))')"
	R "/etc/init.d/cron stop; echo $BASE_URL > $RUN/update.base_url" >/dev/null
	# a stand-in for the updater: its command line names it, it writes the run file the real one writes
	docker exec -d shadow-router sh -c 'printf "{\"pid\":%d,\"stage\":\"download\",\"version\":\"%s\",\"auto\":false,\"started\":%d,\"started_up\":%d}\n" \
		$$ "$1" "$(date +%s)" "$(cut -d. -f1 /proc/uptime)" > /var/run/shadow-vpn/update.run.json
		i=0; while [ $i -lt 120 ]; do sleep 1; i=$((i + 1)); done' "$LIBEXEC/update" "$(next_version)"
	poll 10 R "[ -s $RUN/update.run.json ]"
	upid="$(R "cat $RUN/update.run.json" | jq -r '.pid // empty' 2>/dev/null)"
	check "rpc update_status: an update in progress" "download $(next_version) false true" \
		"$(rpc update_status | jq -r '.running | "\(.stage) \(.version) \(.auto) \(.age | type == "number")"')"
	check "rpc update_check: refused while an update runs" "An update is already running." "$(rpc update_check | jq -r '.error // .job')"
	check "rpc update_install: refused while an update runs" "An update is already running." "$(rpc update_install | jq -r '.error // .job')"
	[ -n "$upid" ] && R "kill $upid" >/dev/null && poll 10 R "[ ! -e /proc/$upid ]"
	check "rpc update_status: a run file whose updater is gone is no update in progress" "null" "$(rpc update_status | jq -r .running)"
	R "rm -f $RUN/update.run.json $RUN/update.base_url; /etc/init.d/cron start" >/dev/null

	# the pages from the LAN, like a browser: each view page, its JS is the packaged file, the Russian catalog
	C 'rm -f /tmp/cj; curl -s -m 10 -c /tmp/cj -o /dev/null -d "luci_username=root&luci_password='"$ROOT_PW"'" http://192.168.77.1/cgi-bin/luci/' >/dev/null
	for v in overview ssh xray routing log settings; do
		out="$(C "curl -s -m 10 -b /tmp/cj -w '\n%{http_code}' http://192.168.77.1/cgi-bin/luci/admin/services/shadow-vpn/$v")"
		check "luci page $v: 200, and it loads view shadow-vpn/$v" "200 1" \
			"$(printf '%s' "$out" | tail -1) $(printf '%s' "$out" | grep -c "instantiateView('shadow-vpn/$v')")"
		js="$(C "curl -s -m 10 -o /tmp/e2e.js -w '%{http_code}' http://192.168.77.1/luci-static/resources/view/shadow-vpn/$v.js; echo; md5sum < /tmp/e2e.js")"
		same "luci page $v: its JS is the packaged view (200, same bytes)" \
			"200 $(host_md5 "$TREE/luci-app-shadow-vpn/htdocs/luci-static/resources/view/shadow-vpn/$v.js")" \
			"$(printf '%s' "$js" | head -1) $(printf '%s' "$js" | tail -1 | cut -c1-32)"
	done
	js="$(C "curl -s -m 10 -o /tmp/e2e.js -w '%{http_code}' http://192.168.77.1/luci-static/resources/shadow-vpn/common.js; echo; md5sum < /tmp/e2e.js")"
	same "luci: common.js is the packaged one" "200 $(host_md5 "$TREE/luci-app-shadow-vpn/htdocs/luci-static/resources/shadow-vpn/common.js")" \
		"$(printf '%s' "$js" | head -1) $(printf '%s' "$js" | tail -1 | cut -c1-32)"
	ru="$(grep -A1 '^msgid "DNS lookups bypass the tunnel"$' "$TREE/luci-app-shadow-vpn/po/ru/shadow-vpn.po" | sed -n 's/^msgstr "\(.*\)"$/\1/p')"
	check "luci: the Russian catalog is served (one of our strings)" "${ru:-no msgstr in the .po}" \
		"$(C 'curl -s -m 10 -b /tmp/cj http://192.168.77.1/cgi-bin/luci/admin/translations/ru')"
	check "luci: the page in Russian for a Russian browser" '<html lang="ru"' \
		"$(C 'curl -s -m 10 -b /tmp/cj -H "Accept-Language: ru" http://192.168.77.1/cgi-bin/luci/admin/services/shadow-vpn/overview')"
	# LuCI's JSON-RPC endpoint: the ACL lets a root session read and write, nobody without one
	sess="$(jq -nc --arg pw "$ROOT_PW" '{jsonrpc: "2.0", id: 1, method: "call",
			params: [ "00000000000000000000000000000000", "session", "login", { username: "root", password: $pw } ]}' |
		ubus_http | jq -r '.result[1].ubus_rpc_session // empty')"
	check "luci /ubus: servers with the root session" "Lab password" \
		"$(jq -nc --arg s "$sess" '{jsonrpc: "2.0", id: 2, method: "call", params: [ $s, "luci.shadow-vpn", "servers", {} ]}' |
			ubus_http | jq -r '[.result[1].servers[]?.name] | join(",")')"
	check "luci /ubus: settings_set with the root session" "true" \
		"$(jq -nc --arg s "$sess" --arg e "$endpoint" '{jsonrpc: "2.0", id: 3, method: "call",
			params: [ $s, "luci.shadow-vpn", "settings_set", { values: { check_endpoint: $e } } ]}' | ubus_http | jq -r '.result[1].ok')"
	check "luci /ubus: no session, no access" "Access denied" \
		"$(jq -nc '{jsonrpc: "2.0", id: 4, method: "call", params: [ "00000000000000000000000000000000", "luci.shadow-vpn", "status", {} ]}' |
			ubus_http | jq -r '.error.message')"
}

stage3_keep() {
	echo "== stage3: sysupgrade keeps Shadow's settings and secrets"
	local out
	check "keep: /lib/upgrade/keep.d/shadow-vpn" "/etc/config/shadow-vpn /etc/shadow-vpn/ " "$(R 'cat /lib/upgrade/keep.d/shadow-vpn' | tr '\n' ' ')"
	# names only, never contents
	out="$(R 'L="$(sysupgrade -l 2>/dev/null)"; n=0
		for f in /etc/config/shadow-vpn $(find /etc/shadow-vpn -type f); do
			n=$((n + 1)); printf "%s\n" "$L" | grep -qxF "$f" || echo "missing $f"
		done
		echo "files=$n"')"
	check "keep: sysupgrade -l lists the config and every file under /etc/shadow-vpn" "files=" "$out"
	check_not "keep: ...none missing" "missing" "$out"
	check "keep: ...secrets among them" "true" "$(R 'sysupgrade -l 2>/dev/null' | grep -c '^/etc/shadow-vpn/secrets/' | awk '{ print ($1 > 0) ? "true" : "false" }')"
	out="$(R 'rm -f /tmp/e2e-backup.tgz; sysupgrade -b /tmp/e2e-backup.tgz >/dev/null 2>&1; tar -tzf /tmp/e2e-backup.tgz 2>&1; rm -f /tmp/e2e-backup.tgz')"
	check "keep: a sysupgrade backup carries the config" "etc/config/shadow-vpn" "$out"
	check "keep: ...and /etc/shadow-vpn" "etc/shadow-vpn/secrets/" "$out"
}

# install.sh while Shadow is on with the kill switch in full mode and the tunnel is down: the router cannot
# download anything, and install.sh says so instead of failing somewhere in apk. install.sh itself is pushed
# in first: with the router blocked it could not fetch it either (README).
stage3_blocked() {
	echo "== stage3: install.sh while the kill switch blocks the router (Shadow on, full mode, tunnel down)"
	local r v
	if ! main_is enabled 1; then
		r="$(enable true)"
		check "blocked: Shadow on" '"state": "done"' "$r"
	fi
	poll 90 tunnel_up || { nok "blocked: Shadow connected first" "$(rpc status | jq -c '{phase,message}')"; return; }
	check "blocked: full mode, kill switch, router traffic" "proxy-all 1 1" "$(main_opt mode) $(main_opt kill_switch) $(main_opt router_traffic)"
	v="$(installed_version)"
	push "$TREE/install.sh" /tmp/install.sh 755
	vpn_block drop
	if poll 60 alive_is false; then ok "blocked: the tunnel is down"; else nok "blocked: the tunnel is down" "$(rpc status | jq -c .tunnel)"; fi
	# no package server: the router could not reach it anyway, and install.sh must stop before any download
	INSTALL_OUT="$(R "SHADOW_BASE_URL=$BASE_URL sh /tmp/install.sh </dev/null; echo rc=\$?")"
	check "blocked: install.sh stops" "rc=1" "$INSTALL_OUT"
	check "blocked: ...and says why (English)" "Shadow is on with the kill switch and its tunnel is down" "$INSTALL_OUT"
	check "blocked: ...and how to go on (English)" "Turn Shadow off" "$INSTALL_OUT"
	check "blocked: ...in Russian too" "Выключите Shadow" "$INSTALL_OUT"
	same "blocked: nothing was changed" "$v" "$(installed_version)"
	check "blocked: Shadow is still on" "1" "$(main_opt enabled)"
	vpn_unblock
	if poll 60 tunnel_up; then ok "blocked: the tunnel is back"; else nok "blocked: the tunnel is back" "$(rpc status | jq -c '{phase,tunnel}')"; fi
}

stage3_upgrade() {
	echo "== stage3: upgrade to a newer build with install.sh (Shadow on)"
	local next dir before out
	next="$(next_version)"
	dir="$TREE/out/upgrade"
	shadow_on "upgrade" || return
	before="$(etc_sums)"
	# what the md5 comparison below covers (stage3.luci connected over SSH, so known_hosts and trust exist)
	out=""
	for f in etc/shadow-vpn/secrets/ etc/shadow-vpn/keys/ etc/shadow-vpn/known_hosts etc/shadow-vpn/trusted.; do
		printf '%s' "$before" | grep -qF " $f" && out="$out ${f#etc/shadow-vpn/}"
	done
	check "upgrade: there are secrets, keys, known_hosts and trust to keep" " secrets/ keys/ known_hosts trusted." "$out"
	if out="$(OUT="$dir" "$TREE/build/mk_apk.sh" "$next" 2>&1)"; then ok "upgrade: build $next"; else nok "upgrade: build $next" "$out"; return; fi
	install_sh "$dir"
	measure "upgrade: install.sh run (Shadow on)" "$INSTALL_MS ms"
	check "upgrade: install.sh exits 0" "rc=0" "$INSTALL_OUT"
	check "upgrade: it says so" "Shadow is upgraded to $next-r1 and is on" "$INSTALL_OUT"
	same "upgrade: $next-r1 is installed" "$next-r1" "$(installed_version)"
	if poll 60 tunnel_up; then ok "upgrade: Shadow stayed on and is connected"; else nok "upgrade: Shadow stayed on and is connected" "$(rpc status | jq -c '{phase,message}')"; fi
	check "upgrade: LAN traffic tunnelled" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	same "upgrade: config, secrets, keys, known_hosts and trust unchanged (md5)" "$before" "$(etc_sums)"
	same "upgrade: rpc status reports the new version" "$next-r1" "$(status_field .versions.shadow)"
}

stage3_uninstall() {
	echo "== stage3: removal: install.sh --uninstall, then apk del without install.sh"
	local before out

	shadow_on "uninstall" || return
	before="$(etc_secret_sums)"
	install_sh "$TREE/out" --uninstall
	measure "uninstall: install.sh --uninstall" "$INSTALL_MS ms"
	check "uninstall: install.sh --uninstall exits 0" "rc=0" "$INSTALL_OUT"
	check "uninstall: it says so" "Shadow is removed" "$INSTALL_OUT"
	removed_checks "uninstall"
	check "uninstall: Shadow is recorded off" "0" "$(main_opt enabled)"
	same "uninstall: secrets, keys and trust stay" "$before" "$(etc_secret_sums)"

	install_sh "$TREE/out"
	measure "reinstall after uninstall (dependencies from the feed again)" "$INSTALL_MS ms"
	check "reinstall: install.sh exits 0" "rc=0" "$INSTALL_OUT"
	check "reinstall: Shadow comes back off" "is installed and is off" "$INSTALL_OUT"
	expect "reinstall: nothing of Shadow armed" R '! nft list table inet shadow_vpn >/dev/null 2>&1 && [ ! -e /var/run/shadow-vpn/active ]'
	check "reinstall: the old servers are there" "Lab password" "$(rpc servers | jq -r '[.servers[].name] | join(",")')"

	# apk del on its own: the package's pre-deinstall turns Shadow off and tears it down
	shadow_on "apk del" || return
	out="$(R 'apk del luci-i18n-shadow-vpn-ru luci-app-shadow-vpn shadow-vpn </dev/null; echo rc=$?')"
	check "apk del: exits 0" "rc=0" "$out"
	removed_checks "apk del"
	check "apk del: Shadow is recorded off, so a later install starts off" "0" "$(main_opt enabled)"
	install_sh "$TREE/out"
	check "reinstall after apk del: install.sh exits 0" "rc=0" "$INSTALL_OUT"
	check "reinstall after apk del: Shadow comes back off" "is installed and is off" "$INSTALL_OUT"
	expect "reinstall after apk del: nothing of Shadow armed" R '! nft list table inet shadow_vpn >/dev/null 2>&1 && [ ! -e /var/run/shadow-vpn/active ]'
}

# Updates from LuCI (DESIGN.md 11): the lab package server serves releases in GitHub's shape, and the updater takes
# them from there through the base URL hook RUN/update.base_url. Cron is stopped meanwhile: the hourly "update due"
# takes the update lock, and a check or install that met it would be refused.
stage3_update() {
	echo "== stage3: updates: check and install through rpc (Shadow on), an automatic update rolled back"
	local cur next broken dir auto before r out t0 id xpid

	cur="$(installed_version)"
	cur="${cur%-r*}"
	[ -n "$cur" ] || { nok "update: Shadow is installed" "no shadow-vpn package"; return; }
	next="${cur%.*}.$((${cur##*.} + 1))"
	broken="${next%.*}.$((${next##*.} + 1))"
	dir="$TREE/out/update"
	auto="$TREE/out/update-auto"
	update_cleanup
	R '/etc/init.d/cron stop' >/dev/null
	# the updater logs a successful install at level info ("Detailed"); the default level (warning) leaves it out
	set_main log_level=info
	poll 30 settled
	shadow_on "update" || { update_cleanup; return; }

	# the latest release: a build of the next version; the installed one under its tag, as GitHub keeps every release
	rm -rf "$dir" "$auto"
	if out="$(OUT="$dir" "$TREE/build/mk_apk.sh" "$next" 2>&1)"; then ok "update: build $next"; else nok "update: build $next" "$out"; update_cleanup; return; fi
	release_json "$dir" "$next"
	if [ "$cur" = "$(cat "$TREE/build/VERSION")" ]; then
		mkdir -p "$dir/$cur" && cp "$TREE/out/SHA256SUMS" "$TREE"/out/*.apk "$dir/$cur/" && release_json "$dir/$cur" "$cur"
	fi
	expect "update: package server with release.json" pkgsrv_start "$dir"
	R "echo $BASE_URL > $RUN/update.base_url" >/dev/null

	# "Check now"
	r="$(job_wait "$(rpc update_check)" 150)"
	check "update: update_check through rpc finds $next" "done true $cur $next true false" \
		"$(printf '%s' "$r" | jq -r '"\(.state) \(.result.ok) \(.result.installed) \(.result.latest) \(.result.available) \(.result.console) \(.result.error // "")"')"
	out="$(rpc update_status)"
	check "update: update_status after the check" "notify $cur $next true true null" \
		"$(printf '%s' "$out" | jq -r '"\(.mode) \(.installed) \(.latest) \(.available) \(.check_ok) \(.running)"')"
	same "update: the release page from release.json" "$BASE_URL/releases/tag/$next" "$(printf '%s' "$out" | jq -r .url)"
	check "update: the release notes" "Lab release $next." "$(printf '%s' "$out" | jq -r .notes)"
	check "update: the release date and the check's age" "number number" \
		"$(printf '%s' "$out" | jq -r '"\(.published | type) \(.checked_age | type)"')"
	check "update: the banner says so" "Shadow $next is available." \
		"$(rpc status | jq -r '.attention[] | select(.code == "update_available") | .message')"

	# "Update to $next": Shadow stays on, the tunnel comes back, settings and secrets stay
	before="$(etc_sums)"
	xpid="$(instance_pid xray)"
	log_mark update
	t0=$(now_ms)
	r="$(job_wait "$(rpc update_install)" 600)"
	measure "update: update_install job (Shadow on)" "$(($(now_ms) - t0)) ms"
	check "update: update_install through rpc updates $cur to $next" "done true true $cur $next" \
		"$(printf '%s' "$r" | jq -r '"\(.state) \(.result.ok) \(.result.changed) \(.result.from) \(.result.to) \(.result.error // "")"')"
	same "update: $next-r1 is installed" "$next-r1" "$(installed_version)"
	check "update: Shadow stayed on" "1" "$(main_opt enabled)"
	if poll 60 tunnel_up; then ok "update: connected, tunnel alive"; else nok "update: connected, tunnel alive" "$(rpc status | jq -c '{phase,message,tunnel}')"; fi
	check "update: LAN traffic tunnelled" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	out="$(rpc update_status)"
	check "update: update_status.last is this update" "true true $cur $next false" \
		"$(printf '%s' "$out" | jq -r '.last | "\(.ok) \(.changed) \(.from) \(.to) \(.auto)"')"
	check "update: update_status: $next installed, nothing newer, nothing running" "$next false null" \
		"$(printf '%s' "$out" | jq -r '"\(.installed) \(.available) \(.running)"')"
	expect "update: the update lock is free, its run file and work dir gone" update_idle
	same "update: config, secrets, keys, known_hosts and trust unchanged (md5)" "$before" "$(etc_sums)"
	if has_attention update_available; then nok "update: the banner is gone" "$(rpc status | jq -c .attention)"; else ok "update: the banner is gone"; fi
	check "update: the log says so (level info)" "Shadow was updated from $cur to $next." "$(since_mark "$LOG_MARK" | grep -F "Shadow was updated" | tail -1)"
	# the same render: procd kept xray over the package's post-install, so the updater started it again itself
	out="$(instance_pid xray)"
	if [ -n "$xpid" ] && [ -n "$out" ] && [ "$xpid" != "$out" ]; then ok "update: xray runs the new code (its instance started again)"
	else nok "update: xray runs the new code (its instance started again)" "pid $xpid before, '$out' after"; fi
	same "update: rpc status reports the new version" "$next-r1" "$(status_field .versions.shadow)"

	# An automatic update (what the hourly "update due" starts at night: job update-install --auto <version>) to a
	# build whose xray never starts: the tunnel does not come back, so the updater installs $next again from the files
	# it downloaded before it changed anything (<base>/$next/), and Shadow connects again
	if out="$(broken_build "$broken" "$auto" 2>&1)"; then ok "update auto: build $broken, its xray never starts"
	else nok "update auto: build $broken, its xray never starts" "$out"; update_cleanup; return; fi
	release_json "$auto" "$broken"
	mkdir -p "$auto/$next" && cp "$dir/SHA256SUMS" "$dir"/*.apk "$dir/release.json" "$auto/$next/"
	expect "update auto: package server with $broken, and $next under its tag" pkgsrv_start "$auto"
	before="$(etc_sums | grep -vF " ${UPDATE_AUTO#/}")"
	t0=$(now_ms)
	id="$(R "$LIBEXEC/job update-install --auto $broken" | tail -1)"
	if ! printf '%s' "$id" | grep -qxE '[0-9]+-[0-9]+'; then nok "update auto: job update-install --auto $broken" "$id"; update_cleanup; return; fi
	r="$(job_wait "{\"job\":\"$id\"}" 600)"
	measure "update auto: install, the tunnel not back, rollback, connected" "$(($(now_ms) - t0)) ms"
	check "update auto: the update failed and was rolled back" "failed false false true" \
		"$(printf '%s' "$r" | jq -r '"\(.state) \(.result.ok) \(.result.changed) \(.result.rolled_back)"')"
	same "update auto: ...and says so" "Shadow $broken was installed, but the tunnel did not come back, so Shadow $next was put back." \
		"$(printf '%s' "$r" | jq -r '.result.error')"
	same "update auto: $next-r1 is installed again" "$next-r1" "$(installed_version)"
	same "update auto: the working xray-run is back" "$(host_md5 "$TREE/shadow-vpn/files/usr/libexec/shadow-vpn/xray-run")" \
		"$(R "md5sum < $LIBEXEC/xray-run" | cut -c1-32)"
	if poll 90 tunnel_up; then ok "update auto: Shadow is on and connected again"
	else nok "update auto: Shadow is on and connected again" "$(rpc status | jq -c '{enabled,phase,message,tunnel}')"; fi
	check "update auto: LAN traffic tunnelled" "$TUNNEL_SRC" "$(curl_c http://tunnel.shadow.lab/)"
	out="$(rpc update_status)"
	check "update auto: update_status.last is the rolled back attempt" "false false true true" \
		"$(printf '%s' "$out" | jq -r '.last | "\(.ok) \(.changed) \(.rolled_back) \(.auto)"')"
	check "update auto: update_status.auto: one finished attempt at $broken, not stopped yet" "$broken 1 true false false" \
		"$(printf '%s' "$out" | jq -r '.auto | "\(.version) \(.tries) \(.finished) \(.ok) \(.stopped)"')"
	same "update auto: the banner says why it failed" \
		"The automatic update to $broken failed: Shadow $broken was installed, but the tunnel did not come back, so Shadow $next was put back." \
		"$(rpc status | jq -r '.attention[] | select(.code == "update_failed") | .message')"
	expect "update auto: the attempt is recorded on flash, for root only" R "[ \"\$(ls -l $UPDATE_AUTO | cut -c1-10)\" = -rw------- ]"
	expect "update auto: the update lock is free, its run file and work dir gone" update_idle
	same "update auto: config, secrets, keys, known_hosts and trust unchanged (md5)" "$before" "$(etc_sums | grep -vF " ${UPDATE_AUTO#/}")"

	update_cleanup
	# a build that breaks the tunnel is nothing to keep in out/
	rm -rf "$auto"
}

stage3_mock() {
	echo "== stage3: no design mock on the router; the LuCI files are the packaged ones"
	local f
	expect "mock: only the six packaged views and common.js, no mock file" R '
		[ "$(ls /www/luci-static/resources/view/shadow-vpn | tr "\n" " ")" = "log.js overview.js routing.js settings.js ssh.js xray.js " ] &&
		[ "$(ls /www/luci-static/resources/shadow-vpn | tr "\n" " ")" = "common.js " ] &&
		[ -z "$(find /www /usr/share/luci /usr/share/rpcd -iname "*mock*" 2>/dev/null)" ]'
	for f in usr/share/luci/menu.d/luci-app-shadow-vpn.json usr/share/rpcd/acl.d/luci-app-shadow-vpn.json usr/share/rpcd/ucode/luci.shadow-vpn; do
		same "mock: /$f is the packaged one" "$(host_md5 "$TREE/luci-app-shadow-vpn/root/$f")" "$(R "md5sum < /$f" | cut -c1-32)"
	done
}

stage3_end() {
	echo "== stage3: end state: Shadow installed and off"
	local v
	v="$(cat "$TREE/build/VERSION")-r1"
	if [ "$(installed_version)" != "$v" ]; then
		install_sh "$TREE/out"
		check "end: Shadow $v installed" "rc=0" "$INSTALL_OUT"
	fi
	if main_is enabled 1; then
		enable false >/dev/null
		poll 30 inactive
	fi
	R "rm -f /etc/init.d/zz-e2e-boot /etc/rc.d/S99zz-e2e-boot $BOOT_MARK
	   uci set shadow-vpn.main.autostart=1; uci commit shadow-vpn" >/dev/null
	same "end: dnsmasq settings as before stage 3" "$DHCP_BEFORE" "$(dhcp_state)"
	check "end: Shadow installed and off" "false disconnected" "$(rpc status | jq -r '"\(.enabled) \(.phase)"')"
	expect "end: nothing of Shadow armed" R '! nft list table inet shadow_vpn >/dev/null 2>&1 && ! ip rule | grep -q "lookup 106"'
	if poll 20 lan_dns_ok; then ok "end: LAN DNS answers"; else nok "end: LAN DNS answers" "no answer"; fi
	check "end: the LAN reaches the web directly" "$DIRECT_SRC" "$(curl_c http://direct.shadow.lab/)"
}

stage3() {
	stage3_setup
	stage3_boot
	stage3_luci
	stage3_keep
	stage3_blocked
	stage3_upgrade
	stage3_uninstall
	# after uninstall: out/ is installed again, the version the update builds on
	stage3_update
	stage3_mock
	stage3_end
}

# ---- main ----------------------------------------------------------------------------------------------

command -v jq >/dev/null || { echo "needs jq on the host" >&2; exit 2; }
perl -MTime::HiRes -e 1 2>/dev/null || { echo "needs perl with Time::HiRes on the host" >&2; exit 2; }
lab_ready
trap pkgsrv_stop EXIT

stages="${*:-install stage1}"
for s in $stages; do
	case "$s" in
	install) stage_install ;;
	stage1) stage1 ;;
	stage2) stage2 ;;
	# one group of stage 2 on its own (development): stage2.killswitch_xray, stage2.ssh, ...
	stage2.*) stage2_setup; "stage2_${s#stage2.}" ;;
	stage3) stage3 ;;
	# one group of stage 3 on its own: stage3.boot, stage3.luci, ...
	stage3.*) stage3_setup; "stage3_${s#stage3.}" ;;
	*) echo "unknown stage: $s (install, stage1, stage2, stage2.<group>, stage3, stage3.<group>)" >&2; exit 2 ;;
	esac
done

echo "== $pass ok, $fail not ok"
[ "$fail" = 0 ]
