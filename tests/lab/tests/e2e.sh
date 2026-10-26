#!/bin/bash
# End-to-end proofs for the Shadow lab (run on the Docker host after ./up.sh with MODE=deps).
# Every check prints PASS/FAIL; web echoes "src=<ip>": 203.0.113.2 = direct (router WAN), 203.0.113.20 = via vpn-server.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LUCI_PORT="${LUCI_PORT:-8080}"
ROOT_PW="${ROOT_PW:-shadow-lab}"
DIRECT="src=203.0.113.2 "; TUNNEL="src=203.0.113.20 "
pass=0; fail=0
R() { docker exec shadow-router sh -c "$1" 2>&1; }
C() { docker exec shadow-client sh -c "$1" 2>&1; }
check() { # name expected-substring actual
  if printf '%s' "$3" | grep -qF -- "$2"; then pass=$((pass+1)); printf 'PASS  %-34s %s\n' "$1" "$(printf '%s' "$3" | head -1 | cut -c1-90)"
  else fail=$((fail+1)); printf 'FAIL  %-34s want "%s" got: %s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ' | cut -c1-160)"; fi; }

R 'command -v xray >/dev/null' >/dev/null || { echo "router has no xray (MODE=factory?) - install Shadow deps first"; exit 2; }
XRAY_MAJOR=$(R 'xray version | sed -n "1s/^Xray \([0-9]*\)\..*/\1/p"')
CFG=router-client.json; [ "$XRAY_MAJOR" -ge 26 ] 2>/dev/null || CFG=router-client-xray25.json
push() { docker exec -i shadow-router sh -c "mkdir -p /tmp/lab && cat > '$2'" < "$1"; }
push "$HERE/state/$CFG" /tmp/lab/client.json
push "$HERE/tests/tproxy.nft" /tmp/lab/tproxy.nft
push "$HERE/tests/kernel-probe.sh" /tmp/lab/kernel-probe.sh

echo "== router: $(R '. /etc/openwrt_release; echo $DISTRIB_DESCRIPTION $DISTRIB_ARCH') kernel $(R 'uname -r'), xray $(R 'xray version | head -1 | cut -d" " -f2'), $(R 'ssh -V' | cut -d, -f1)"

echo "== 1. kernel features (host kernel, apk kmods are not loadable)"
probe=$(R 'sh /tmp/lab/kernel-probe.sh'); echo "$probe" | sed 's/^/      /'
check "nft tproxy ip/ip6 + socket + fib" "OK" "$(echo "$probe" | grep -c '^FAIL' | sed 's/^0$/OK/')"

