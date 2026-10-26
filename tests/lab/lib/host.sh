# shellcheck shell=bash
# Docker host helpers shared by tests/lab/up.sh and tests/unit/packaging/install_test.sh (bash, sourced).
# The lab runs on any arm64 Docker host: OrbStack on Apple Silicon, a Linux arm64 machine, GitHub's
# ubuntu-24.04-arm runners. Nothing here may assume one of them.

# router_sysctl_args <probe image>: fills the array ROUTER_SYSCTLS with the --sysctl options of a router
# container (OpenWrt's own values for what Docker lets a container set).
#  - net.bridge.bridge-nf-call-*=0: with br_netfilter loaded in the host kernel (OrbStack has it, Docker on
#    Linux may load it) the router's own br-lan would pass bridged LAN traffic through netfilter, and tproxy of
#    it fails silently (SYN tproxied, no SYN-ACK). A real OpenWrt has no br_netfilter. A host without the
#    module has no such sysctls, and Docker refuses to set a sysctl that does not exist.
#  - net.netfilter.nf_conntrack_*: exist only once the host kernel has nf_conntrack loaded.
# These sysctls are per network namespace, so a throwaway container is asked (the host's own /proc says
# nothing on macOS, and the Linux host's namespace may differ). Call it after the lab's Docker networks exist:
# creating one can load br_netfilter.
router_sysctl_args() {
	local k present
	local -a always=(
		net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 net.ipv6.conf.default.forwarding=1
	)
	local -a optional=(
		net.bridge.bridge-nf-call-iptables=0 net.bridge.bridge-nf-call-ip6tables=0 net.bridge.bridge-nf-call-arptables=0
		net.netfilter.nf_conntrack_acct=1 net.netfilter.nf_conntrack_tcp_timeout_established=7440
		net.netfilter.nf_conntrack_udp_timeout=60 net.netfilter.nf_conntrack_udp_timeout_stream=180
	)
	present="$(docker run --rm --network none --entrypoint /bin/sh "$1" -c '
		for kv do
			k=${kv%%=*}
			[ -e "/proc/sys/$(echo "$k" | tr . /)" ] && echo "$kv"
		done
		exit 0' _ "${optional[@]}")" || return 1
	ROUTER_SYSCTLS=()
	for k in "${always[@]}" $present; do ROUTER_SYSCTLS+=(--sysctl "$k"); done
}

# check_ifnames <container> <network>=<ifname>...: the container's interface <ifname> is its endpoint on
# <network>. Docker Engine 28+ honours the endpoint driver-opt com.docker.network.endpoint.ifname; an older
# engine ignores it and names the interfaces in its own order, which would swap WAN and LAN.
check_ifnames() {
	local c="$1" pair net dev fmt want got engine
	shift
	for pair in "$@"; do
		net="${pair%%=*}"
		dev="${pair#*=}"
		fmt='{{(index .NetworkSettings.Networks "'"$net"'").MacAddress}}'
		want="$(docker inspect -f "$fmt" "$c")"
		got="$(docker exec "$c" cat "/sys/class/net/$dev/address" 2>/dev/null)"
		if [ -z "$want" ] || [ "$want" != "$got" ]; then
			engine="$(docker version --format '{{.Server.Version}}')"
			echo "$c: $dev is not its endpoint on $net (MAC $want, $dev has '$got')." \
				"The lab needs Docker Engine 28 or newer (driver-opt com.docker.network.endpoint.ifname); this one is $engine." >&2
			return 1
		fi
	done
}

# sha256_of <file>: sha256sum (Linux) or shasum (macOS)
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}
