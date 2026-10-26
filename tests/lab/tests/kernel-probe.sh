#!/bin/sh
# Runs inside shadow-router: which nft/iproute features does the (host) kernel accept?
P=probe_$$
nft add table inet $P
nft "add chain inet $P pre { type filter hook prerouting priority mangle; policy accept; }"
nft "add chain inet $P out { type route hook output priority mangle; policy accept; }"
nft "add set inet $P s4 { type ipv4_addr; flags interval, timeout; timeout 1h; }"
nft "add set inet $P s6 { type ipv6_addr; flags interval; }"
nft "add set inet $P dyn { type ipv4_addr; flags dynamic, timeout; timeout 5m; }"
t() { if nft add rule inet $P "$1" $2 2>/tmp/probe.err; then echo "OK   $2"; else echo "FAIL $2 :: $(head -1 /tmp/probe.err)"; fi; }
t pre 'meta l4proto { tcp, udp } ip daddr @s4 meta mark set 0x105 tproxy ip to 127.0.0.1:12345 accept'
t pre 'meta l4proto { tcp, udp } ip6 daddr @s6 meta mark set 0x105 tproxy ip6 to [::1]:12345 accept'
t pre 'meta l4proto tcp socket transparent 1 meta mark set 0x105 accept'
t pre 'meta l4proto tcp socket wildcard 0 accept'
t pre 'socket mark 0x105 accept'
t pre 'fib daddr type local return'
t pre 'ct mark 0x1 meta mark set ct mark'
t pre 'ct state new ct mark set 0x1'
t pre 'update @dyn { ip saddr limit rate 10/second }'
t pre 'numgen inc mod 2 0 accept'
t pre 'limit rate 5/second log prefix "probe " accept'
t pre 'quota over 10 mbytes accept'
t pre 'meta skuid 0 accept'
t out 'meta mark 0xff return'
t out 'ip daddr @s4 meta l4proto { tcp, udp } meta mark set 0x105'
t out 'meta skgid 0 accept'
nft delete table inet $P
ip rule add fwmark 0x105 lookup 105 pref 105 2>/dev/null; ip route replace local default dev lo table 105 && echo "OK   ip route local default dev lo table 105"
ip -6 rule add fwmark 0x105 lookup 105 pref 105 2>/dev/null && ip -6 route replace local default dev lo table 105 && echo "OK   ip -6 rule + local ::/0 dev lo table 105" || echo "FAIL ip -6 policy routing"
ip -6 rule del fwmark 0x105 lookup 105 2>/dev/null; ip -6 route flush table 105 2>/dev/null
[ -c /dev/net/tun ] && echo "OK   /dev/net/tun" || echo "n/a  /dev/net/tun (needs --device /dev/net/tun)"
grep -q nf_tables /proc/modules 2>/dev/null && echo "modules visible" || echo "info /proc/modules: $(wc -l < /proc/modules) entries (the Docker host kernel loads its own modules; apk kmods cannot load)"
ls /lib/modules/*/ 2>/dev/null | grep -cE 'tproxy|socket' | sed 's/^/info kmod .ko files on disk matching tproxy|socket: /'