echo "== 2. procd services: xray + ssh -D (respawn)"
R 'cat > /etc/init.d/shadow-lab <<"EOF"
#!/bin/sh /etc/rc.common
# lab-only stand-in for the future shadow-vpn init script
START=99
USE_PROCD=1
start_service() {
	mkdir -p /tmp/shadow-test
	procd_open_instance xray
	procd_set_param command /usr/bin/xray run -c /tmp/lab/client.json
	procd_set_param respawn 3600 2 5
	procd_set_param stderr 1
	procd_close_instance
	procd_open_instance ssh
	procd_set_param command /usr/bin/ssh -N -T -D 127.0.0.1:1080 -i /root/.ssh/id_ed25519 \
		-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/tmp/shadow-test/known_hosts \
		-o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 vpnuser@203.0.113.20
	procd_set_param respawn 3600 2 0
	procd_set_param stderr 1
	procd_close_instance
}
EOF
chmod +x /etc/init.d/shadow-lab; /etc/init.d/shadow-lab restart' >/dev/null
sleep 3
check "procd runs xray" "running" "$(R 'ubus call service list "{\"name\":\"shadow-lab\"}" | grep -c "\"running\": true" | sed "s/^2$/running/"')"

echo "== 3. every outbound type from the router (socks -> outbound -> vpn-server)"
for p in 20001:vless-reality-vision 20002:vless-xhttp-reality 20003:vmess-ws 20004:trojan-tls-pinned 20005:hysteria2 20006:vless-mkcp 20007:ssh-D-chain; do
  if [ "${p%%:*}" = 20005 ] && [ "$CFG" != router-client.json ]; then echo "SKIP  ${p#*:} (xray $XRAY_MAJOR has no hysteria)"; continue; fi
  if [ "${p%%:*}" = 20006 ] && [ "$CFG" != router-client.json ]; then echo "XFAIL ${p#*:} (mKCP 25.1 client <-> 26.3 server incompatible)"; continue; fi
  check "${p#*:}" "$TUNNEL" "$(R "curl -s -m 10 --socks5-hostname 127.0.0.1:${p%%:*} http://203.0.113.10/")"
done

echo "== 4. split tunnel: dnsmasq-full nftset -> tproxy -> xray / ssh"
R 'nft delete table inet shadow_test 2>/dev/null; nft -f /tmp/lab/tproxy.nft
   ip rule del fwmark 0x105 lookup 105 2>/dev/null; ip rule add fwmark 0x105 lookup 105 pref 105
   ip route replace local default dev lo table 105
   sec=$(uci show dhcp.@dnsmasq[0] | head -1 | cut -d. -f2 | cut -d= -f1)
   printf "nftset=/tunnel.shadow.lab/4#inet#shadow_test#via_xray4\nnftset=/ssh.shadow.lab/4#inet#shadow_test#via_ssh4\n" > /tmp/dnsmasq.$sec.d/shadow-test.conf
   /etc/init.d/dnsmasq restart' >/dev/null
sleep 2
check "direct.shadow.lab stays direct" "$DIRECT" "$(C 'curl -s -m 8 http://direct.shadow.lab/')"
check "tunnel.shadow.lab via xray tproxy" "$TUNNEL" "$(C 'curl -s -m 8 http://tunnel.shadow.lab/')"
check "nftset filled by dnsmasq" "203.0.113.11" "$(R 'nft list set inet shadow_test via_xray4')"
check "ssh.shadow.lab via ssh -D tproxy" "$TUNNEL" "$(C 'curl -s -m 8 http://ssh.shadow.lab/')"
check "https (TLS sniff) via xray" "200" "$(C 'curl -sk -m 8 -o /dev/null -w %{http_code} https://tunnel.shadow.lab/')"
check "UDP (DNS to .11) via xray" "203.0.113.20" "$(C 'dig +short +time=3 +tries=1 @203.0.113.11 vpn.shadow.lab')"
check "xray access log saw tproxy" "[tproxy-xray -> reality]" "$(R 'cat /tmp/shadow-test/access.log')"

echo "== 5. full tunnel (catch-all rule; LAN/router-local stay local)"
R 'nft add rule inet shadow_test prerouting meta l4proto { tcp, udp } meta mark set 0x105 tproxy ip to 127.0.0.1:12345 counter accept comment \"full\"' >/dev/null
check "unlisted IP now tunnelled" "$TUNNEL" "$(C 'curl -s -m 8 http://203.0.113.10/')"
check "real Internet via vpn-server" "200" "$(C 'curl -s -m 12 -o /dev/null -w %{http_code} https://downloads.openwrt.org/')"
check "router LuCI still local" "200" "$(C 'curl -s -m 5 -o /dev/null -w %{http_code} http://192.168.77.1/')"
R 'nft delete rule inet shadow_test prerouting handle $(nft -a list chain inet shadow_test prerouting | sed -n "s/.*comment \"full\".*# handle //p")' >/dev/null
check "back to split: unlisted direct" "$DIRECT" "$(C 'curl -s -m 8 http://203.0.113.10/')"

echo "== 6. resilience"
R 'kill -9 $(pidof xray)' >/dev/null; sleep 4
check "procd respawned xray" "$TUNNEL" "$(C 'curl -s -m 8 http://tunnel.shadow.lab/')"
R 'kill -9 $(pidof ssh)' >/dev/null; sleep 4
check "procd respawned ssh -D" "$TUNNEL" "$(C 'curl -s -m 8 http://ssh.shadow.lab/')"
R 'nft flush set inet shadow_test via_xray4' >/dev/null
C 'dig +short tunnel.shadow.lab' >/dev/null
check "cache hit does NOT refill nftset" "EMPTY" "$(R 'nft list set inet shadow_test via_xray4 | grep -q elements && echo FILLED || echo EMPTY')"
R 'for p in $(pidof dnsmasq); do [ "$(cat /proc/$p/comm)" = dnsmasq ] && kill -HUP $p; done' >/dev/null; sleep 1
C 'dig +short tunnel.shadow.lab' >/dev/null
check "SIGHUP (cache flush) refills nftset" "203.0.113.11" "$(R 'nft list set inet shadow_test via_xray4')"

echo "== 7. fw4 software flow offload (lab: br-lan over veth -> not engaged; see README)"
R 'uci set firewall.@defaults[0].flow_offloading=1; uci commit firewall; fw4 reload; nft insert rule inet fw4 forward ip saddr 203.0.113.10 tcp sport 80 counter comment \"offload-probe\"' >/dev/null
C 'curl -s -m 20 -o /dev/null http://203.0.113.10/big' >/dev/null
fwd=$(R 'nft list chain inet fw4 forward | sed -n "s/.*counter packets \([0-9]*\).*offload-probe.*/\1/p"')
echo "      forward-chain packets for a 20 MB direct download: $fwd (offloaded flow would show ~1-3)"
check "tunnel still works with offload on" "$TUNNEL" "$(C 'curl -s -m 8 http://tunnel.shadow.lab/')"
R 'uci delete firewall.@defaults[0].flow_offloading; uci commit firewall; fw4 reload' >/dev/null

echo "== 8. LuCI from the host (via lan-client relay)"
check "LuCI login root/test-pw" "302" "$(curl -s -m 5 -o /dev/null -w %{http_code} --data "luci_username=root&luci_password=$ROOT_PW" http://127.0.0.1:$LUCI_PORT/cgi-bin/luci/)"

echo "== 9. memory (VmRSS, kB)"
R 'for n in xray ssh dnsmasq; do for p in $(pidof $n); do [ "$(cat /proc/$p/comm)" = "$n" ] && printf "      %-8s %s\n" $n "$(sed -n "s/^VmRSS:[^0-9]*//p" /proc/$p/status)"; done; done'

echo "== result: $pass passed, $fail failed"
[ "$fail" = 0 ]
