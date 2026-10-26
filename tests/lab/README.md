# Shadow OpenWrt lab (Cudy TR3000 firmware userland in Docker)

Local, throwaway test lab for `shadow-vpn` / `luci-app-shadow-vpn`. Runs on any arm64 Docker host, so the aarch64
router rootfs runs natively: OrbStack on Apple Silicon, a Linux arm64 machine, GitHub's `ubuntu-24.04-arm` runners
(CI, `.github/workflows/ci.yml`).

```
./up.sh                         # 25.12.6 (apk), Shadow deps preinstalled (MODE=deps)   ~12 s warm
MODE=factory ./up.sh            # pristine factory TR3000 rootfs -> test install.sh from scratch
OWRT_VER=24.10.8 ./up.sh        # same device, 24.10.8 (opkg, xray-core 25.1.30)
SHADOW_SRC=$(cd ../.. && pwd) ./up.sh   # this repository, bind-mounted read-only at /mnt/shadow-src in the router
BUILD_ONLY=1 ./up.sh            # only download + verify firmware, build the images and the lab secrets (state/)
PRINT_FIRMWARE=1 ./up.sh        # version=, file=, sha256= of the firmware image (the CI cache key), nothing else
./tests/e2e.sh                  # research proofs, 26 checks on 25.12.6 (24 + SKIP hy2 + XFAIL mKCP on 24.10.8);
                                # only on a lab without Shadow installed: it binds the same ports (12345, 12346)
./e2e-shadow.sh                 # Shadow itself: build, install.sh from a lab package server, scenario checks
./e2e-shadow.sh stage2          # failure handling (about 5 min; install + stage1 + stage2 about 6 min)
./e2e-shadow.sh stage3          # restart/reload, power cuts, LuCI, keep list, blocked install, upgrade, uninstall
                                # (install + stage1 + stage2 + stage3 on a fresh lab: about 8 min)
./down.sh                       # remove lab containers + networks (label com.shadow.testenv=1); images kept
```

## Shadow scenario checks (`e2e-shadow.sh`)

```
./e2e-shadow.sh                  # install + stage1 (build, install.sh, main paths)
./e2e-shadow.sh stage1           # only the checks, on what is installed
./e2e-shadow.sh stage2           # failure handling, on what is installed
./e2e-shadow.sh stage2.ssh       # one group of stage2 (killswitch_xray, fallback_xray, xray_crash, quic,
                                 # routing_edits, both_sets, port_forward, dnsmasq, ssh, heal, end)
./e2e-shadow.sh stage3           # boot, LuCI, keep list, blocked install, upgrade, removal (about 1.5 min)
./e2e-shadow.sh stage3.boot      # one group of stage3 (boot, luci, keep, blocked, upgrade, uninstall, mock, end)
SKIP_BUILD=1 ./e2e-shadow.sh     # install out/ as it is
```

* `install`: `build/mk_apk.sh`, then a throwaway `shadow-pkgsrv` (203.0.113.30, nginx) serves `out/` and install.sh;
  the router runs `wget …/install.sh` + `SHADOW_BASE_URL=http://203.0.113.30 sh install.sh`. Fresh install: Shadow off,
  nothing armed, LuCI Services → Shadow present, LAN unchanged. Upgrade: `enabled` kept, tunnel back up.
* `stage1`: SSH (servers "Lab password", "Lab key") split mode with the rule `tunnel.shadow.lab` and full mode
  (the router's NTP names resolve through the WAN DNS, never the tunnel), the direct list (a fixture list naming
  `direct.shadow.lab`), `dns_upstream_leak`, all six Xray links, Off/On.
  It ends with Shadow **on**: Xray profile `lab-vless-kcp`, full mode, `tunnel_dns=1`, kill switch on.
* `stage2`: failure handling. The VPN server goes away (an nft table `inet lab_block` on shadow-vpn: `drop` =
  unreachable, `refuse` = TCP reset as from a stopped sshd) with the kill switch (blocked at once once detected, names
  neither resolve nor reach the ISP resolver, direct names keep working, back on its own) and in fallback mode
  (tunnelled destinations go direct); xray `kill -9` (reset at once, procd respawn); a crash loop with a config xray
  rejects (a wrapper `/usr/bin/xray` → `xray.real` that exits 23 while `/tmp/e2e-xray-rejects` exists: gate opens in
  fallback mode, fatal attention, no restarts, Connect again after the fix); an xray-only change in SSH mode (the
  kill switch: ssh keeps its session and the phase stays Connected), SSH refused, `ifup wan` during a long
  backoff, a wrong password (one attempt, nothing for a minute), a swapped host key (originals kept in
  shadow-vpn:`/etc/ssh/orig`) and "Pin this key" (only the fingerprint the page showed); `fw4 reload`, firewall
  stop/start, network restart; rule edits and a
  profile switch while connected; a port forward `wan:9000 → shadow-client:9000` (redirect `firewall.e2e_pf`); one
  address in the proxy and the direct set; dnsmasq with its own `serversfile`, and a conf-dir file that clashes with
  ours (`zz-e2e.conf`, `max-ttl=600`); QUIC rejects. Every group cleans up after itself, and `stage2_cleanup` removes
  what an interrupted run left. It ends in the stage1 end state.
