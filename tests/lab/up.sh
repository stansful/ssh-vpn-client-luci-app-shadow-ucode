#!/bin/bash
# Shadow OpenWrt lab: Cudy TR3000 firmware userland in Docker on an arm64 host (linux/arm64 natively):
# OrbStack on Apple Silicon, a Linux arm64 machine with Docker Engine 28+, GitHub's ubuntu-24.04-arm runners.
#
#   ./up.sh                      # 25.12.6 (apk) router with Shadow deps preinstalled (MODE=deps)
#   MODE=factory ./up.sh         # pristine factory rootfs: test install.sh from scratch
#   OWRT_VER=24.10.8 ./up.sh     # opkg-based 24.10 firmware of the same device
#   SHADOW_SRC=$PWD ./up.sh      # this repository, bind-mounted read-only at /mnt/shadow-src in the router
#   ./tests/e2e.sh               # proofs (needs MODE=deps)
#   ./down.sh                    # remove containers + networks (images are kept)
#   BUILD_ONLY=1 ./up.sh         # only download/verify firmware, build the images and the lab secrets (state/)
#   PRINT_FIRMWARE=1 ./up.sh     # print version=, file= and sha256= of the firmware image (CI cache key), nothing else
#
# Topology (all static IPs):
#   shadow-lan 192.168.77.0/24 : shadow-client .10  -- eth1/br-lan .1 [shadow-router] eth0 .2 -- shadow-wan 203.0.113.0/24
#   shadow-wan 203.0.113.0/24  : shadow-web .10/.11/.12 + 198.51.100.10 (HTTP echo, TLS, UDP echo :7777/:443, DNS: zone shadow.lab + recursion
#                                = the lab ISP resolver), shadow-vpn .20 (sshd + xray)
#                                docker gateway .1 NATs to the real Internet (apk feeds, 1.1.1.1)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OWRT_VER="${OWRT_VER:-25.12.6}"
PROFILE="${PROFILE:-cudy_tr3000-256mb-v1}"
TARGET="mediatek/filogic"
MODE="${MODE:-deps}"
LUCI_PORT="${LUCI_PORT:-8080}"
SSH_PORT="${SSH_PORT:-2222}"
SHADOW_SRC="${SHADOW_SRC:-}"
ROOT_PW="${ROOT_PW:-shadow-lab}"          # throwaway LuCI/ssh password of the lab router
XRAY_IMG="ghcr.io/xtls/xray-core:26.3.27"
ALPINE_IMG="alpine:3.22"
LABEL="com.shadow.testenv=1"

IMG_ROOTFS="shadow-testenv/tr3000-rootfs:$OWRT_VER"
IMG_DEPS="shadow-testenv/tr3000-deps:$OWRT_VER"
IMG_TOOLS="shadow-testenv/tools:alpine3.22"
IMG_VPN="shadow-testenv/vpn:xray26.3.27"
DL="$HERE/dl/$OWRT_VER"
STATE="$HERE/state"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
have_img() { docker image inspect "$1" >/dev/null 2>&1; }
# shellcheck source=lib/host.sh
. "$HERE/lib/host.sh"

# 1) Official firmware for the exact device, verified against the release sha256sums.
BIN="openwrt-$OWRT_VER-mediatek-filogic-$PROFILE-squashfs-sysupgrade.bin"
URL="https://downloads.openwrt.org/releases/$OWRT_VER/targets/$TARGET"
mkdir -p "$DL"
# firmware_sha: the release's sha256 of $BIN (sha256sums is kept in dl/ with the image)
firmware_sha() {
  [ -s "$DL/sha256sums" ] || curl -fsSL -o "$DL/sha256sums" "$URL/sha256sums"
  want="$(grep -E "[ *]$BIN\$" "$DL/sha256sums" | cut -d' ' -f1)"
  [ -n "$want" ] || die "$BIN is not in $URL/sha256sums"
}
if [ "${PRINT_FIRMWARE:-0}" = 1 ]; then
  firmware_sha
  printf 'version=%s\nfile=%s\nsha256=%s\n' "$OWRT_VER" "$BIN" "$want"
  exit 0
fi

[ "$(docker version --format '{{.Server.Arch}}')" = "arm64" ] ||
  die "needs an arm64 Docker engine (OrbStack on Apple Silicon, a Linux arm64 host): the router rootfs is aarch64"

if ! have_img "$IMG_ROOTFS"; then
  firmware_sha
  [ -s "$DL/$BIN" ] || { log "download $BIN"; curl -fsSL -o "$DL/$BIN" "$URL/$BIN"; }
  got="$(sha256_of "$DL/$BIN")"
  [ "$want" = "$got" ] || die "sha256 mismatch for $BIN"

  # 2) sysupgrade.bin = tar{ sysupgrade-<board>/kernel, /root (squashfs) } -> rootfs tarball -> docker import
  log "build $IMG_ROOTFS from the device squashfs"
  docker run --rm -v "$DL:/dl:ro" "$ALPINE_IMG" sh -euc '
      apk add -q --no-cache squashfs-tools >&2
      member=$(tar -tf /dl/'"$BIN"' | grep "/root$")
      tar -xOf /dl/'"$BIN"' "$member" > /tmp/root.sqfs
      unsquashfs -q -n -d /tmp/r /tmp/root.sqfs >&2
      tar -C /tmp/r -c .' \
    | docker import --platform linux/arm64 --change 'CMD ["/sbin/init"]' - "$IMG_ROOTFS" >/dev/null
