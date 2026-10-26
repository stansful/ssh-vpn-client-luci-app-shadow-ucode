#!/bin/sh
# Runs inside shadow-router (via docker exec) right after procd finished booting.
# $1 = root password for LuCI/ssh (test value)
set -u
PW="$1"
# 1) Docker bind-mounts its own /etc/resolv.conf (127.0.0.11). Use OpenWrt's (dnsmasq) like the real box.
umount /etc/resolv.conf 2>/dev/null; rm -f /etc/resolv.conf; ln -s /tmp/resolv.conf /etc/resolv.conf
# 2) Test root password (factory = empty password, LuCI accepts it but warns).
printf '%s\n%s\n' "$PW" "$PW" | passwd root >/dev/null 2>&1
# 3) Lab DNS zone shadow.lab served by the "web" container; allow its 203.0.113.x answers through rebind protection.
uci -q del_list dhcp.@dnsmasq[0].server='/shadow.lab/203.0.113.10'
uci add_list dhcp.@dnsmasq[0].server='/shadow.lab/203.0.113.10'
uci -q del_list dhcp.@dnsmasq[0].rebind_domain='shadow.lab'
uci add_list dhcp.@dnsmasq[0].rebind_domain='shadow.lab'
uci commit dhcp
/etc/init.d/dnsmasq restart >/dev/null 2>&1
# 4) SSH key the router uses for ssh -D to the vpn-server (copied in by up.sh to /tmp/lab/).
mkdir -p /root/.ssh && chmod 700 /root/.ssh
[ -f /tmp/lab/router_id_ed25519 ] && cp /tmp/lab/router_id_ed25519 /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519
# 5) Never run OpenWrt's K90umount ("umount -a -d -r") at shutdown: in a container it finds the cgroup2
#    mount busy and remounts it read-only, and that superblock is shared by the whole Docker VM, so no
#    container could start or be exec'd afterwards (lab: one "docker restart shadow-router" did it).
/etc/init.d/umount disable 2>/dev/null
rm -f /etc/rc.d/K*umount
true