* `stage3`: the life cycle around Shadow. Groups: `boot` (`/etc/init.d/shadow-vpn restart` and `reload` keep it
  connected; power cuts with `autostart=1`, an Off cut short before its teardown, `autostart=0`), `luci` (every rpc
  method with the router's data, the six pages and their JS from the LAN, the Russian catalog, the `/ubus` ACL, and
  that the router offers exactly the methods tested), `keep` (`sysupgrade -l`/`-b`), `blocked` (install.sh while
  Shadow is on with the kill switch in full mode and the VPN server is blocked: it stops before any download with the
  Russian/English hint), `upgrade` (a build of the next patch version into `out/upgrade/`), `uninstall`
  (`install.sh --uninstall` and `apk del`: packages, data plane and the procd service with its triggers gone, each
  followed by a reinstall that stays off), `mock` (no design mock left,
  LuCI files are the packaged ones), `end`. A lab-only `/etc/init.d/zz-e2e-boot` (the last S99) marks the end of a
  boot. It ends with Shadow installed and **off** and dnsmasq's settings as before it.
* Reboots are power cuts (`docker kill` + `docker start`): see the K90umount gotcha below.
* Lines are `ok …` / `not ok …: why` and `# measured …`; exit 1 on any failure. Waits poll with a deadline;
  "nothing happens for N s" checks sample every 2 s over the window.

## Host requirements

* An arm64 Docker Engine **28 or newer**: the router's WAN/LAN interfaces are pinned to eth0/eth1 with the endpoint
  driver-opt `com.docker.network.endpoint.ifname`, which older engines ignore (up.sh checks the MACs and stops).
* A host kernel with nftables, tproxy and socket matching (`nft_tproxy`, `nft_socket`, `nft_fib_inet`,
  `nft_reject_inet`, `nft_redir`, …): the router's own kmod packages cannot load into the host kernel, nftables loads
  the host's modules on demand. `tests/lab/tests/kernel-probe.sh` (run by `tests/e2e.sh`) lists what works. On Ubuntu
  some of these modules are in `linux-modules-extra-$(uname -r)`; CI loads them before the lab starts.