fi

# 3) Router image with Shadow's runtime deps (fast iterations) unless MODE=factory.
ROUTER_IMG="$IMG_ROOTFS"
if [ "$MODE" = deps ]; then
  have_img "$IMG_DEPS" || { log "build $IMG_DEPS"; docker build -q --build-arg BASE="$IMG_ROOTFS" -t "$IMG_DEPS" -f "$HERE/build/router-deps.Dockerfile" "$HERE/build" >/dev/null; }
  ROUTER_IMG="$IMG_DEPS"
fi

# 4) Helper images.
have_img "$IMG_TOOLS" || { log "build $IMG_TOOLS"; docker build -q -t "$IMG_TOOLS" -f "$HERE/build/tools.Dockerfile" "$HERE/build" >/dev/null; }
have_img "$IMG_VPN"   || { log "build $IMG_VPN";   docker build -q --build-arg XRAY_IMG="$XRAY_IMG" --build-arg TOOLS_IMG="$IMG_TOOLS" -t "$IMG_VPN" -f "$HERE/build/vpn.Dockerfile" "$HERE/build" >/dev/null; }

# 5) Throwaway secrets + xray server/client configs + share links (kept across runs; rm -rf state/ to rotate).
#    Written as root in the container, then given to the host user (on Linux, a bind mount keeps root's ids).
mkdir -p "$STATE"
docker run --rm -i -e HOST_IDS="$(id -u):$(id -g)" -v "$STATE:/s" "$IMG_VPN" sh -s < "$HERE/lib/gen-state.sh" >/dev/null

[ "${BUILD_ONLY:-0}" = 1 ] && { log "images and state ready (BUILD_ONLY)"; exit 0; }
docker ps -a --format '{{.Names}}' | grep -qx shadow-router && die "lab already up - run ./down.sh first"

# 6) Networks. gateway_mode_ipv4=nat-unprotected (Docker Engine 28+): in its default "nat" mode Docker drops, in the
#    host's raw PREROUTING, every packet to a container address that arrives from another bridge. On a host where
#    bridged traffic passes through iptables (br_netfilter with bridge-nf-call-iptables=1, as on many Linux Docker
#    hosts) that includes the LAN client's packets to shadow-web and shadow-vpn on their way to the router, which
#    are bridged on shadow-lan: every direct LAN connection would die there.
log "networks"
GW_MODE="com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected"
docker network create --label "$LABEL" -o "$GW_MODE" --subnet 203.0.113.0/24 --gateway 203.0.113.1 shadow-wan >/dev/null
docker network create --label "$LABEL" -o "$GW_MODE" --subnet 192.168.77.0/24 --gateway 192.168.77.254 shadow-lan >/dev/null

# 7) WAN side: web echo (+TLS target for REALITY, +DNS zone) and the user's own server.
log "shadow-web, shadow-vpn"
docker run -d --name shadow-web --label "$LABEL" --hostname web --cap-add NET_ADMIN \
  --network name=shadow-wan,ip=203.0.113.10 \
  -v "$HERE/files/web:/cfg:ro" -v "$STATE:/s:ro" "$IMG_TOOLS" sh -c '
    ip addr add 203.0.113.11/24 dev eth0; ip addr add 203.0.113.12/24 dev eth0
    # the port-forward peer: Docker masquerades 203.0.113.x sources that cross into the LAN bridge
    ip addr add 198.51.100.10/32 dev eth0
    cp /cfg/nginx.conf /etc/nginx/http.d/default.conf
    head -c 20000000 /dev/urandom > /srv/big.bin
    dnsmasq -C /cfg/dnsmasq.conf
    # UDP echo of the source address (tunnelled UDP says udp-src=203.0.113.20), one per address so the
    # reply comes from the address that was asked; :443 stands in for QUIC
    for a in 203.0.113.10 203.0.113.11 203.0.113.12; do for p in 7777 443; do
      socat -T 2 UDP4-RECVFROM:$p,bind=$a,fork SYSTEM:"echo udp-src=\$SOCAT_PEERADDR" &
    done; done
    exec nginx -g "daemon off;"' >/dev/null

