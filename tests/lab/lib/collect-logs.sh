#!/bin/bash
# Collects what explains a failed lab run into <dir> (CI uploads it as an artifact): the lab containers,
# their logs, and the router's log, Shadow state, nft ruleset, routes and dnsmasq files. Secret files (the
# rendered xray config, ssh params, /etc/shadow-vpn) are listed, never copied; the lab's secrets are
# throwaway values anyway (tests/lab/state).
#   tests/lab/lib/collect-logs.sh <dir>
set -u
OUT="${1:?usage: collect-logs.sh <dir>}"
LABEL="com.shadow.testenv=1"
mkdir -p "$OUT"

# grab <file> <command...>: the command's output (and errors) into $OUT/<file>
grab() {
	local f="$1"
	shift
	"$@" >"$OUT/$f" 2>&1 || echo "# exit $?" >>"$OUT/$f"
}
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

grab docker-ps.txt docker ps -a --filter "label=$LABEL" --format '{{.Names}}\t{{.Status}}\t{{.Image}}'
grab docker-version.txt docker version
for c in $(docker ps -a --filter "label=$LABEL" --format '{{.Names}}'); do
	grab "docker-logs-$c.txt" docker logs --tail 2000 "$c"
done

if running shadow-router; then
	grab router-logread.txt docker exec shadow-router logread
	grab router-state.txt docker exec shadow-router sh -c '
		RUN=/var/run/shadow-vpn
		echo "== uci show shadow-vpn"; uci -q show shadow-vpn
		echo "== $RUN"; ls -la $RUN $RUN/jobs 2>&1
		for f in state.json attention.json check.json gate transport applied fallback dnsmasq wan_dns lan_state patterns; do
			[ -e $RUN/$f ] && { echo "== $RUN/$f"; cat $RUN/$f; echo; }
		done
		for f in $RUN/ssh.*.log; do [ -e "$f" ] && { echo "== $f"; tail -n 100 "$f"; }; done
		echo "== /etc/shadow-vpn (names only)"; find /etc/shadow-vpn 2>&1
		echo "== procd"; ubus call service list "{\"name\":\"shadow-vpn\"}"; ubus call service list "{\"name\":\"dnsmasq\"}"
		echo "== processes"; ps w
		echo "== packages"; apk list -I 2>/dev/null | grep -E "shadow|xray|openssh|dnsmasq"'
	grab router-net.txt docker exec shadow-router sh -c '
		echo "== ip addr"; ip addr
		echo "== ip rule"; ip rule; ip -6 rule
		echo "== routes"; ip route show table all; ip -6 route show table all
		echo "== nft"; nft list ruleset
		echo "== listeners"; netstat -lntup
		echo "== dnsmasq conf-dir files"; for f in /tmp/dnsmasq.*.d/* /etc/dnsmasq.d/*; do [ -e "$f" ] && { echo "-- $f"; cat "$f"; }; done
		echo "== /etc/config/dhcp"; cat /etc/config/dhcp
		echo "== resolv"; cat /tmp/resolv.conf.d/resolv.conf.auto 2>&1'
fi
if running shadow-vpn; then
	grab vpn-xray.txt docker exec shadow-vpn sh -c 'tail -n 500 /tmp/xray.log; echo "== access"; tail -n 500 /tmp/xray-access.log'
fi
if running shadow-web; then
	grab web-dnsmasq.txt docker exec shadow-web tail -n 1000 /tmp/dnsmasq-web.log
fi
echo "logs in $OUT"