* `br_netfilter` does not matter: when the host kernel has it loaded (OrbStack does), up.sh turns its sysctls off in
  the router's namespace; without it there is nothing to turn off (`lib/host.sh`). On a host whose bridged traffic
  passes through iptables (`bridge-nf-call-iptables=1` in the host's namespace, common on Linux), Docker's default
  "nat" gateway mode drops every packet to a container address that arrives from another bridge, which includes
  the LAN client's direct connections to shadow-web: up.sh creates both lab networks with
  `com.docker.network.bridge.gateway_mode_ipv4=nat-unprotected`, and its smoke check stops when the LAN cannot reach
  the web directly.
* bash, curl, jq and perl (Time::HiRes) for the scripts; python3 for `tests/unit/packaging/install_test.sh`;
  Node.js 22.18+ for `tests/unit/luci/check_views.mjs`. GNU or BSD userland both work.
* Internet access: the OpenWrt package feed, GitHub (domain lists), 1.1.1.1 (DoH through the tunnel).
* Files the lab writes into `state/` belong to the host user (a container writes them as root; on Linux a bind mount
  keeps root's ids, so `lib/gen-state.sh` hands them back).

## CI

`.github/workflows/ci.yml` runs on every push to a branch other than `master` and every pull request on GitHub's `ubuntu-24.04-arm`: job `unit`
(`BUILD_ONLY=1 up.sh` with `dl/` cached by firmware version and sha256, `tests/unit/run.sh`, `check_views.mjs`,
`scripts/build-release.sh`, `out/` as an artifact), job `host-docker` (`install_test.sh`, which also installs
the latest release published on GitHub with the tree's install.sh, `rpcd-smoke.sh`, `ssh/e2e.sh`) and job `lab`
(`up.sh`, then `e2e-shadow.sh install stage1 stage2 stage3`; the router's logs and state are an artifact when it
fails, `lib/collect-logs.sh`). A push to `master` is tested by `.github/workflows/release.yml`, which runs the same
workflow (`workflow_call`; `ci.yml` ignores pushes to `master`) and builds and publishes a release only after it
passes.

## Credentials (test values only, never reuse)

| what | value |
|---|---|
| LuCI / router ssh | http://127.0.0.1:8080/ , `ssh -p 2222 root@127.0.0.1`, user `root`, password `shadow-lab` (override `ROOT_PW=`) |
| factory LuCI | before router-init sets it, root has an EMPTY password (`root:::`) and LuCI accepts it |
| vpn-server ssh | `vpnuser@203.0.113.20`, key `state/router_id_ed25519` (copied to router `/root/.ssh/id_ed25519`), password in `state/ssh.pw` |
| xray server | secrets in `state/` (uuid, x25519.txt, shortid, trojan.pw, hy2.pw, vpn.crt.sha256); share links in `state/links.txt` (also `/tmp/lab/links.txt` on the router) |

`rm -rf state/` rotates every secret on the next `./up.sh`.

## Topology

```
 host 127.0.0.1:8080/2222 --> shadow-client (socat relay) --> LuCI/ssh on 192.168.77.1 (LAN side, like a real PC)

 shadow-lan 192.168.77.0/24                      shadow-wan 203.0.113.0/24 (TEST-NET-3; Docker gw .1 NATs to the Internet)
 shadow-client .10 --- eth1 [br-lan .1] shadow-router [eth0 .2] --- shadow-web .10 .11 .12 + 198.51.100.10 (nginx echo "src=<ip>", TLS1.3, DNS zone shadow.lab)
 (default route + DNS = router)                                  \-- shadow-vpn .20  (sshd + xray 26.3.27: reality-vision:443,
                                                                                       xhttp+reality:8443, vmess-ws:10002, trojan-tls:10003,
                                                                                       hysteria2:8444/udp, vless-mkcp:10005/udp)
 web says src=203.0.113.2  -> direct;  src=203.0.113.20 -> tunnelled   (UDP echo on :7777 and :443 of .10/.11/.12 says udp-src=<ip>)
 shadow-vpn has NET_ADMIN (stage2 blocks the router there with nft). 198.51.100.10 on shadow-web is the port-forward
 peer; the router routes it via 203.0.113.10 (UCI route lab_peer).
 DNS: direct.shadow.lab=.10  tunnel.shadow.lab=.11  ssh.shadow.lab=.12  vpn.shadow.lab=.20 (local-ttl 120)
 shadow-web's dnsmasq is the lab "ISP resolver": it answers shadow.lab and forwards every other name to 1.1.1.1/8.8.8.8.
 The router's WAN DNS and shadow-vpn's resolv.conf point at it, so the VPN server can dial sniffed lab names.
 shadow-pkgsrv .30 (only while e2e-shadow.sh installs): nginx serving out/ and install.sh for SHADOW_BASE_URL.
```

Tunnel DNS (`tunnel_dns=1`) resolves through DoH at 1.1.1.1 from the VPN server, which does not know shadow.lab:
split-mode checks of lab names run with `tunnel_dns=0`; tunnel DNS itself is checked with public names. In full mode
the router's per-domain `server=/shadow.lab/203.0.113.10` (router-init) keeps lab names resolvable.

WAN is TEST-NET-3 on purpose: the desktop app's bypass list
([`policy.go` `localPrefixes`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/native/service-go/internal/dataplane/policy.go))
treats RFC1918/CGNAT as local,
so a 10.x "internet" could never be tunnelled in full-tunnel mode. Router dnsmasq gets `server=/shadow.lab/203.0.113.10`
and `rebind_domain shadow.lab` (dnsmasq treats TEST-NETs as private for rebind protection). That per-domain line is not
a plain upstream, so Shadow's `dns_upstream_leak` attention does not count it.

## How the router container is built

* Image = the official `openwrt-<ver>-mediatek-filogic-cudy_tr3000-256mb-v1-squashfs-sysupgrade.bin`
  (sha256 checked against the release `sha256sums`), `tar -xO sysupgrade-*/root` -> `unsquashfs` -> `docker import`.
  Exact r33311 userland, `aarch64_cortex-a53`, same package set as the flashed router (LuCI preinstalled).
  Docker Hub `openwrt/rootfs` has no 25.12 cortex-a53/filogic tag (only `armsr-armv8-25.12.x` = `aarch64_generic`).
* `docker create ... /sbin/init` with NET_ADMIN, NET_RAW, SYS_ADMIN, seccomp/apparmor unconfined (procd mounts + ujail need it).
* `--sysctl net.bridge.bridge-nf-call-iptables=0` (+ip6tables, arptables) when the host kernel has br_netfilter loaded
  (OrbStack does): with it on, tproxy of bridged LAN traffic silently fails (SYN tproxied, no SYN-ACK). Real OpenWrt
  has no br_netfilter. `lib/host.sh` asks a throwaway container which of these per-namespace sysctls exist.
* Interface names pinned with `driver-opt=com.docker.network.endpoint.ifname=eth0|eth1` to match TR3000 board.d
  (`ucidef_set_interfaces_lan_wan eth1 eth0`; Docker Engine 28+, checked after start), `files/router/etc/config/network`
  is copied in before first boot (board_detect cannot identify the board in a container). WAN is `proto static` (no
  DHCP server on Docker networks).
* After boot (`lib/router-init.sh`): unmount Docker's `/etc/resolv.conf` bind-mount and symlink `/tmp/resolv.conf`,
  set the test root password, lab DNS zone, ssh key.

## Gotchas found while building it

* `docker cp` cannot write into the router's `/tmp` (procd's own tmpfs). Stream files: `docker exec -i shadow-router sh -c 'cat > /tmp/x' < x`.
* `-p` published on the router lands on its WAN endpoint (fw4 rejects) even with `gw-priority` on LAN -> relay via lan-client.
* Never `mount -o remount,rw /proc/sys` in the router: non-namespaced sysctls (kernel.*, vm.*) would hit the whole Docker
  host (OrbStack's VM, or the Linux machine itself).
  Use `--sysctl net.*=` at create time; OpenWrt's own sysctl.d writes fail harmlessly (read-only /proc/sys).
* OrbStack bind mounts served a stale copy of a file replaced via `mv`; scripts are fed via stdin (`sh -s < file`).
* busybox ash: `$(...)` inside a heredoc inside a function body breaks parsing; precompute into variables.
* busybox `sleep` has no fractions; `timeout` is not in the TR3000 image.
* Docker (with br_netfilter, as on OrbStack) masquerades a 203.0.113.x source that leaves through another bridge: a connection
  forwarded from the WAN reached the LAN client as 192.168.77.254 and was reset. Port-forward checks use the peer
  198.51.100.10, which no Docker rule touches.
* `socat UDP4-RECVFROM` on 0.0.0.0 answers from the primary address only: bind one echo per address.
* `pgrep -f`/`pkill -f` inside `sh -c '…'` also match that shell's own command line; write patterns as `[s]shd…`.
  The router's busybox has `pgrep` but no `pkill`.
* rc.common holds its procd lock (`/var/lock/procd_<service>.lock`) on fd 1000 during every action, and busybox
  `start-stop-daemon -b` does not close it: a daemon started from an init script keeps that lock, and every later
  `/etc/init.d/<service> …` (even `status`) hangs. Start daemons with `1000>&-` (Shadow's init script closes it for
  every helper it runs).
* `e2e-shadow.sh` also runs under macOS `/bin/bash` 3.2, which brace-expands `"{\"a\":1,\"b\":2}"` inside a `"$(…)"`
  command argument (an assignment is fine): put JSON with a comma into a variable first.
* Do not edit `e2e-shadow.sh` while it runs: bash reads the file as it goes, and the end of the run fails.
* procd logs `failed adding instance cgroup ... Operation not permitted` (cgroup2 is read-only): cgroup limits untestable.
* **Never shut the router down gracefully while OpenWrt's `K90umount` is enabled** (`docker restart`/`docker stop`
  or `reboot` inside run procd's shutdown, which runs `umount -a -d -r`): it finds the container's cgroup2 mount
  busy and remounts it read-only, and that superblock is shared by the whole Docker host (OrbStack's VM, or a Linux
  machine's own `/sys/fs/cgroup`). Afterwards no container can start and `docker exec` fails ("read-only file
  system" under `/sys/fs/cgroup/docker/...`) until that host restarts (lab, stage 3; OrbStack: `orb restart docker`).
  `lib/router-init.sh` disables `umount`; `e2e-shadow.sh` reboots the router with a power cut (`docker kill` +
  `docker start`, no userland shutdown at all) and refuses to if `K90umount` is back. Remove lab containers with
  `down.sh` or `docker rm -f` (SIGKILL), never `docker stop`. The throwaway routers of `install_test.sh` and
  `rpcd-smoke.sh` keep `K90umount` and are only ever removed with `docker rm -f`.