# NET_ADMIN: e2e-shadow.sh stage2 blocks the router at this server with nft (a server that went away)
docker run -d --init --name shadow-vpn --label "$LABEL" --hostname vpn --cap-add NET_ADMIN \
  --network name=shadow-wan,ip=203.0.113.20 \
  -v "$HERE/files/vpn:/cfg:ro" -v "$STATE:/s:ro" "$IMG_VPN" sh -c '
    echo "nameserver 203.0.113.10" > /etc/resolv.conf   # the lab ISP resolver: sniffed lab names resolve
    echo "vpnuser:$(cat /s/ssh.pw)" | chpasswd >/dev/null
    install -d -m 700 -o vpnuser -g vpnuser /home/vpnuser/.ssh
    install -m 600 -o vpnuser -g vpnuser /s/router_id_ed25519.pub /home/vpnuser/.ssh/authorized_keys
    xray run -c /s/server.json > /tmp/xray.log 2>&1 &
    exec /usr/sbin/sshd -D -e -f /cfg/sshd_config' >/dev/null

# 8) The router: procd as PID 1, eth0=wan, eth1=lan (same mapping as TR3000 board.d).
log "shadow-router ($ROUTER_IMG)"
mount_src=()
[ -n "$SHADOW_SRC" ] && mount_src=(-v "$SHADOW_SRC:/mnt/shadow-src:ro")
router_sysctl_args "$IMG_TOOLS" || die "cannot probe the router's sysctls"
docker create --name shadow-router --label "$LABEL" --hostname TR3000 \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
  --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
  "${ROUTER_SYSCTLS[@]}" \
  --network name=shadow-wan,ip=203.0.113.2,driver-opt=com.docker.network.endpoint.ifname=eth0 \
  --network name=shadow-lan,ip=192.168.77.1,driver-opt=com.docker.network.endpoint.ifname=eth1 \
  ${mount_src[@]+"${mount_src[@]}"} \
  "$ROUTER_IMG" /sbin/init >/dev/null
docker cp "$HERE/files/router/etc/config/network" shadow-router:/etc/config/network
docker start shadow-router >/dev/null
check_ifnames shadow-router shadow-wan=eth0 shadow-lan=eth1 || die "WAN/LAN interfaces are not eth0/eth1 (see above)"

for i in $(seq 1 60); do
  docker exec shadow-router sh -c 'pidof dnsmasq >/dev/null && pidof uhttpd >/dev/null && pidof rpcd >/dev/null' 2>/dev/null && break
  sleep 1
  [ "$i" = 60 ] && die "router did not finish booting (docker logs shadow-router)"
done
# /tmp inside the router is procd's own tmpfs: "docker cp" cannot see it, so stream files through exec.
push() { docker exec -i shadow-router sh -c "mkdir -p \"\${1%/*}\" && cat > \"\$1\"" _ "$2" < "$1"; }
push "$STATE/router_id_ed25519" /tmp/lab/router_id_ed25519
push "$STATE/router-client.json" /tmp/lab/router-client.json
push "$STATE/links.txt"          /tmp/lab/links.txt
push "$HERE/tests/tproxy.nft"    /tmp/lab/tproxy.nft
docker exec -i shadow-router sh -s "$ROOT_PW" < "$HERE/lib/router-init.sh"

# 9) LAN client: default route + DNS via the router (Docker's own gateway .254 is not used).
#    It also relays the Mac's 127.0.0.1:$LUCI_PORT/$SSH_PORT to the router's LAN address, so LuCI is reached
#    from the LAN side like on a real box (a port published on the router itself lands on its WAN = fw4 reject).
log "shadow-client"
docker run -d --init --name shadow-client --label "$LABEL" --hostname lan-client --cap-add NET_ADMIN \
  --network name=shadow-lan,ip=192.168.77.10 -p "127.0.0.1:$LUCI_PORT:8080" -p "127.0.0.1:$SSH_PORT:2222" \
  "$IMG_TOOLS" sh -c '
    ip route replace default via 192.168.77.1
    echo "nameserver 192.168.77.1" > /etc/resolv.conf
    socat TCP-LISTEN:8080,fork,reuseaddr TCP:192.168.77.1:80 &
    socat TCP-LISTEN:2222,fork,reuseaddr TCP:192.168.77.1:22 &
    exec sleep infinity' >/dev/null

log "smoke"
# The LAN client reaches shadow-web directly through the router: polled, the router may still be settling.
smoke=
for _ in $(seq 1 30); do
  smoke="$(docker exec shadow-client curl -s -m 3 http://203.0.113.10/ 2>/dev/null)" && [ -n "$smoke" ] && break
  smoke=
  sleep 1
done
[ -n "$smoke" ] ||
  die "the LAN client cannot reach shadow-web through the router (Docker host filtering bridged traffic? tests/lab/README.md)"
echo "$smoke"
docker exec shadow-client dig +short +time=3 direct.shadow.lab || true
printf 'LuCI : http://127.0.0.1:%s/  (root / %s)\nssh  : ssh -p %s root@127.0.0.1\nshell: docker exec -it shadow-router ash\nmode : %s, image %s\n' \
  "$LUCI_PORT" "$ROOT_PW" "$SSH_PORT" "$MODE" "$ROUTER_IMG"
