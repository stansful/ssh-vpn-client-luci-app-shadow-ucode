# Shadow for OpenWrt: design

Status: approved direction (owner, 2026-10-25): LuCI mock approved, OpenWrt 25.12+ only, kill switch on by default.
Revised after an adversarial review and lab checks (section 14 lists what changed and why). Implemented; the
lab scenario checks are `tests/lab/e2e-shadow.sh` (section 12), stages 1 (main paths), 2 (failure handling) and 3
(boot, upgrade, removal, LuCI).

Shadow for OpenWrt ports the core of the [Shadow desktop app](https://github.com/stansful/ssh-vpn-client-electron)
(repository `stansful/ssh-vpn-client-electron`, "the desktop" below) to a router: a tunnel to your own server over SSH
(`ssh -D`) or Xray (`vless://`, `vmess://`, `trojan://`, `hysteria2://`/`hy2://`), full or split routing for the
whole LAN, the itdoginfo/allow-domains Russia lists, auto-reconnect, a tunnel check and a log. It lives in
LuCI under **Services → Shadow** and installs with one command. Desktop file names below (`src/…`) and "desktop
spec §N" ([FUNCTIONAL_SPEC.md](https://github.com/stansful/ssh-vpn-client-electron/blob/master/FUNCTIONAL_SPEC.md)) refer to the desktop repository.

The reference router is a Cudy TR3000 256MB v1 (MediaTek MT7981B, `mediatek/filogic`, `aarch64_cortex-a53`),
OpenWrt 25.12.6, kernel 6.12.112. Facts marked "lab" were checked in the Docker lab, which boots the real TR3000
25.12.6 sysupgrade rootfs with procd as PID 1 (section 12).

## 1. Goals and non-goals

Goals, in priority order:

1. Low RAM and CPU on a 2×A53 router. No resident process of our own: the only long-running processes are
   `xray` and, in SSH mode, `ssh`. Our code runs on demand (procd hooks, rpcd calls, hotplug, cron, short jobs).
2. Direct traffic stays in the kernel fast path, flow offloading included. Only traffic that must be tunnelled
   enters userspace.
3. Predictable failure. With the kill switch (default) tunnelled destinations are blocked while the tunnel is
   down and everything else keeps working; without it they fall back to direct. A Shadow failure never takes
   down DNS or direct traffic, and turning Shadow off leaves the router exactly as it was.
4. Behaviour parity with the desktop app where it makes sense on a router (routing precedence, link parsing,
   host-key trust, list format, rules import/export, messages).

Not ported: the SSH terminal (the router has ttyd and users have SSH clients), tray/window/theme/update UI,
TUN/wintun/PAC/system proxy, process rules (replaced by LAN-device rules), the public profile list, sleep/wake
handling.

## 2. Supported systems

- **OpenWrt 25.12 and newer (apk).** All our packages are `noarch`; the binaries come from the official feed:
  `xray-core` 26.3.27, `openssh-client` 10.6p1, `dnsmasq-full` 2.93. Any architecture the feed builds works.
- **OpenWrt 24.10 and older are refused** by the installer (owner decision): their xray-core 25.1.30 has no
  Hysteria 2, an mKCP that does not talk to 26.x servers and different REALITY/pinning fields.
- Disk: about 45 MB on `/overlay` (xray-core is 30 MB unpacked; OpenSSL, OpenSSH and dnsmasq-full add about 8 MB).
  RAM: xray about 30 MB, ssh about 4 MB (lab). The installer checks free space and `MemAvailable`.

## 3. Layout

### 3.1 Repository

```text
ssh-vpn-client-luci-app-shadow-ucode/
  README.md, README.en.md        what it is, install, update, removal (Russian, English)
  install.sh                     one-command installer / upgrader / uninstaller
  docs/DESIGN.md                 this file; docs/CONTRACTS.md: the module contracts; docs/DEVELOPMENT.md: tests,
                                 CI, releases; docs/images/: the README's screenshots and diagram
  shadow-vpn/                    backend package (noarch)
    files/etc/init.d/shadow-vpn
    files/etc/hotplug.d/iface/99-shadow-vpn
    files/etc/uci-defaults/80-shadow-vpn       creates /etc/config/shadow-vpn if missing, registers the fw4 include
    files/usr/share/nftables.d/chain-pre/input/30-shadow-vpn.nft
    files/usr/libexec/shadow-vpn/              helpers (sh + ucode), see 3.2
    files/usr/share/ucode/shadow-vpn/*.uc      ucode modules: const, config, secrets, state, xray, links, validate,
                                               lists, routing (nft + dnsmasq), ssh, keys (CONTRACTS.md)
  luci-app-shadow-vpn/           LuCI package (noarch)
    htdocs/luci-static/resources/view/shadow-vpn/*.js
    root/usr/share/luci/menu.d/luci-app-shadow-vpn.json
    root/usr/share/rpcd/acl.d/luci-app-shadow-vpn.json
    root/usr/share/rpcd/ucode/luci.shadow-vpn
    po/{templates,ru}/shadow-vpn.po(t)
  build/                         mk_apk.sh (Alpine `apk mkpkg`), po2lmo.py, VERSION
  scripts/                       make-release.sh (new version + release commit), build-release.sh (the release
                                 files, as CI builds them), lib/version.sh (X.Y.Z checks and comparison, section 11)
  tests/
    unit/                        ucode tests run inside the lab router image (run.sh), host-side docker tests,
                                 release/ (the release scripts' tests: bash and git)
    lab/                         Docker lab: up.sh, down.sh, e2e-shadow.sh (Shadow), tests/e2e.sh (research proofs)
  .github/workflows/
    ci.yml                       pull requests and pushes to branches other than master: lint, unit, host docker
                                 and lab tests (section 12); a push to master is left to release.yml
    release.yml                  every push to master: the whole CI (ci.yml), then, for a version with
                                 no release yet, build and publish the release X.Y.Z install.sh downloads (section 11)
  .github/scripts/               release-state.sh (new/retry/released), release-notes.sh
  .github/actions/lab-host/      CI: host kernel modules, firmware cache, lab images (BUILD_ONLY=1 up.sh)
```

### 3.2 On the router

| Path | What |
|---|---|
| `/etc/config/shadow-vpn` | UCI: settings, servers, keys, profiles, rules (no secrets) |
| `/etc/shadow-vpn/` (0700) | `secrets/<sid>.{password,passphrase,link}`, `keys/<sid>`, `known_hosts`, `trusted.<sid>`, `fingerprint.key` (the key of the profile identities in UCI, 5), `lists/{proxy,direct}.lst` + `.sha256`. Files 0600, written tmp + fsync + rename (UBIFS: a power cut right after a save must not leave an empty file). Listed in `/lib/upgrade/keep.d/shadow-vpn`, so sysupgrade and backups keep it next to `/etc/config/shadow-vpn` |
| `/var/run/shadow-vpn/` (tmpfs, 0700) | `xray.json`, `ssh.<sid>.params`, `table.nft` (the full ruleset incl. gate and server elements, used by heals), `dnsmasq.conf` / `dnsmasq.down.conf` (the two DNS variants, 6.5), `state.json`, `attention.json`, `gate`, `fatal`, `ssh.<sid>.{log,state,last}`, `hostkey.<sid>.{seen,status}`, `check.json`, `jobs/*.json`, `patterns`, `wan_dns`, `wan_networks`, `lan_state` (what the iface hook compares, 6.2), `active` |
| `<dnsmasq confdir>/shadow-vpn.conf` | generated `nftset=`, `server=/host/…` (normal upstream for direct names; server hosts and the router's NTP server names on a resolver outside the tunnel, 6.5; `127.0.0.1#5300` for tunnelled ones), `max-ttl` (unless the instance sets `max_ttl`), (full mode) `no-resolv` and the default `server=`, (`ipv6=0`, full mode) `filter-AAAA`, (full mode with no resolver outside the tunnel) `host-record=` for the server names; never a `servers-file=` (6.5); confdir from `dhcp.<sec>.confdir`, default `/tmp/dnsmasq.<sec>.d` for the instance serving `lan` (the only path visible in its ujail). Its temp file is `.shadow-vpn.conf.tmp`: conf-dir skips dot files |
| `/usr/libexec/shadow-vpn/` | `apply`, `job`, `gate-set`, `ssh-run`, `ssh-up`, `ssh-askpass`, `ssh-hostkey`, `ssh-classify`, `xray-run`, `tunnel-check`, `fw4-hook`, `lists` |

## 4. Packages and dependencies

| Package | Depends |
|---|---|
| `shadow-vpn` | `xray-core`, `openssh-client`, `dnsmasq-full`, `kmod-nft-tproxy`, `kmod-nft-socket`, `ucode`, `ucode-mod-fs`, `ucode-mod-uci`, `ucode-mod-ubus`, `ucode-mod-socket`, `ucode-mod-digest` |
| `luci-app-shadow-vpn` | `shadow-vpn`, `luci-base`, `rpcd-mod-ucode` |
| `luci-i18n-shadow-vpn-ru` | `luci-app-shadow-vpn` |

- `apk add dnsmasq-full` replaces `dnsmasq` in one transaction and keeps `/etc/config/dhcp` (lab).
- `/usr/bin/ssh` is an alternatives link that may point to Dropbear; we always call `/usr/libexec/ssh-openssh`.
- Busybox in the factory image provides `flock`, `start-stop-daemon`, `netstat`, `crontab`, `fsync` and `sort -V`
  (lab); `ip` is busybox and handles our v4/v6 rules and `ip route get` (lab). `ip-full` is not needed.
- A key's passphrase is checked only when ssh loads the key: a wrong one is a fatal stop at connect (8.2), not a
  form error. Nothing calls `ssh-keygen`.

## 5. Configuration (UCI) and secrets

```text
config shadow 'main'
	option enabled '0'              # Shadow on/off (the user's intent)
	option autostart '1'            # an enabled Shadow comes back after a reboot or power loss
	option transport 'ssh'          # ssh | xray
	option ssh_server ''            # selected ssh_server section
	option xray_profile ''          # selected profile section
	option mode 'proxy-all'         # proxy-all | selected-rules
	option kill_switch '1'          # 1: tunnelled traffic is blocked while the tunnel is down; 0: it goes direct
	option check_endpoint 'youtube.com:443'
	option check_after_connect '1'
	option ssh_udp 'reject'         # reject | direct (direct only in proxy-all; UDP cannot go over SSH)
	option tunnel_dns '1'           # resolve tunnelled names through the tunnel (DoH); full mode: every name but direct ones
	option ipv6 '0'                 # 1: divert IPv6 too; 0: tunnelled names get no AAAA and IPv6 that would be tunnelled is rejected
	option dns_redirect '1'         # redirect LAN DNS (port 53) to the router; LAN hosts that are the router's own upstreams are exempt
	option router_traffic '1'       # the router's own connections follow the same rules
	option lists_refresh '24'       # hours between automatic list refreshes, 0 = manual only
	option log_level 'warning'      # info | warning | error (ours and xray's)

config list 'proxy'                 # "Blocked in Russia": Russia/inside-raw.lst
	option enabled '0'
config list 'direct'                # "Russian services": Russia/outside-raw.lst
	option enabled '0'

config ssh_server                   # section name s_<12 hex>
	option name '' ; option host '' ; option port '22' ; option username ''
	option auth 'password'          # password | key
	option key ''                   # ssh_key section
	option fingerprint ''           # pinned SHA256:..., empty = trust on first use
	option keepalive '15'           # ServerAliveInterval, 5..3600
	option note ''

config ssh_key                      # k_<12 hex>; text in /etc/shadow-vpn/keys/<sid>
	option name '' ; option type 'ed25519' ; option format 'openssh' ; option encrypted '0'
	# type: ed25519 | ecdsa | rsa, or 'unknown' for an encrypted PKCS#8 key (its algorithm is inside the
	# encrypted part; OpenSSH reads it without the type)

config profile                      # p_<12 hex>; link in /etc/shadow-vpn/secrets/<sid>.link
	option name '' ; option protocol 'vless' ; option host '' ; option port '443' ; option hop_ports ''
	option transport 'tcp' ; option security 'reality' ; option flow ''
	option fingerprint 'hmac:...' ; option pinned '0' ; option insecure_without_pin '0'
	option supported '1'            # 0: the link parses but no outbound can be built (badge, cannot be selected)
	option created '' ; option updated ''

config rule
	option id '<uuid>' ; option type 'domain'   # domain | ip | device
	option value '' ; option enabled '1'
```

- Field limits and validation messages are the desktop's ([`src/shared/validation.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/shared/validation.ts),
  [`src/main/app/ipc-validation.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/main/app/ipc-validation.ts)), in
  English with a Russian translation.
- Secrets never go to UCI, LuCI reads, argv, the environment of a non-root process or our log lines. The rpcd
  plugin writes them with `umask 077`; the ACL gives no file access to `/etc/shadow-vpn`. "Copy link" and
  "Show key" are explicit rpc calls that return the value into a modal (no clipboard API on plain-http LuCI).
- A profile's `fingerprint` (its dedupe identity) is not the link parser's plain SHA-256, which covers the Trojan
  or Hysteria 2 password and would let anyone with a `uci show` paste or the read-only LuCI ACL guess it offline:
  UCI holds `hmac:` + HMAC-SHA256 of it under `/etc/shadow-vpn/fingerprint.key` (32 random bytes, made on first
  use). uci-defaults rewrites the plain values of earlier builds (`sha256:…`).
- **Every section id that reaches a path is checked** against `^[skp]_[0-9a-f]{12}$` before any path is built,
  in one `valid_sid()` guard of the rpcd plugin and again in the helpers.
- **The link parser rejects malformed credentials** (VLESS/VMess id, REALITY `pbk` and `sid`, passwords) with
  desktop-style messages, so `xray run -test` never has a reason to echo them. Where `-test` output is stored in
  `state.json`/attention, values after `invalid UUID:`, `invalid "password":` and `"shortId":` are cut and the
  desktop's `redactSecrets` patterns ([`src/service/xray-service.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/service/xray-service.ts)) applied. xray itself logs straight to logd under procd (no pipe process).
- **Renderers never emit a raw UCI value.** Every value goes through the ported validators (desktop
  `validation.ts`, [`domain-proxy-list.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/core/routing/domain-proxy-list.ts), plus MAC/IPv4/IPv6/CIDR/port validators for device and IP rules) at render
  time; invalid entries are skipped and reported as attention. IPv6 IP rules while `ipv6=0` are flagged in the UI.
- The host-key pin has one source of truth: UCI `fingerprint`. The `pin` that `ssh-hostkey` reads is rendered from it
  into `/var/run/shadow-vpn/` on every start.
- Caps: 1000 profiles (UCI is parsed whole on every read), 10 000 rules, 20 000 domains per list, 2 MiB per
  download or import, 2000 lines per link import (what the profile cap can use; the import parses inside rpcd,
  about 1 s per 200 links on an A53), and per link a host of at most 253 characters and at most 128 query
  parameters (router limits: one hostile link could otherwise hold rpcd for seconds). Server and key names take
  64 code points and notes 500 on save, the same limits `config.load()` applies, so nothing saved is dropped on
  read; a user name OpenSSH refuses (any of ``' ` " ; & < > | ( ) { } $ \ %`` or a leading `-`) is refused on save, and
  one saved before that check stops at connect with "SSH server settings are invalid." instead of making procd
  restart ssh every 2 s.

## 6. Lifecycle

### 6.1 Serialisation

One lock, `flock /var/lock/shadow-vpn.lock`, around apply, teardown, re-render and list apply. Jobs converge on the
desired state in UCI (`enabled`, selection, rules) instead of issuing imperative start/stop, so the last writer wins
cleanly.

Code that runs inside a synchronous context never waits for the lock: the fw4 include (runs under fw4's lock),
`ssh-up` (LocalCommand, blocks ssh), procd triggers (one serial queue for the whole system) and hotplug. They try
`flock -n`; when it is busy they touch `/var/run/shadow-vpn/pending`, which the lock holder checks before
releasing and then re-converges.

`active` marks "Shadow's data plane should exist". Apply creates it **last**; teardown removes it **first**, so a
fw4 reload or hotplug event during teardown never re-creates the table.

### 6.2 Init script

`/etc/init.d/shadow-vpn`: procd, `START=95` (after network S20, firewall/dnsmasq S19 and cron S50), **no `STOP`**
(nothing needs undoing at power-off; tmpfs state disappears anyway).

- `start_service` → `apply converge`. If `enabled=0` it makes sure nothing of ours is armed and returns.
  OpenWrt's `default_postinst` runs `start` on install and on upgrade; this keeps a fresh install inert.
- At boot with `enabled=1` and `autostart=0`, Shadow turns itself **off for real**: `enabled=0` (one UCI commit),
  as if the user had turned it off. Otherwise the UI would show On with nothing running, and the next config save
  would silently arm it.
- `reload_service` (defined explicitly; the default would run `start` and could leave a data plane armed with no
  instances) takes `flock -n` and spawns the detached `job converge`, or touches `pending` when the lock is busy. The
  full converge never runs inside procd's trigger queue, which is serial for the whole system.
- `stop_service` → teardown of our own data plane only (`enabled` stays as it is): used by `restart`.
- Every helper the init script runs gets fd 1000 closed (`1000>&-`). rc.common holds its procd lock
  (`/var/lock/procd_shadow-vpn.lock`) on fd 1000 while an action runs, and busybox `start-stop-daemon -b` keeps fds
  above 2 open, so a detached job would keep that lock for as long as it lives and every later init action, procd's
  reload trigger included, would wait for it (lab: a daemon started from an init script kept that script's lock this
  way).
- `service_triggers`: `procd_add_reload_trigger shadow-vpn dhcp system firewall network` (LuCI forms use `uci
  apply`, which emits `config.change`; `dhcp` because the dnsmasq instance, its confdir, `max_ttl` and upstreams
  feed the render, `system` for the NTP server names, `firewall` and `network` for the LAN zone's devices and
  prefixes). rpcd writes made with the ucode `uci` cursor emit no event, so the plugin spawns a
  `job converge` after them (`job converge --connect` for an explicit Connect, 8.2). Interface trigger:
  `interface.*.up` for the interfaces of the `wan` zone → `job wan-up`. The iface hotplug hook (`fw4-hook
  --iface`) re-renders on a WAN DNS change and, for an interface outside the WAN zone, runs `apply lan-check`,
  which converges when the LAN devices or the router's LAN-side networks differ from the last render
  (`RUN/lan_state`).
- The declaration (`SHADOW_DECLARE=1 … start`, after every converge, outside our lock) reads `RUN` piecemeal, so
  a converge running at that moment can change it underneath. apply therefore puts a converge's new files in
  place before it removes the old server's params, and an `ssh-run` that finds its params gone while
  `RUN/ssh.sid` names another server sleeps until that converge's own declaration replaces it, instead of
  recording "SSH server settings are missing" as a fatal stop that would park the new server too.

### 6.3 Converge

`apply converge` under the lock:

1. Read UCI. Desired = `enabled=1` and a valid selection; split mode also needs at least one target (enabled
   rule, list or device), otherwise attention "nothing to route" and desired = off.
2. **Desired off:** if armed, tear down (6.4). Done.
3. **Desired on:** render everything into `/var/run/shadow-vpn/next/`: `xray.json` (0600), `ssh.<sid>.params`, the
   nft ruleset, both dnsmasq conf variants (6.5), the pattern list. Check with `xray run -test -c` (exit 23 = config
   error → attention, desired off), `nft -c -f` (a kernel-side dry run, so a missing `nft_tproxy` or `nft_socket`
   fails here, before anything is touched), `dnsmasq --test -C <file>` for both variants, and that ports 12345 (v4/v6),
   5300, 12346, 12347, 12348 are free or held by our own instances (`netstat -lntup` against the pids from
   `ubus call service list`; `-test` does not bind). Only a foreign listener fails the check. Nothing up to this point
   touched the system.
4. Apply: move `next/` into place atomically (tmp + rename); `nft -f table.nft` in one transaction that keeps the
   table when the set definitions are unchanged (so dnsmasq-filled sets keep their elements) but runs
   `flush set` on every static set (local, server, user*_net, dev*, lan_if, dns_upstream*) and on the gate chain
   before re-adding their contents, so deleted rules and devices stop matching at once; `delete table` when a set
   definition changed. Ip rules: `ip rule del` until it fails, then add; `ip route replace local default dev lo
   table 106`. fw4 check: if `inet fw4 input` lacks our chain-pre rule, `fw4 -q reload` once; also when
   `flow_offloading=1`, so flows offloaded before start return to the slow path. `touch active`.
5. procd instances. procd restarts an instance only when its command, env or `file` list changed (lab: a changed
   config file with the same argv keeps the old process), so each instance lists its rendered files:
   - `xray`: `xray-run` → `exec xray run -c /var/run/shadow-vpn/xray.json`; `procd_set_param file` on `xray.json`;
     `respawn 3600 5 0`; env `GOGC=50 GOMEMLIMIT=48MiB`; stdout/stderr to logd.
   - `ssh` (SSH mode): `ssh-run <sid>` → `exec ssh ...` (section 8); `procd_set_param file` on `ssh.<sid>.params`,
     the secret file and the key file; `respawn 120 2 0`;
     env `SSH_ASKPASS=/usr/libexec/shadow-vpn/ssh-askpass SSH_ASKPASS_REQUIRE=force SHADOW_ID=<sid>`.
6. Detached `job post-start`: wait until xray listens on 12345 (≤10 s; not while the gate is open, as that DNS
   variant does not use xray), then restart dnsmasq if its file changed and check within 3 s that the dnsmasq
   instance runs (6.5), run `gate-set`, and schedule the first tunnel check.

Any failure from step 4 on: tear down our changes at once, record attention, desired off.

The phase a converge writes: "Connecting" only when the instance that reports the phase restarts, which in SSH
mode is ssh (a new generation, a changed server or its secret files, a new target); ssh-up writes "Connected".
A change that only rewrites `xray.json` (kill switch, IPv6, log level, a private-range IP rule) restarts xray
alone, so in SSH mode the phase stays as ssh left it; when it was xray's error that such a change fixed, the
converge shows the running session again ("Connected", or "Connecting" while ssh has none). In Xray mode
xray-run's watcher reports, and every xray restart starts with "Connecting".

### 6.4 Teardown

Under the lock: remove `active`; delete `inet shadow_vpn` and our ip rules/routes; remove the dnsmasq file and
restart dnsmasq (the file is read only at dnsmasq start, lab); remove the procd instances; clear state.

- Where our dnsmasq file is comes from `RUN/dnsmasq` (tmpfs). A confdir the user set on flash
  (`/etc/dnsmasq.d`) keeps the file over a reboot, an Off cut short or a failed boot converge, and in full mode it
  would keep every lookup on a tunnel that no longer exists. So when `RUN/dnsmasq` says nothing, the instance's
  confdir is checked for a `shadow-vpn.conf` that starts with our generated header: it counts as armed, and Off,
  the boot converge, `install.sh --uninstall` and `apk del` remove it. A file of that name without the header is
  left alone.
- A teardown while Shadow stays on (nothing to route, a failed converge) keeps `RUN/fatal`, `RUN/xray.fatal` and
  `ssh.stamp`: a rejected login is not tried again until a Connect or a changed server (8.2). Off removes them
  and clears the attention of the run it stopped (`ssh_fatal`, `xray_config`, `port_busy`, `dns_rejected`,
  `nft_rejected`, `nothing_to_route`, `dns_bootstrap`, `dns_upstream_leak`).

### 6.5 dnsmasq

dnsmasq reads conf-dir files **only at start**; SIGHUP clears the cache and re-reads hosts/servers files but not
conf-dir (lab: a new file is ignored after SIGHUP, a removed file stays in effect). So:

- Whenever the generated conf file's hash changes (start, Off, rule/list/mode/ipv6 change, list refresh, WAN DNS
  change in full mode, the gate flipping in fallback mode), restart the dnsmasq instance: `ubus call service delete
  '{"name":"dnsmasq","instance":"<sec>"}'` then `/etc/init.d/dnsmasq start` (about 60 ms of DNS gap, lab), falling
  back to `/etc/init.d/dnsmasq restart` (about 2.5 s; it re-runs the DHCP-server probe).
- **One file, two variants, no `servers-file=`.** The tunnel `server=` lines are in the conf itself. Apply renders it
  twice: `dnsmasq.conf` (tunnelled names through `127.0.0.1#5300`) and `dnsmasq.down.conf` (the normal upstream for
  them, for fallback mode while xray is down, 6.7) and installs the one of the current gate verdict. Switching DNS is
  therefore a dnsmasq restart: `gate-set` leaves `pending` when the installed conf is not the verdict's, and the
  converge that follows installs it and post-start restarts dnsmasq with the liveness check below (lab: about 0.3 s
  after the gate flips). An earlier design kept the tunnel lines in a SIGHUP-reloadable `servers-file`; dnsmasq allows
  only one `servers-file` per instance, so when an ad blocker (simple-adblock, adblock-fast) later gave the instance its
  own UCI `serversfile` and restarted dnsmasq while Shadow ran, dnsmasq refused to start ("illegal repeated keyword")
  and took DNS and DHCP down for the LAN (lab). Our conf never names one now, so an instance with its own
  `servers-file`, set before or after Shadow started, always starts (lab).
- Order: on start, xray listens first, then dnsmasq restarts; on stop, the file goes and dnsmasq restarts before
  xray stops.
- **Liveness:** one bad line makes dnsmasq refuse to start, which takes DNS and DHCP down for the whole LAN (lab).
  Besides `dnsmasq --test` before the move, every restart we trigger is followed by a check (≤3 s) that the instance
  runs. If it does not: delete our files, restart dnsmasq again, attention "DNS configuration rejected", desired off.
- When patterns were **removed or moved between sets** (the generator keeps the last mapping in `patterns`), the
  affected dnsmasq-filled sets are flushed before the restart, so those names stop matching. A flush empties the
  whole set, and every listed site then goes direct until its clients resolve again (≤300 s), so it is limited to
  what routes another way: a removed user rule or direct name, a name that moves into or out of the direct set, a
  new pattern under one of another set, and a proxy list turned off as a whole. Additions keep the sets, and so
  do a move between the user and the proxy set (both divert) and a name a list refresh dropped from the proxy
  list (its stale addresses err on the tunnel side until Off or a reboot).
- `max-ttl=300` while active bounds how long clients keep answers that never passed through the sets.
- **Full mode with `tunnel_dns=1`:** the conf file has `no-resolv` and `server=127.0.0.1#5300` as the default
  upstream. Direct patterns get explicit upstreams
  (`server=/P/<addr>` for each address dnsmasq would otherwise use: `dhcp.@dnsmasq[].server` plus
  `resolv.conf.auto`; never `#` once `no-resolv` is set). The iface hotplug hook re-renders when the WAN DNS changes.
  Plain upstreams in the instance's own UCI `server` list (`list server '9.9.9.9'` in `/etc/config/dhcp`) stay
  default upstreams next to ours, so dnsmasq sends some lookups there directly. Shadow never edits
  `dhcp.@dnsmasq[]` (all its dnsmasq settings live in the conf-dir file), so converge raises attention `dns_upstream_leak` ("In full mode some DNS lookups go
  to <servers> directly: remove them in Network → DHCP and DNS or turn off DNS through the tunnel in Settings.") and
  the Overview shows it. Per-domain entries (`/zone/addr`), dnsmasq itself, our own port and a resolver whose
  lookups go through the tunnel anyway (below) do not count.
- **Names that must never wait for the tunnel** (exempt): the VPN server hosts and the router's NTP server names
  (`system.ntp.server` and, with `use_dhcp`, the names DHCP gave). The TR3000 has no battery clock: after a power
  cut `sysfixtime` sets the time of the newest file in `/etc`, possibly months back, VMess refuses a clock more than
  120 s off and TLS (xray's DoH included) checks certificates against it, so an NTP name resolved through the
  tunnel could never fix the clock that the tunnel needs. In full mode exempt names go to the **bootstrap**
  resolvers: upstreams whose own lookups leave the router directly, i.e. plain DNS on port 53 (the output chain
  exempts it) or on a local address, never dnsmasq itself (`127.0.0.1#53`, `::1#53`) and never a LAN resolver
  (full mode tunnels the LAN's traffic, and AdGuard Home or Pi-hole may use DoH themselves). The instance's own
  servers come first; with `noresolv` and nothing usable there, the WAN's `resolv.conf.auto` servers (read even
  then). With `router_traffic=1` a forwarder on the router (https-dns-proxy on `127.0.0.1#5053`, dnscrypt-proxy
  on `127.0.0.53`) or a remote server on another port is tunnelled itself: it stays a normal upstream for other
  names, and attention `dns_bootstrap` names it. With no bootstrap resolver at all the server names are answered
  from the addresses this render resolved (`host-record=`) so the tunnel still comes up, and `dns_bootstrap` asks
  for a plain DNS server (a pinned address never sees a DDNS change). Split mode keeps exempt names on the
  normal upstream (`server=/name/#`).
- The conf is written `0644` with an explicit `chmod`: dnsmasq reads it after dropping root, and the jobs that
  write it run under rpcd's umask 077 (lab: a `0600` file was "Permission denied").
- `max-ttl` may appear only once too: when the instance sets UCI `max_ttl`, ours is left out. A `max_ttl` set by a
  script that restarts dnsmasq without `config.change` while Shadow runs would still clash (section 13); one set in
  LuCI or with `reload_config` re-converges through the `dhcp` reload trigger. A clash that is there at a restart we
  trigger is caught by the liveness check and rolled back (lab: a user conf-dir file with `max-ttl=600`).

### 6.6 State shown in LuCI

Derived on demand by the rpcd `status` call; nothing resident keeps it:

- procd instance state (`ubus call service list`): running, restart count, exit code;
- `state.json` written by `xray-run`, `ssh-run`, `ssh-up` and `apply`: `phase` (`disconnected | connecting |
  connected | reconnecting | error`), `since`, `attempt`, `message`;
- **tunnel health from xray itself**: `GET http://127.0.0.1:12348/debug/vars` (xray `metrics`) returns
  `observatory.proxy` with ping counts and failures (lab). A failing proxy shows as "No tunnel" (kill switch) or
  "Direct" (fallback) even while the processes run;
- for SSH, the last `ssh-classify` result (auth, hostkey, key, port_busy, dns, timeout, refused, unreachable,
  negotiate, closed, dead_link) mapped to the desktop's messages ([desktop spec §15.3](https://github.com/stansful/ssh-vpn-client-electron/blob/master/FUNCTIONAL_SPEC.md));
- `attention.json`: events that stay until dismissed or until their cause is gone (fatal stop, nothing to route,
  config rejected by xray or nft, port busy, DNS file rejected, DNS lookups bypassing the tunnel in full mode, DNS
  servers that depend on the tunnel, invalid rules, list download failed); codes in CONTRACTS.md §8. The fatal ones
  go with their flag: `ssh_fatal` when a session comes up again or a Connect or changed server clears `RUN/fatal`,
  `xray_config` when `RUN/xray.fatal` is cleared; a converge while the instance stays parked keeps them and the
  error phase (lab), and so does a reconnecting ssh while xray is parked (its tunnel carries nothing). Off clears
  them with their flags (6.4); `list_failed` goes with the next successful refresh of that list.
- Durations come from the router: `state.json` stamps `since_up` (uptime) next to `since`, and status returns
  `age` (and `check.age`, `tunnel.last_seen_age`), because the router clock can be days off until NTP sets it
  after a power cut, and the browser's clock is another one.

### 6.7 Tunnel down: kill switch and fallback

Health and failover live inside xray, so no watcher process is needed:

- All tunnelled inbounds (`tproxy-in`, `tproxy6-in`) and xray's internal DNS (`dns-internal`) route to a
  **balancer** `tunnel` with selector `proxy` and `fallbackTag` = `block` (kill switch, default) or `direct`.
- `burstObservatory` pings `http://www.gstatic.com/generate_204` through `proxy` every 5 s (sampling 2,
  timeout 3 s; target from the owner: a dead tunnel is noticed in about 10 s). xray spreads the probes at random over
  interval × sampling, so the lab measured 5–16 s from the server going away to the fallback, about 11 s typical
  (7 s when the server refuses at once). When the pings succeed again it returns to `proxy` within about one
  interval. Right after xray starts `tunnel.alive` is `null` (no probe yet), never optimistic (lab: `null`, then
  `false` within about 2 s for a dead server). So "the tunnel is down" is detected for both transports and for both
  failure kinds: a dead process behind `proxy` (ssh) and an unreachable or blocked server
  (xray). The probe costs one small HTTP request per 5 s through the tunnel.
- Fallback traffic still passes through xray in userspace; that is acceptable during an outage.
- DNS follows the same balancer: with the kill switch, tunnelled names do not resolve while the tunnel is down
  (consistent with blocking them); in fallback mode DoH goes direct, so names keep resolving.
- The tunnel check (`check-in`) routes to `proxy` directly, never to the balancer, so it always tests the tunnel.

What xray cannot cover is **xray itself not running** (start, respawn, crash loop, port taken). With no listener the
tproxy expression breaks without a verdict, the marked packet is delivered locally to no socket and the client hangs
20–120 s (lab). So `divert` **ends with reject rules** after the tproxy rules (`meta l4proto tcp reject with tcp
reset`, then `reject with icmpx port-unreachable`): whenever nothing listens, tunnelled connections fail at once,
with no wrapper state involved. That is also the kill-switch behaviour while xray is down.

The nft `gate` chain is left for one case only: **fallback mode with xray down for 10 s or more** (or a fatal config
error). Then `gate-set` puts `accept` into `gate`, which ends the base chain before the mark and tproxy, so the flow
is forwarded directly, and leaves a converge that installs the DNS variant with the normal upstream for tunnelled
names (6.5; dnsmasq restart). When xray listens again, `gate-set` empties `gate` and the tunnel variant comes back the
same way. With the kill switch, `gate` always stays empty.

`gate` is reached by `jump` from `divert` and from `output` before any mark is set; only `accept`/`reject` end
evaluation there (`return` would fall through to the tproxy rule, lab). `gate-set` writes `/var/run/shadow-vpn/gate`
and regenerates `table.nft`; renders and heals always include the current verdict. Before `exec xray`,
`xray-run` starts one detached watcher (`xray-run --watch`, at most 120 s, killed by teardown and by the next
`xray-run`): it runs `gate-set` once the port listens, and once more when xray has been down for
`XRAY_DOWN_FALLBACK_SEC` (10 s). procd respawns `xray-run` 5 s after xray exits and the outage is counted from that
first respawn (`RUN/xray.down`), not from the watcher's own start: in a crash loop every start replaces the watcher,
and a count of its own never reached 10 s (lab). So in fallback mode the gate opens about 15 s after xray died (lab:
10–15 s, the lower end when the fatal parks xray first).

`xray-run` also counts quick exits: after 3 exits within 30 s of start it runs `xray run -test` once; on a config
error it records fatal attention, sets the gate per the table and sleeps instead of exec'ing xray (its watcher is
stopped; lab: no restart in the next 30 s); otherwise it backs off 5 → 60 s. A converge that does not clear the fatal
flag (no Connect, no changed config) keeps the error state shown.

Lab timings (`e2e-shadow.sh stage2`, three runs): server unreachable → tunnelled connections refused at once
8–12.5 s (`tunnel.alive` false at the same time; before that they hang on the dead server); server back →
tunnelled again 0.8–7.6 s (up to about one observatory interval after the first good probe); fallback mode →
tunnelled destinations direct 6.8–17 s, back 0.4–3.9 s; `kill -9` of xray → tunnelled TCP reset at once (curl
"connection refused" in under 1 ms, no hang), back after procd's 5 s respawn (5.0–5.4 s); crash loop with a config
xray rejects → gate open 10.2–15.4 s, DNS on the normal upstream about 0.3 s later, Connect again after the fix →
tunnelled in about 1.3 s.

## 7. Data plane

### 7.1 Namespace (chosen not to collide with other routing tools)

| Item | Value |
|---|---|
| nft table | `inet shadow_vpn` (dedicated; never inside `inet fw4`) |
| tproxy mark | `0x00400000` |
| xray socket mark | `0x00800000` (`sockopt.mark` on every outbound) |
| policy routing | `fwmark 0x400000/0x400000 table 106 priority 106` (v4 and v6), `local default dev lo table 106` |
| ports (loopback) | tproxy 12345 (`127.0.0.1` and `::1`), DNS 5300, SSH socks 12346, check socks 12347, metrics 12348 |

### 7.2 Routing decision (desktop [`traffic-policy.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/core/routing/traffic-policy.ts) order)

| Step | Desktop | Router |
|---|---|---|
| 0 | SSH: tunnelled UDP is dropped | `divert`: UDP rejected in SSH mode (`ssh_udp=direct` returns instead, full mode only) |
| 1 | the transport's server stays direct | `@server4/6` → accept. Filled from the exact addresses ssh/xray use (8.3) |
| 2 | user domain or IP rule → tunnel | `@user4/6` (dnsmasq) and `@user4/6_net` (CIDRs) → divert |
| 3 | local/private → direct | `fib daddr type local`, `@local4/6` → return (`@local4/6` also hold the router's own LAN-side networks) |
| 4 | process rule → tunnel | device rule: `ip saddr @dev4`, `ether saddr @dev_mac` → divert |
| 5 | direct list → direct | `@proxy4/6` → divert first, then `@direct4/6` → return (see below) |
| 6 | proxy-all → tunnel | full mode: `goto divert` |
| 7 | split: proxy list → tunnel | covered by step 5's `@proxy4/6` check |
| 8 | everything else → direct | return |

Before any of this: `ct direction reply return` (replies of port forwards, UPnP maps and IPv6 pinholes must never
be diverted; lab: a port forward died in full mode without it), `ct status dnat return`, and
`meta l4proto != { tcp, udp } return`: only TCP and UDP can be tproxied, so ICMP (ping, PMTU errors) and every other
protocol always goes direct, in both modes and for every set and device match. Without it divert's final reject
answered pings in full mode with port-unreachable. Broadcast and multicast (`fib daddr type { local, broadcast,
multicast }`, `ip6 daddr ff00::/8`) return before the user sets too: an IP rule as wide as `0.0.0.0/0` (or the
`0.0.0.0/1` + `128.0.0.0/1` pair of imported lists) would otherwise hand DHCP, SSDP and mDNS to xray, and new LAN
clients would get no lease.

The router's own LAN-side networks join `@local4/6` at render time: the addresses and delegated prefixes of every
interface outside the `wan` zone (a guest or IoT VLAN with its own global IPv6 prefix). Without them, IPv6 between
two LAN segments was rejected in full mode (`ipv6=0`) or sent to the VPN server (`ipv6=1`), while IPv4 between them
worked because RFC 1918 is local. The iface hook converges when they change (6.2).

Routing is decided per packet, not per connection, with one exception: a TCP flow that already has a transparent
socket stays in the tunnel. So an established direct TCP flow whose address joins a tunnel set (another client
resolved a listed name that shares the anycast address) is reset once by xray's listener, and its reconnect is
tunnelled, as the shared-address rule says; the same happens to direct flows when Shadow starts or the fallback
gate closes. Keeping direct decisions per connection would let established flows outlive a new rule, a switch to
Proxy all and the end of a fallback outage, so it is not done (13).

Names are already resolved to exactly one set per pattern, so an address in both `@proxy` and `@direct` can only be
a shared CDN/anycast address. It goes to the tunnel, in both modes, like the desktop, which releases a flow to direct
only when the direct list covers every name it is known by.

Names are decided at the **pattern** level, because dnsmasq applies only the single longest matching `nftset=`
entry (dnsmasq `forward.c`). For every pattern P from user domain rules and the enabled lists, the generator
computes the desktop decision for the name P and emits P into exactly one set (`user`, `proxy` or `direct`). This
is exact: every pattern matching a name N is a suffix of N, so the longest one carries every other match and
decision(N) = decision(P). A desktop `*.example.com` rule (subdomains only) becomes `example.com` (apex included);
the UI says so.

**Server names never go through the tunnel**, and neither do the router's NTP server names (6.5). For the
selected SSH server, every host of the selected Xray profile and every NTP name, the generator emits
`server=/<name>/#` (split mode) or `server=/<name>/<bootstrap resolver>` (full mode) and leaves the name out of the
`nftset=` lines. As a longer match it overrides any tunnelled pattern, which avoids the bootstrap loop "the
server's address is resolved through the tunnel that needs it" (lab), also when the router's own resolver is a
DoH or DoT forwarder whose traffic full mode tunnels (6.5).

**Tunnel DNS** (`tunnel_dns=1`): names that go to the tunnel are resolved through it: `127.0.0.1#5300` → xray
`dns-in` → `dns-out` → DoH (`https://1.1.1.1/dns-query`) via the `tunnel` balancer, `queryStrategy: UseIPv4` unless
`ipv6=1`. This gives the server's geo/CDN answers, avoids ISP poisoning and returns NODATA for AAAA.
- Split mode: tunnelled patterns get `server=/P/127.0.0.1#5300`; other names keep the router's normal upstream.
- Full mode: every name except direct patterns and server hosts goes through the tunnel (6.5), so the ISP sees no
  LAN lookups.
- Non-A/AAAA queries for tunnelled names (HTTPS/SVCB, MX, TXT, SRV) are answered REFUSED (`nonIPQuery: reject`).
  `nonIPQuery: skip` with the dns outbound sent through `proxy` over TCP would fix that; it is adopted only if the
  lab shows it works over `ssh -D` too, otherwise the limitation is documented.

**DNS redirect** (`dns_redirect=1`): a `dns_hijack` nat chain redirects LAN port 53 to the router so the sets see
every query. LAN hosts that are the router's own DNS upstreams (`dhcp.@dnsmasq[].server` and `resolv.conf.auto`
entries inside LAN subnets: Pi-hole, AdGuard Home) are exempt via `@dns_upstream4/6`, otherwise their own upstream
queries would loop back into dnsmasq. Users with their own resolver can turn the redirect off. DoH inside browsers
bypasses split routing (documented on the Overview).

xray sniffs TLS/HTTP/QUIC on the tproxy inbounds with `routeOnly: false`, so the server dials the **name**,
like the desktop does. A sniffed name can be an IP literal (`Host: 127.0.0.1`), which the packet-level private check
never saw, so xray routing blocks private, loopback and link-local targets and `localhost` on the tproxy inbounds
before the tunnel rule (plain CIDRs, no `.dat` file). This restores desktop step 3 for sniffed literals.

**IPv6** with `ipv6=0` (default): tunnelled names get NODATA for AAAA; full mode adds `filter-AAAA` for all names;
`divert` rejects IPv6 with `icmpx admin-prohibited` (Happy Eyeballs falls back to IPv4 at once) instead of letting it
bypass the tunnel, which also covers device rules and full mode. With `ipv6=1`, v6 is diverted like v4.

### 7.3 nft ruleset (rendered per mode/transport; every rule ends with a newline)

```nft
table inet shadow_vpn {
	set local4 { type ipv4_addr; flags interval; auto-merge; elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10,
		127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }; }
	set local6 { type ipv6_addr; flags interval; auto-merge; elements = { ::/127, fc00::/7, fe80::/10, ff00::/8 }; }
	# local4/6 also get the router's LAN-side networks (every interface outside the wan zone)
	set server4 { type ipv4_addr; flags interval; }
	set user4 { type ipv4_addr; }
	set user4_net { type ipv4_addr; flags interval; auto-merge; }
	set proxy4 { type ipv4_addr; }
	set direct4 { type ipv4_addr; }
	set dev4 { type ipv4_addr; flags interval; }
	set dev_mac { type ether_addr; }
	set lan_if { type ifname; elements = { "br-lan" }; }
	set dns_upstream4 { type ipv4_addr; }
	set fetch4 { type ipv4_addr; flags timeout; timeout 60s; }   # list downloads through the tunnel (9)
	# + the v6 twins

	chain dns_hijack {
		type nat hook prerouting priority dstnat - 5; policy accept;
		# only with dns_redirect=1
		iifname @lan_if ip saddr != @dns_upstream4 meta l4proto { tcp, udp } th dport 53 fib daddr type != local redirect to :53
	}

	chain prerouting {
		type filter hook prerouting priority mangle - 1; policy accept;
		iifname @lan_if meta l4proto tcp socket transparent 1 meta mark set 0x00400000 accept
		iif "lo" meta l4proto tcp socket transparent 1 meta mark set 0x00400000 accept
		ct direction reply return
		ct status dnat return
		meta l4proto != { tcp, udp } return
		iif "lo" meta mark & 0x00400000 == 0x00400000 goto divert
		iifname != @lan_if return
		fib daddr type { local, broadcast, multicast } return
		ip6 daddr ff00::/8 return
		th dport 53 return
		ip daddr @server4 accept
		ip daddr @user4 goto divert
		ip daddr @user4_net goto divert
		ip daddr @local4 return
		ip saddr @dev4 goto divert
		ether saddr @dev_mac goto divert
		ip daddr @proxy4 goto divert
		ip daddr @direct4 return
		# full only: goto divert
	}

	chain divert {
		# only TCP and UDP get here (prerouting returns everything else first)
		jump gate
		# ipv6=0:    meta nfproto ipv6 reject with icmpx admin-prohibited
		# ssh mode:  meta l4proto udp reject with icmpx port-unreachable
		# vision without -udp443: udp dport 443 reject with icmpx port-unreachable
		meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set 0x00400000 tproxy ip to 127.0.0.1:12345 accept
		# ipv6=1 only:
		meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set 0x00400000 tproxy ip6 to [::1]:12345 accept
		# reached only when nothing listens on 12345: fail fast instead of a black hole
		meta l4proto tcp reject with tcp reset
		reject with icmpx port-unreachable
	}

	chain gate {
		# empty, or `accept` in fallback mode while xray is down (6.7)
	}

	chain output {
		type route hook output priority mangle - 1; policy accept;
		ct direction reply return
		meta mark & 0x00800000 == 0x00800000 return
		th dport 53 return
		ip daddr @fetch4 jump gate_out
		# router_traffic=1 only, from here:
		udp dport { 67, 68, 123 } return
		fib daddr type { local, broadcast, multicast } return
		ip6 daddr ff00::/8 return
		ip daddr @server4 return
		ip daddr @local4 return
		ip daddr @user4 jump gate_out
		ip daddr @user4_net jump gate_out
		ip daddr @proxy4 jump gate_out
		# full only: ip daddr != @direct4 jump gate_out
	}

	chain gate_out {
		jump gate
		meta l4proto { tcp, udp } meta mark set 0x00400000
	}
}
```

- dnsmasq-filled sets are plain hashes (no interval, no timeout): every dnsmasq add is a full libnftables run.
- fw4 integration: the static `chain-pre/input` file accepts the tproxy mark (otherwise a LAN zone with input
  REJECT drops tproxied connections), and a UCI `include` of type `script` runs `fw4-hook` after every fw4
  start/reload (fw4 reloads on every WAN ifup). When `active` exists and the table is missing, the hook loads the
  pre-rendered `table.nft` (current gate verdict and server addresses included; never an additive re-add, which
  duplicates rules, lab) and sends dnsmasq SIGHUP so its cache empties and the sets refill. It never calls fw4 or UCI
  and uses `flock -n`/`pending`. The same hook and the iface hotplug hook check both the fwmark rule and
  `local default dev lo table 106` on every ifup (an `lo` flap removes the route but keeps the rule, lab).
  `fw4 reload/restart` never touch our table; `firewall stop` flushes everything and the hook heals it.
  `post-install` runs `fw4 -q reload` so the include and the chain-pre file are active right away.
- Offload: tproxied flows are delivered locally and never offloaded; direct flows keep SW/HW offload.

### 7.4 xray config

```json
{
  "log": {"loglevel": "warning", "access": "none", "dnsLog": false},
  "policy": {"levels": {"0": {"handshake": 4, "connIdle": 300, "uplinkOnly": 1, "downlinkOnly": 1, "bufferSize": 4}}},
  "metrics": {"tag": "metrics", "listen": "127.0.0.1:12348"},
  "burstObservatory": {"subjectSelector": ["proxy"],
    "pingConfig": {"destination": "http://www.gstatic.com/generate_204", "interval": "5s", "sampling": 2, "timeout": "3s"}},
  "dns": {"tag": "dns-internal", "queryStrategy": "UseIPv4", "servers": ["https://1.1.1.1/dns-query"]},
  "inbounds": [
    {"tag": "tproxy-in", "listen": "127.0.0.1", "port": 12345, "protocol": "dokodemo-door",
     "settings": {"network": "tcp,udp", "followRedirect": true},
     "streamSettings": {"sockopt": {"tproxy": "tproxy", "mark": 8388608}},
     "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": false}},
    {"tag": "tproxy6-in", "listen": "::1", "port": 12345, "...": "same as tproxy-in"},
    {"tag": "dns-in", "listen": "127.0.0.1", "port": 5300, "protocol": "dokodemo-door",
     "settings": {"address": "1.1.1.1", "port": 53, "network": "tcp,udp"}},
    {"tag": "check-in", "listen": "127.0.0.1", "port": 12347, "protocol": "socks", "settings": {"udp": false}}
  ],
  "outbounds": [
    {"tag": "proxy", "...": "from the share link, or socks 127.0.0.1:12346 in SSH mode",
     "streamSettings": {"sockopt": {"mark": 8388608}}},
    {"tag": "direct", "protocol": "freedom", "streamSettings": {"sockopt": {"mark": 8388608}}},
    {"tag": "block", "protocol": "blackhole"},
    {"tag": "dns-out", "protocol": "dns", "settings": {"nonIPQuery": "reject"}}
  ],
  "routing": {"domainStrategy": "AsIs",
    "balancers": [{"tag": "tunnel", "selector": ["proxy"], "fallbackTag": "block", "strategy": {"type": "random"}}],
    "rules": [
      {"inboundTag": ["dns-in"], "outboundTag": "dns-out"},
      {"inboundTag": ["check-in"], "outboundTag": "proxy"},
      {"inboundTag": ["tproxy-in", "tproxy6-in"], "network": "udp", "outboundTag": "block"},
      {"inboundTag": ["tproxy-in", "tproxy6-in"], "domain": ["full:localhost"], "outboundTag": "block"},
      {"inboundTag": ["tproxy-in", "tproxy6-in"], "ip": ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
        "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"], "outboundTag": "block"},
      {"inboundTag": ["tproxy-in", "tproxy6-in", "dns-internal"], "balancerTag": "tunnel"}
    ]}
}
```

- `fallbackTag` is `direct` when `kill_switch=0`. The UDP→block rule exists only in SSH mode.
- `tproxy6-in` on `::1` is rendered only with `ipv6=1`: with `ipv6=0` divert rejects IPv6 before the tproxy rule, and
  binding `::1` would make xray fail on a kernel without IPv6.
- The private-target rules apply only to sniffed literals; user IP rules that open a network behind the server
  (e.g. `10.8.0.0/16`) are rendered as an allow rule to the balancer placed before them.
- `connIdle` 300 s is xray's default and the desktop's (idle SSH, MQTT and push connections survive).
- No geoip/geosite rules, so no `.dat` files load.
- The proxy server name is resolved by the system resolver (no `sockopt.domainStrategy`), see 7.2.
- The `proxy` outbound comes from a ucode port of the desktop's
  [`share-link-parser.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/core/proxy/share-link-parser.ts),
  [`hysteria2-link.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/core/proxy/hysteria2-link.ts) and
  [`xray-config.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/core/proxy/xray-config.ts) (same normalisation, fingerprint/dedupe identity, errors and the 26.x quirks: no
  `allowInsecure` → `pinnedPeerCertSha256`/`verifyPeerCertByName`, mKCP masks via `finalmask`,
  `quicParams.udpHop` for port hopping), tested against vectors the desktop's own code computed
  (`tests/unit/vectors/links.json`, `tests/unit/links/extra.json`; the generators next to them read a desktop
  checkout from `DESKTOP_SRC`).
- One extension over the desktop: TLS links (`vless://`, `trojan://` with `security=tls`) take the Xray 26
  share-link parameters `pcs` (→ `pinnedPeerCertSha256`, hex or base64, comma-separated) and `vcn`
  (→ `verifyPeerCertByName`). The desktop reads them for Hysteria 2 only, so a self-signed TLS server could not be
  used at all (xray 26 has no `allowInsecure`); a malformed `pcs` makes the profile unsupported. No desktop vector
  has `pcs`/`vcn` on a TLS link, so parity is unaffected.
- mKCP: a plain `type=kcp` link (no `fm`, `headerType` or `seed`) gets the `mkcp-original` mask, as on the desktop:
  that is the obfuscation every pre-26 mKCP server applies by default. An xray 26 server without masks needs a link
  that says so in `fm` (lab: the server applies `mkcp-original`).

## 8. SSH mode

### 8.1 Command

```sh
/usr/libexec/ssh-openssh -F none -n -N -T -D 127.0.0.1:12346 -p "$PORT" -l "$USER" \
  -o HostName="$SERVER_IP" -o HostKeyAlias=shadow-$SID -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null \
  -o "KnownHostsCommand=/usr/libexec/shadow-vpn/ssh-hostkey %I %H %t %f %K" \
  -o CheckHostIP=no -o UpdateHostKeys=no -o BatchMode=no -o NumberOfPasswordPrompts=1 \
  -o IdentitiesOnly=yes -o IdentityAgent=none  <key or password options> \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=$KEEPALIVE -o ServerAliveCountMax=3 \
  -o ConnectTimeout=10 -o ConnectionAttempts=1 \
  -o Ciphers=aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr \
  -o PermitLocalCommand=yes -o "LocalCommand=/usr/libexec/shadow-vpn/ssh-up $SID" \
  -o ControlMaster=no -o ControlPath=none -o ForwardAgent=no -o ForwardX11=no \
  -o WarnWeakCrypto=no-pq-kex -o LogLevel=VERBOSE -E /var/run/shadow-vpn/ssh.$SID.log -- "shadow-$SID"
```

- AES-GCM first: the MT7981B has the ARMv8 Crypto Extension and the feed's libcrypto uses it.
- Passwords and passphrases come from `ssh-askpass`, which reads `/etc/shadow-vpn/secrets/<sid>.*`; the prompt
  text tells a password from a passphrase. No sshpass, nothing in argv (lab: works with no tty and DISPLAY unset).
- Host keys: `ssh-hostkey` (KnownHostsCommand) is the single authority (lab: TOFU, pin, mismatch). No pin → trust
  on first use and refuse a changed key; pin set → accept only that `SHA256:` fingerprint; the last key seen is
  saved for "Pin this key". Changing host, port or pin forgets the trusted key ([desktop spec §8.8](https://github.com/stansful/ssh-vpn-client-electron/blob/master/FUNCTIONAL_SPEC.md)).
- Keys: OpenSSH, PEM and PKCS#8 (RSA, ECDSA, Ed25519, encrypted or not) are read by OpenSSH directly. An encrypted
  PKCS#8 key hides its algorithm, so it is saved with type `unknown` (the UI says "type hidden by encryption").
  DSA and `sk-` keys are refused on save with the desktop's messages.
- Every helper starts with a plain `#!/bin/sh` line (a trailing comment on the shebang breaks it on Linux, lab).

### 8.2 ssh-run

`ssh-run` decides, then `exec`s ssh, so no supervisor stays resident:

1. If `/var/run/shadow-vpn/fatal` exists, write state `error` and `exec sleep 2147483647` (the instance stays
   registered and nothing retries; only an explicit Connect, or a changed server, clears the flag and restarts the
   instance; lab: no ssh process and no login attempt in the minute after a rejected password).
2. Classify the previous run's log. Fatal: `hostkey` (incl. `KnownHostsCommand failed`), `key`, `negotiate` for
   host-key algorithms, and `auth` on the first connect or twice in a row during auto-reconnect (desktop parity).
   Fatal → write `fatal` + attention, then as step 1. The balancer has already switched to its fallback.
   "First connect" means the first of a Connect **or of a changed server** (edited, switched, pinned): apply gives the
   ssh instance a new generation (`RUN/ssh.gen`) whenever the server's params or secret files change, so a new wrong
   password is fatal at its first rejection instead of after two (lab: exactly one login attempt).
3. Backoff 1 → 2 → 4 … 60 s from the fail count (reset after a session that lasted 120 s, and by `job wan-up`).
4. Resolve the server once through dnsmasq (`server=/<host>/#`, so never through the tunnel), put exactly that
   address into `@server4/6`, pass it as `HostName`; `HostKeyAlias` keeps the host-key identity.
5. Truncate the log (ssh opens it with `O_APPEND`), write state `connecting`, mark the run `launched` and `exec`
   ssh with its stderr appended to the log as well: OpenSSH reports some errors before `-E` applies (a user name
   it refuses), and a launched run that left an empty log is classified as a failure with the backoff, never
   retried every 2 s by procd.

Params missing at launch are fatal ("SSH server settings are missing.") only while `RUN/ssh.sid` still names this
server; otherwise a converge is replacing it (6.2) and ssh-run sleeps without a flag. While xray is parked by a
config error, every phase ssh-run or ssh-up would write shows xray's error instead (nothing the session carries
gets through).

`ssh-up` (LocalCommand) runs synchronously after authentication and after the `-D` listener is bound, and ssh
serves nothing until it exits (lab). It only writes state `connected` and the session start, runs `gate-set`
with `flock -n`, starts the tunnel check fully detached (`start-stop-daemon -b`) and exits.

The ssh log is capped at 256 KiB by the detached check job and the list cron (truncating an `O_APPEND` file from
outside is safe).

`job wan-up` (interface trigger): returns at once unless `active` and not fatal; resets the fail count and sends
`TERM` to the ssh instance so it reconnects now instead of waiting for ServerAlive or the backoff; re-resolves
server addresses in the background (lab: `ifup wan` with 30 s or more of backoff left → ssh connected in 1.5 s).
The `TERM` goes only to a run without a session, or to a session older than the interface that carries the
route to its server address (`ip route get`, an interface of that address family on that device): wan6 coming up
seconds after wan, or a second WAN-zone interface, no longer kills the session that just started on the new link.

Lab timings (`e2e-shadow.sh stage2`): sshd refusing → `tunnel.alive` false in 4–13 s (the observatory; ssh itself
exits at its next packet); after a 15 s outage the tunnel was back 2–13 s after sshd, the remaining backoff plus up
to one observatory interval: the balancer keeps its fallback until the next probe succeeds, so traffic can resume
some seconds after ssh-up (after `ifup wan`: connected 1.5 s, tunnelled 3.2–7.4 s). Wrong password → error in
1.2–2.3 s; fixed + Connect → tunnelled in about 0.5 s. Host key changed → refused with the mismatch message;
"Pin this key" → tunnelled in 0.2–6 s.

## 9. Domain lists

- Sources: `https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/{inside,outside}-raw.lst`,
  parsed with the desktop rules ([`domain-proxy-list.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/core/routing/domain-proxy-list.ts)): ≤20 000 entries, ≤2 MiB, 15 s.
- Stored as last good copy in `/etc/shadow-vpn/lists/` with a `.sha256`, written as tmp + fsync + rename and
  only when the hash changes (flash wear); checked at boot. Routing works at boot before the network is up and
  when GitHub is blocked.
- Refresh: the "Refresh" button, and cron every `lists_refresh` hours. The cron line is installed once with
  `crontab` in post-install and removed in pre-deinstall; post-install also runs `/etc/init.d/cron enable` and
  restarts cron (its init refuses to start while `/etc/crontabs` is empty, and the factory image has it empty).
  Downloads never block start.
- When the direct download fails and the tunnel is up, retry through the tunnel: resolve the list host via
  `127.0.0.1#5300`, add its addresses to a temporary set `fetch4` (`timeout 60s`) that the `output` chain
  diverts, and download again with uclient-fetch (it cannot use SOCKS or CONNECT itself).
- A failed refresh is logged with its reason (the hourly one at level info, as it fails every hour while GitHub is
  unreachable), and LuCI's Refresh shows it; `list_failed` (raised when a list is missing or three intervals old)
  goes with the next refresh of that list that succeeds.

## 10. LuCI

Menu: `admin/services/shadow-vpn` "Shadow" (order 45), pages as tabs (the approved mock):

| Tab | Content |
|---|---|
| Overview | status with phase, target, uptime/attempt and message; the main On/Off button; transport switch SSH/Xray and server/profile picker; tunnel check (endpoint, Test, result, latency); summary tiles (routing, own rules, memory); attention banners |
| SSH | servers (table + modal form, host-key status, "Pin this key", "Forget trusted key"); keys (paste or upload, type/format badges, used-by count, show) |
| Xray | profiles (add link, import many, search, pin, rename, show link, delete, delete unpinned, unsupported/insecure badges) |
| Routing | mode cards; the two lists (use, refresh, view, count, updated, auto-refresh); rules tabs Domains / IP / Devices (add with validation, enable, delete, import/export JSON compatible with the desktop); device picker from DHCP leases |
| Log | Shadow, xray and ssh lines, level filter, refresh, download, follow |
| Settings | tunnel down: kill switch (default) or direct; autostart; UDP over SSH; tunnel DNS; IPv6; redirect LAN DNS to the router; router traffic; log level; about/update command |

Change from the mock: the "wait before going direct" seconds field is gone; detection time is fixed by the
observatory (about 10 s) and shown as text.

- One rpcd ucode plugin `luci.shadow-vpn` for fast reads and short writes (status, select, save server/key/
  profile, import links, rules import/export, pin/forget host key, logs, dismiss attention, and `settings_set` for
  the settings outside the Settings form: the Overview check endpoint, the Routing mode cards, list auto-refresh). Anything that can
  take seconds (On/Off, tunnel check, list download, reload after writes) runs as a
  detached job (`/usr/libexec/shadow-vpn/job`) writing `/var/run/shadow-vpn/jobs/<id>.json`; the view polls it. A
  slow ucode call blocks all of rpcd, and calls are cut at 30 s.
- Status polling every 5 s with one batched call, paused while the tab is hidden. `status` keeps its validated
  model until `/etc/config/shadow-vpn` or its uncommitted changes change (inode, mtime and size; one minute at
  most): a full load of a file with thousands of rules costs rpcd, which serves every other LuCI call meanwhile,
  a second or more on an A53.
- While Shadow is on, `select` refuses a transport with nothing usable selected (it would turn the tunnel off,
  6.3); the Xray tab asks before a profile replaces a running SSH tunnel. "Pin this key" sends the fingerprint the
  page showed, and the router pins it only while it is still the key it last saw (an impostor met by a later
  connect attempt is not pinned in its place).
- The tunnel check's result, failed or not, is shown in its box only; the router returns the HTTP status line and
  the SOCKS reply code as data, and the page words them. Backend messages are English msgids in the Russian
  catalog (a test collects them from the sources, 12).
- **Log:** the plugin runs `/sbin/logread -l <n>` with constant arguments (no shell, no user text), keeps lines
  tagged `shadow-vpn`, `xray`, `ssh` and the tags the helpers really log under (`xray-run`, `ssh-run`,
  `ssh-openssh`), and the browser filters level and text.
- Theme-neutral: only LuCI classes (`cbi-*`, `btn cbi-button-*`, `alert-message`, `label`, `spinning`, `modal`)
  plus a small injected stylesheet whose colours fall back across themes (bootstrap, argon, aurora, proton2025).
  Nested arrays are not valid `E()` children (they are stringified); children are flattened.
- English msgids, Russian translation shipped as a prebuilt `.lmo` (Python po2lmo, byte-identical to the official
  tool). `msgctxt` where a word would collide with luci-base.

**Tunnel check** (`tunnel-check`, ucode with `ucode-mod-socket`): SOCKS5 CONNECT through `check-in` → `proxy`, then
a TLS ClientHello (ports 443/8443/993/995) or `HEAD /` (80/8080/8000) and the time to the **first response byte**,
12 s deadline. xray's SOCKS inbound replies success at once even when the upstream is dead (lab), so stopping at
the SOCKS reply would always pass. Result texts follow [desktop spec §15.4](https://github.com/stansful/ssh-vpn-client-electron/blob/master/FUNCTIONAL_SPEC.md).

## 11. Install, upgrade, remove, release

```sh
sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh)
```

`HEAD` is the repository's default branch, whatever its name (raw.githubusercontent.com resolves it; checked with
curl and with the router's uclient-fetch). The same command upgrades; `… install.sh) --uninstall` removes.

So routers pair `install.sh` from the default branch with the packages of the latest release, and a push reaches
them at once (raw.githubusercontent.com caches the file for up to 5 minutes, so right after a release or a push the
old one can still meet the other side's new files). The rule: `install.sh` on the default branch always installs the
current latest release, and the asset names, the `SHA256SUMS` format and `SHADOW_BASE_URL` change only compatibly
both ways. `tests/unit/packaging/install_test.sh` checks the first half on every push: the tree's `install.sh`
installs the latest release from GitHub the way a router does, or, while none is published, says so. A release run
that publishes a new version skips that check (`PUBLISHED_RELEASE=skip`): the release it publishes replaces that
one, and a broken latest release must not block its own fix; a push to the default branch whose version is already
released keeps the check. The `install.sh` copy in a release is for reference (its sum is in `SHA256SUMS`); nothing
downloads it.

`install.sh` (busybox ash, `uclient-fetch` as wget):

1. Root, OpenWrt ≥ 25.12 and apk present (24.10 and older: clear refusal); free space on `/overlay` ≥ 45 MB;
   `MemAvailable` check.
2. Clock: if it is before the build date baked into the script, `ntpd -q` and accept the result only if it moves
   the clock forward past that floor; otherwise abort (TLS needs a sane clock). Never `--no-check-certificate`.
3. `apk update`.
4. Download `SHA256SUMS` **only from GitHub**, from the repository's latest release:
   `https://github.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/releases/latest/download/<file>` (two
   redirects, uclient-fetch follows them), with the asset's API URL from `/repos/…/releases/latest` and
   `Accept: application/octet-stream` as the second path; then `shadow-vpn.apk`, `luci-app-shadow-vpn.apk` and
   `luci-i18n-shadow-vpn-ru.apk` (Russian when LuCI is in Russian or the user agrees); `wget -T 15`, 3 tries, a hard
   deadline; verify every sha256. "Latest" can move to a new release between two downloads, so an install at that
   moment can meet old sums with a new package: install.sh then waits 15 s and fetches `SHA256SUMS` and every package
   again (the API listing too) before it gives up. A version change says "upgraded" or, when the latest release is
   an older version (a rollback), "downgraded". When `SHA256SUMS` cannot be downloaded, one more request to
   `/repos/…/releases/latest` (under `SHADOW_BASE_URL`: to `SHA256SUMS`) tells "no release" from a network error:
   on HTTP 404 (none published yet, or no public repository) install.sh says that no release is published, so a
   user in a country that blocks sites is not sent to check access to github.com.
5. `apk add --cache-predownload --allow-untrusted <files>`; dependencies come from the official feed in the same
   transaction (dnsmasq-full replaces dnsmasq). `--cache-predownload` is required: apk purges `dnsmasq` before it
   installs the rest, and the router resolves the feed's host through dnsmasq, so every package is downloaded first
   (into a cache under the install's temp dir, removed afterwards). The free-space check asks for 45 MB on a fresh
   install (xray-core, OpenSSH, OpenSSL, dnsmasq-full) and 5 MB when the dependencies are already installed;
   `MemAvailable` 48 MB / 16 MB.
6. Post-install: `fw4 -q reload`, cron line, `rpcd reload`, clear the LuCI cache. The service converges: a fresh
   install stays off until the user turns Shadow on; an upgrade keeps it on if it was on.

Before any download (after the clock check) install.sh looks at Shadow: when it is on (`active`) with the kill
switch and `router_traffic`, and xray's own probe (`127.0.0.1:12348/debug/vars`: `observatory.proxy` without
`alive: true`, as xray leaves `alive` out when it is false; up to 15 s for a first probe; no answer counts as down)
says the tunnel is down, the router's own downloads are blocked (6.7). In full mode install.sh stops at once, before
any download, with a Russian/English hint to turn Shadow off first (LuCI, or
`uci set shadow-vpn.main.enabled=0; uci commit shadow-vpn; /etc/init.d/shadow-vpn reload`), run it again and turn
Shadow back on (lab: stage3 `blocked` with the VPN server blocked; install_test.sh with no xray answering). In split
mode only listed hosts are blocked, so it goes on and adds the same hint if a download or `apk add` then fails.
Fetching install.sh itself is blocked in that state too (the one-liner then only shows wget's error), so the hint
helps when the script is already on the router or the tunnel goes down during a run.

`install.sh --uninstall` sets `enabled=0`, runs `apply teardown`, removes our packages and keeps
dnsmasq-full (it adds `dnsmasq-full` to `/etc/apk/world` first, so it is not removed as an orphan). Package
`pre-deinstall` does the same if the packages are removed with `apk del`: `enabled=0` and
teardown, then it removes the cron line and the fw4 include (found by its path). Its teardown is `apply teardown
--from-init`: `default_prerm`'s `stop` has already deleted the procd service, and a teardown that declared the
instances again would register the service and its triggers once more, which procd would then run against the
removed files on every dhcp commit and WAN ifup until a reboot. A plain `apk del` keeps
dnsmasq-full too, even on a router from the factory image whose world still names `dnsmasq` (dnsmasq-full provides
it, and apk keeps the installed provider; `tests/unit/packaging/install_test.sh`): no swap back to dnsmasq, which
would purge the running DNS before downloading its replacement. `enabled=0`
matters for a later install: its `post-install` runs `/etc/init.d/shadow-vpn start`, and with the kept
`enabled=1` that would arm Shadow again unasked. apk runs no `pre-deinstall`
on an upgrade, so an upgrade keeps Shadow on. `/etc/config/shadow-vpn` and `/etc/shadow-vpn` stay after a removal.

Builds: `build/mk_apk.sh` re-runs itself in `alpine:3.23` with docker and writes `out/`. The tree goes into the
builder as a tar stream and the result is checked against `SHA256SUMS` on the host: OrbStack bind mounts can show a
stale, cut-off copy of a file that was just rewritten. `scripts/build-release.sh [--test] [--out DIR]` is the
release build, run alike by a developer, the CI's `unit` job and the release workflow: (with `--test` first
`tests/unit/run.sh` and `check_views.mjs`) `sh -n install.sh`, `mk_apk.sh` with `STRICT=1`, `install.sh` next to the
packages and `SHA256SUMS` over the three packages and `install.sh`, checked, then it prints the version, the files
with their sizes and the sums. `SOURCE_DATE_EPOCH` is the HEAD commit's time, so one commit gives byte-identical files
on macOS, on Linux and in CI (checked: a macOS build through docker and a native build as root in `alpine:3.23` of
one commit have the same sums); it warns when the tree has uncommitted changes. The extra `install.sh` line in
`SHA256SUMS` has the format every install.sh accepts, and install.sh only looks up the lines it needs.

Versions (`scripts/lib/version.sh`, shared by the release scripts): `X.Y.Z`, three decimal numbers without leading
zeros, no `v`; the same string is `build/VERSION`, the release's name and its tag; the packages are `X.Y.Z-r1`.
Tags `vX.Y.Z` (what the first release workflow would have created) count as version X.Y.Z. Comparison is numeric
per part in bash (BSD sort has no `-V`).

Release, as in the desktop app: `scripts/make-release.sh` (bash 3.2 on macOS or 5 on Linux, any directory) refuses
a dirty tree (tracked changes, staged or not; untracked files only warn), a detached HEAD and a malformed
`build/VERSION`, warns off the default branch (`origin/HEAD`, else `master`/`main`) and when the branch is behind
`origin`; prints the current version and the highest release tag (local tags and `git ls-remote --tags origin`),
suggests the next patch version of the higher of the two, and takes a version only when it is X.Y.Z, no tag of it
exists and it is higher than the current version and every tag. It writes `build/VERSION`, shows the diff, asks
(`--yes` skips the questions, `--no-commit` stops here), commits only that file as `feat: release - version X.Y.Z`
(a failed or declined commit puts the file back; git hooks run on the commit's own index, so a commit that a hook
added other files to or changed the version in is undone the same way). It never pushes (the owner pushes by hand)
and never creates tags: GitHub creates the tag when the workflow publishes.

`.github/workflows/release.yml` runs on every push to `master` (the trigger names it; the gate also requires it to be
`github.event.repository.default_branch`) and by hand:

1. `gate` reads `build/VERSION` and runs `.github/scripts/release-state.sh` (a port of the desktop's): `released` when
   GitHub has a published release of that version (then the run ends with a notice to bump the version with
   `scripts/make-release.sh`), `new` with no tag yet, `retry` when the tag is already on this commit without a
   release; it fails for a version that is not X.Y.Z, one not higher than every other release tag on origin, and a
   tag of the version on another commit.
2. `quality` is the whole CI (`ci.yml` through `workflow_call`, the lab included) on every push to the default
   branch, released or not, even when the gate failed; a push to `master` does not start `ci.yml` itself
   (`branches-ignore: [master]`), so the checks run once and no skipped CI run is left behind. It skips `install_test.sh`'s check of the published release only when this run replaces that release.
3. `build` (only for `new`/`retry`, after `quality` passed) runs `scripts/build-release.sh` and checks that the
   output is exactly the five assets and matches `SHA256SUMS`.
4. `publish` (the only job with `contents: write`) checks the state again (a re-run may come days later), refuses
   when `.github/workflows` changed on the default branch after this commit (`GITHUB_TOKEN` cannot create a tag
   there; the newer run releases), deletes leftover drafts, creates the release `X.Y.Z` as a draft targeting the
   built commit through the API and keeps the id that call returns (the release list lags behind a draft created a
   moment ago, so the job never looks it up there), uploads the five assets to that id, checks every upload's size,
   state and sha256 digest (polling the draft for a few seconds), publishes it with
   `make_latest=true` and checks that `/releases/latest` is this version and the tag is on this commit. A draft is
   deleted when the job fails before publishing. Notes (`.github/scripts/release-notes.sh`), Russian first and then
   English: the install command and the commit subjects since the previous release tag in this commit's history,
   without merges and release commits.

One release runs at a time per ref; a running one is never cancelled (it could leave a draft), a newer pending run
replaces an older pending one. A failed run publishes nothing: re-run the failed jobs or push a fix (the version is
still unreleased). As every new version must be higher than every tag, the new release is always the latest, so
routers never move back. A usign signature over `SHA256SUMS` with the public key embedded in install.sh is optional
hardening for later.

## 12. Testing

- **Lab** (`tests/lab/`): Docker on an arm64 host, so the aarch64 rootfs runs natively: OrbStack on Apple Silicon,
  or a plain Linux arm64 Docker host (GitHub's `ubuntu-24.04-arm` runners in CI). The router container is the
  real TR3000 25.12.6 sysupgrade rootfs (`docker import`), procd as PID 1, WAN/LAN as Docker networks pinned to
  eth0/eth1; plus a LAN client, a web server that echoes the source address, and a VPN server with sshd and xray
  26.3.27 (REALITY, xhttp, ws, trojan, hysteria2, mKCP inbounds).
- **Unit** (ucode, run in the lab router): link parser against the desktop's vectors, precedence resolver,
  validation messages, list parser, and `nft -c -f` of every rendered variant (mode × transport × ipv6 ×
  router_traffic × gate state); `apply converge` and `teardown` for real in the throwaway container (the phase
  after an xray-only change in SSH mode, the NTP exemption, what a stop that is not an Off keeps and what Off
  clears, our file left in a persistent confdir). `tests/unit/luci/check_views.mjs` also checks that every
  backend message (collected from the sources) translates through the Russian catalog.
- **Lab scenario checks:** `tests/lab/e2e-shadow.sh [install] [stage1]` builds, serves `out/` from a throwaway
  container on the lab WAN, runs `install.sh` with `SHADOW_BASE_URL`, then checks the main paths: SSH (password and
  key) in split and full mode, every Xray link type, tunnel DNS, the direct list, `dns_upstream_leak`, Off/On with
  the data plane gone and DNS kept up, and the LuCI rpc (also over LuCI's `/ubus` from the LAN). `stage2` covers
  failures: the VPN server unreachable or refusing (nft on shadow-vpn) with the kill switch and in fallback mode, xray
  `kill -9` and a crash loop with a config xray rejects (a wrapper that stands in for an xray upgrade), SSH refused,
  `ifup wan`, a wrong password, a changed host key and "Pin this key", fw4/firewall/network restarts, routing edits
  while connected, a profile switch, a LAN port forward, an address in both list sets, dnsmasq with its own
  `servers-file`, a DNS file dnsmasq rejects, and QUIC rejects; `stage2.<group>` runs one group. Lab names are not known to the tunnel's DoH resolver, so split-mode checks of lab names run with
  `tunnel_dns=0` and tunnel DNS is checked with public names (tests/lab/README.md). `stage3` covers the life
  cycle: restart and reload through the init script; power cuts (`docker kill` + `docker start`) with
  `autostart=1`, with an Off cut short before its teardown, and with `autostart=0`; every rpc method with the
  router's data (and that the router offers no other), the six pages and their JS over HTTP from the LAN, the
  Russian catalog and the `/ubus` ACL; the sysupgrade keep list (`sysupgrade -l`, `-b`); install.sh refusing while
  the kill switch blocks the router (11); an upgrade to the next patch version; `install.sh --uninstall` and
  `apk del` (packages gone, dnsmasq-full kept, DNS and DHCP fine) each followed by a reinstall that stays off. The
  lab never shuts the router down gracefully: OpenWrt's `K90umount` remounts the Docker VM's shared cgroup2
  read-only (section 14).
- **E2E** (lab, the full list): install with `install.sh` from a local file server; On/Off, restart, reload and
  reboot; split/full × SSH/Xray; dnsmasq file in effect after start and gone
  after Off; kill switch and fallback (server down → blocked / `src=<WAN>`); xray kill -9 (gate rejects, then
  recovers); ssh fatal auth; fw4 reload/stop/start and network restart healing; removed rule or device stops
  tunnelling without a restart; port forward works in full mode and with a device rule; one IP in both proxy and
  direct sets goes to the tunnel; profile switch restarts xray; a rejected dnsmasq file rolls back; LAN Pi-hole
  upstream does not loop; QUIC reject in SSH mode and with Vision; LuCI pages smoke.
- **CI** (`.github/workflows/ci.yml`, every push to a branch other than `master` and every pull request,
  `ubuntu-24.04-arm`; a push to `master` is tested by `release.yml`, which calls it through `workflow_call`, 11): `lint` (`ubuntu-24.04`) runs actionlint over the workflows (with shellcheck over their `run:` scripts), shellcheck `-x` over
  `scripts/`, `.github/scripts/` and `tests/unit/release/` (the pinned actionlint image's shellcheck 0.11.0, `-f gcc`:
  that static build cannot print Cyrillic source lines) and `tests/unit/release/run.sh`; `unit` builds the lab
  images (`tests/lab/dl` cached by firmware version and sha256), runs `tests/unit/run.sh`, `check_views.mjs` and
  `scripts/build-release.sh` (the release files are a run artifact); `host-docker` runs `install_test.sh` (with
  the published release check of 11, skipped in a run that publishes a release), `rpcd-smoke.sh` and `ssh/e2e.sh`;
  `lab` brings the lab up and runs `e2e-shadow.sh install stage1 stage2 stage3`, keeping the router's logs as an
  artifact when it fails. The scripts know no OrbStack specifics: br_netfilter's
  sysctls are set only where the host kernel has them, the interface names need Docker Engine 28+ (checked), the lab
  networks use the `nat-unprotected` gateway mode (a host that filters bridged traffic would otherwise drop the
  LAN's direct connections), files the lab generates belong to the host user.
- **Release scripts** (`tests/unit/release/run.sh`; bash 3.2+ and git on the host, no Docker; `TEST_BASH=<bash>`
  picks the bash): `make-release_test.sh` runs `scripts/make-release.sh` from outside throwaway clones of a local
  bare origin (the prompt and Enter, refused versions and tags, local/origin/legacy tags, a dirty tree, the commit
  and its single file, pre-commit hooks that stage other files or fail, no push and no tags, other branches,
  detached HEAD, a branch behind origin, no origin); `release-state_test.sh` runs `release-state.sh` against a bare
  origin with tags and a curl stub for the GitHub API, and `tag_commit` (lightweight and annotated tags);
  `release-notes_test.sh` the notes' previous tag and commit list; `assets_test.sh` checks that release.yml,
  build-release.sh and install.sh name the same files, that the tag is plain X.Y.Z and that release.yml reads the
  tag's commit with `tag_commit` like release-state.sh. They pass under macOS
  `/bin/bash` 3.2 (BSD tools), bash 5.2 in `ubuntu:24.04` (GNU) and bash 5.3 in `alpine:3.23` (busybox).
- Every test is deterministic: no assertion races random jitter or a tight timer window.
- Not testable in the lab: the 6.12 kernel and kmod loading, MT7981 hardware offload, Wi-Fi, real flash/RAM
  pressure, PPPoE/DHCP WAN. Covered by the installer's checks and a manual test on the router.

## 13. Known limits

The owner reviewed the open questions of the lab integration on 2026-10-25 and kept these as they are: the mKCP
plain-link semantics of the desktop (7.4); `pcs`/`vcn` on TLS links as a router-only extension (7.4); the DNS limits
below (private names in split mode with tunnel DNS, DoH going direct in fallback mode, a script-set `max_ttl`,
`firewall stop` on its own); a dismissed `dns_upstream_leak` coming back at the next converge while its cause
remains; a changed server starting a new connect series (`RUN/ssh.gen`, 8.2) and no backoff reset after sessions
shorter than 120 s; and `apk del` recording Shadow as off (11).

- Clients' own DNS caches delay tunnelling of a name for up to its TTL after a list change; `max-ttl=300` bounds
  it. After a reboot the dnsmasq-filled sets start empty, so with the kill switch a client that still has a cached
  answer reaches a listed name directly until it resolves again (≤300 s).
- Browser DoH bypasses split routing (Overview hint).
- An IP shared by a tunnelled and a direct name goes to the tunnel in both modes.
- With `dns_redirect=0`, devices that use their own resolver bypass split routing like browser DoH does.
- UCI with hundreds of profiles is parsed on every read; the cap is 1000.
- Detection of a dead tunnel takes 5–16 s, about 8–12 s typical (observatory interval × sampling, lab); in fallback
  mode a crashed xray opens the gate 10–15 s after the crash (lab). When the server comes back, tunnelled traffic
  waits for the next successful probe: up to about 8 s after ssh or the server is back (lab).
- Fallback mode while xray runs but the server is gone: tunnelled names resolve through xray's DoH, which then goes
  out directly from the router to 1.1.1.1 (lab). Where 1.1.1.1 is blocked, they do not resolve until the tunnel is
  back; the switch to the normal upstream happens only while xray itself is down (6.7).
- An SSH session shorter than 120 s does not reset the backoff (desktop parity), so a server that flaps reconnects
  after up to 60 s; `ifup wan` (or any WAN up event) reconnects at once.
- Routing is decided per packet (7.2): an established direct TCP flow whose address joins a tunnel set is reset
  once, and its reconnect is tunnelled.
- A list refresh that drops a domain leaves its addresses in the proxy set until Off or a reboot (they keep going
  to the tunnel); flushing the whole set would send every listed site direct for up to 300 s (6.5).
- Full mode with no DNS server outside the tunnel (only a forwarder on the router, only LAN resolvers, no WAN DNS):
  the server names are answered from the addresses of the last render, so a DDNS change is seen only once a plain
  DNS server is added (attention `dns_bootstrap`), and the clock cannot be set while the tunnel is down.
- Exempt NTP names are those of `system.ntp` (and of DHCP with `use_dhcp`); a time client of another package
  with its own server names resolves them like any other name.
- A LAN resolver (AdGuard Home, Pi-hole) is never a bootstrap resolver in full mode, since it may use DoH that the
  tunnel carries; that it may also fail while the tunnel is down is not reported.
- A UCI `max_ttl` that a script sets while Shadow runs and then restarts dnsmasq without `config.change` clashes with
  our `max-ttl` until the next converge; LuCI and `reload_config` re-converge first (6.5).
- `/etc/init.d/firewall stop` on its own removes our table with everything else; it comes back when the firewall
  starts again (or on the next WAN up). Until then tunnelled destinations are not protected by the kill switch.
- Tunnel DNS resolves through public DoH (1.1.1.1): names that only a local or per-domain server knows resolve only
  through that UCI per-domain server (`server=/zone/addr`), which dnsmasq prefers as the longer match, unless a
  tunnelled pattern is longer still.
- A plain mKCP link means a server with the classic `mkcp-original` obfuscation (7.4); an xray 26 server without
  masks needs `fm` in its link.

## 14. Review log

Changes after the adversarial review and lab checks (2026-10-25):

| Finding | Change |
|---|---|
| nft `return` in a jumped chain falls through to tproxy (lab) | gate uses `accept`/`reject`; output chain also consults the gate |
| dnsmasq reads conf-dir only at start (lab) | restart the instance on every file change; flush sets on pattern removal |
| xray mode had no "tunnel down" signal | balancer + burstObservatory with `fallbackTag` (lab), DNS through the same balancer |
| no listener = black hole, not RST (lab) | gate rejects while xray is not listening |
| default procd reload could leave an armed data plane | explicit `reload_service`, converge model, teardown on every failure |
| the system was touched before validation | validate → render → test → apply, rollback on failure |
| races between jobs | one flock, non-blocking hooks with `pending`, `active` created last / removed first |
| fatal SSH stop left routing armed / retries came back | `fatal` flag cleared only by Connect; auth fatal after two rejections on reconnect |
| server name could resolve through its own tunnel (lab) | `server=/<host>/#`, `HostName=<ip>`, exact address in `@server4/6` |
| LocalCommand blocks ssh (lab) | `ssh-up` only writes state and detaches the check |
| tunnel check passes on xray's instant SOCKS reply (lab) | measure to the first response byte |
| full mode with `ipv6=0` leaked IPv6 | reject forwarded LAN IPv6 in full mode |
| section ids in secret paths | `valid_sid()` guard |
| xray could echo malformed credentials | strict link validation, redaction of stored `-test` output |
| SHA256SUMS from a mirror / clock stepping | sums only from GitHub, forward-only clock floor, no jsDelivr |
| cron not running on a stock image | install the line once, enable and restart cron |
| fw4 pieces inactive until a reload | `fw4 -q reload` in post-install and at apply when missing |
| replies of port forwards / UPnP / IPv6 pinholes were diverted (lab) | `ct direction reply return`, `ct status dnat return` in prerouting and output |
| no listener on 12345 = black hole even with an empty gate | `divert` ends with reject rules; `gate` only carries the fallback `accept` |
| shared CDN IP in both proxy and direct sets went direct in split mode | `@proxy` is checked before `@direct` in both modes |
| `flush table` kept deleted CIDR/device elements | `flush set` of every static set in the same transaction |
| full mode resolved every unlisted name at the ISP | full mode: `no-resolv`, default upstream through the tunnel, explicit WAN DNS for direct names and server hosts |
| tunnel DNS stayed pinned when xray is down in fallback mode | tunnel `server=` lines in a SIGHUP-reloadable servers-file that `gate-set` swaps |
| `ipv6=0` let IPv6 bypass in full mode and for device rules | `filter-AAAA` in full mode, IPv6 rejected in `divert` |
| DNS redirect looped with a LAN Pi-hole/AdGuard upstream | `@dns_upstream` exemption and a `dns_redirect` setting |
| router OUTPUT captured DHCP/NTP; full mode unspecified | `udp dport {67,68,123}` and reply exemptions; full-mode output rule spelled out |
| sniffed IP literals could reach the router's LAN through the server | xray blocks private targets and `localhost` on the tproxy inbounds |
| xray kept the old config after a profile switch (lab) | `procd_set_param file` on rendered configs |
| one bad dnsmasq line takes DNS and DHCP down (lab) | validators at render time, `dnsmasq --test`, liveness check with rollback |
| reload ran the whole converge inside procd's trigger queue; own ports counted as busy | detached `job converge`; ports held by our own pids count as free |
| `autostart=0` left On in the UI with nothing running | at boot it becomes a real Off (`enabled=0`) |
| `/etc/shadow-vpn` lost on sysupgrade; pin stored twice (lab) | `/lib/upgrade/keep.d/shadow-vpn`; UCI `fingerprint` is the only pin |
| VLESS Vision dropped QUIC silently | `udp dport 443 reject` for Vision without `-udp443` |
| `connIdle 120` cut idle connections | 300 s, as xray and the desktop |
| socket lookup on every WAN packet | the `socket transparent` rule is limited to LAN and `lo` |

Changes from the stage 1 lab integration (2026-10-25):

| Finding | Change |
|---|---|
| ping failed in full mode: ICMP reached divert's final reject (lab) | `meta l4proto != { tcp, udp } return` before every divert |
| dnsmasq could not read the servers-file: jobs run under rpcd's umask 077 (lab) | explicit `chmod 0644`; an unreadable file counts as changed |
| full mode leaked lookups to the instance's own UCI upstreams | attention `dns_upstream_leak` with an Overview banner |
| encrypted PKCS#8 keys could not be saved (type `unknown`) | accepted as `unknown` when PKCS#8 and encrypted; DSA text only for DSA |
| `trojan://…&pcs=` ignored the pin, so self-signed TLS servers failed (lab) | `pcs`/`vcn` on every TLS link (7.4) |
| the lab VPN server could not resolve sniffed lab names | lab: shadow-web is the ISP resolver for the router WAN and the VPN server |
| OrbStack bind mounts served stale files to tests and builds | `tests/unit/run.sh` and `build/mk_apk.sh` stream the tree with tar |

Changes from the stage 2 lab integration (failure handling, 2026-10-25):

| Finding | Change |
|---|---|
| an ad blocker's UCI `serversfile` added while Shadow ran made dnsmasq refuse to start (a second `servers-file`), taking LAN DNS and DHCP down (lab) | no `servers-file` of ours: tunnel lines in the conf, two rendered variants, DNS follows the gate through a converge and a dnsmasq restart (6.5); this also ends the inline-mode limit |
| in a crash loop every xray start replaced the watcher, so its own 10 s count never ran out and the gate stayed shut in fallback mode | the watcher counts from `RUN/xray.down` (the first respawn); a parked instance stops its watcher (6.7) |
| a converge while an instance was parked by a fatal flag showed "Connecting…" forever | the error phase and message stay until the flag is cleared (6.3, 6.6) |
| `ssh_fatal` stayed on the Overview after the server was fixed and connected; a converge cleared `xray_config` while xray was still parked | fatal attentions go with their flags (6.6) |
| a wrong password saved for the connected server took two login attempts before the fatal stop | a changed server starts a new connect series (`RUN/ssh.gen`): fatal at the first rejection (8.2) |
| dnsmasq changes in `/etc/config/dhcp` (instance, confdir, `max_ttl`, upstreams) were seen only at the next converge | reload trigger on `dhcp` (6.2) |
| lab: the UDP echo answered only for 203.0.113.10; forwarded connections from 203.0.113.x reached the LAN as 192.168.77.254 (Docker masquerade) | lab: one echo per address (also :443), a port-forward peer 198.51.100.10 with a router route; `--cap-add NET_ADMIN` on shadow-vpn for the nft blocks |

Changes from the stage 3 work (boot, removal, LuCI; 2026-10-25):

| Finding | Change |
|---|---|
| lab: one `docker restart shadow-router` ran OpenWrt's `K90umount` (`umount -a -d -r`), which remounted the container's busy cgroup2 read-only; that superblock is the Docker VM's, so no container could start or be exec'd until OrbStack restarted | lab: `router-init.sh` disables `umount`; `e2e-shadow.sh` reboots with a power cut (`docker kill` + `docker start`) and refuses while `K90umount` is enabled |
| after `apk del` the kept `enabled=1` made a later install arm Shadow again unasked (code reading: `post-install` runs `start`) | `pre-deinstall` sets `enabled=0` before the teardown (section 11) |
| lab: a daemon started from an init script kept rc.common's procd lock (fd 1000; busybox `start-stop-daemon -b` leaves it open), so every later call of that init script hung. Our own init script passed the same fd to apply, so a detached job would have kept *our* procd lock | the init script runs every helper with `1000>&-` (6.2) |
| an upgrade while the kill switch blocked the router failed somewhere in apk (stage 1 report) | install.sh checks xray's probe first and stops with a hint to turn Shadow off (section 11); xray leaves `alive` out of its metrics when it is false (lab) |

Changes from the review of 2026-10-26 (data plane, life cycle, security, LuCI):

| Finding | Change |
|---|---|
| full mode resolved the router's NTP names only through the tunnel: after a power cut (no battery clock) VMess and TLS failed, so the clock could never be set (permanent outage) | NTP server names are exempt like server hosts (6.5, 7.2); `system` reload trigger |
| full mode sent the VPN server's name to a forwarder on the router (https-dns-proxy, dnscrypt-proxy) or a LAN resolver whose own traffic the tunnel carries: the tunnel could never come up | exempt names go to bootstrap resolvers (plain DNS outside the tunnel, `resolv.conf.auto` read with `noresolv` too), else `host-record=` of the last addresses; `127.0.0.53` is a real upstream; attention `dns_bootstrap`; such forwarders are no `dns_upstream_leak` (6.5) |
| an IP rule like `0.0.0.0/0` took DHCP, SSDP and mDNS from the router | broadcast and multicast return before the user sets (7.2, 7.3) |
| removing or moving one pattern flushed the whole proxy set (every listed site direct for up to 300 s) | flush only what routes another way (6.5) |
| status re-validated the whole UCI file every 5 s | the model is kept until the file changes (10) |
| IPv6 between LAN segments was rejected or sent to the VPN server in full mode | the router's LAN-side networks join `@local4/6`; iface hook and `firewall`/`network` triggers re-render (6.2, 7.2) |
| SSH mode: an xray-only change left "Connecting…" until the session dropped | only an ssh restart starts "Connecting" in SSH mode (6.3) |
| our dnsmasq file in a confdir on flash survived a reboot with Shadow off: LAN DNS down | a file with our header there counts as armed and is removed (6.4) |
| `job wan-up` killed the session that had just started on the new link (wan6 after wan) | `TERM` only for a session older than its link (8.2) |
| `list_failed` stayed after a good refresh; a failed Refresh said "see the log" and logged nothing | cleared on success; failures logged and returned (9) |
| Off left the fatal flags' banners; a teardown that was not an Off allowed the rejected login again | Off clears them; a stop while on keeps the flags (6.4) |
| ssh-up showed "Connected" while xray was parked | xray's error stays shown (8.2) |
| a declaration racing a server switch could park the new server with "settings are missing" | new files first, and the old ssh-run waits for its replacement (6.2) |
| `apk del` registered the procd service again | pre-deinstall tears down with `--from-init` (11) |
| secrets and host-key trust files were renamed without fsync | tmp + fsync + rename (3.2) |
| a hostile import held rpcd for minutes; hosts config.load drops were stored invisibly | host ≤ 253, ≤ 128 parameters, 2000 lines, the config validators before storing (5) |
| OpenSSH-refused user names respawned ssh every 2 s; an empty log was "retry now" | refused on save; stderr to the log; a launched run with an empty log backs off (5, 8.2) |
| "Pin this key" pinned whatever key was seen last | the page sends the fingerprint it showed (10) |
| UCI held an unsalted SHA-256 of each profile's credential | keyed HMAC under `fingerprint.key`, earlier values rewritten (5) |
| server/key name and note limits differed between save and load | one set of limits in code points (5) |
| the dnsmasq temp file had a name conf-dir reads | `.shadow-vpn.conf.tmp` (3.2) |
| an install during a release refresh saw old sums with new packages; a re-run could move `openwrt-latest` back | install.sh fetches again once; the workflow never moves it back without `allow_rollback`; "downgraded" (11) |
| tunnel-check refused the IDN endpoints the settings accept | it takes what the settings take and dials punycode |
| DESIGN promised a passphrase check with ssh-keygen that no code does | sentence removed (4) |
| backend messages, the check result and new attentions showed English in the Russian UI; a failed check also raised a red toast | catalog entries and patterns, structured check fields, result box only (10) |
| the transport switch tore a running tunnel down when the other transport had nothing selected; the Xray tab's Select silently replaced an SSH tunnel | `select` refuses while on; the Xray tab asks first (10) |
| the Overview hid the reconnect reason while the tunnel was down; durations used the browser's clock against a router clock that can be days off | the reason stays; ages come from the router's uptime clock (6.6) |
| Log's Follow never showed the newest lines; a router outage stacked one error per poll | Follow sticks to the bottom; one notification per outage |
| phone width: the list rows squeezed their titles, the picker cut "Edit", the keys' Delete was clipped | layout fixes in the stylesheet |
| `nft_rejected` had no title; the Routing page said an enabled empty list would keep Shadow off | title and error style; the page counts it as the router does |
| routing re-decided established direct flows (a reset when an address joins a tunnel set) | kept as is and documented (7.2, 13): sticky direct decisions would let flows outlive new rules and Proxy all |


Changes for the standalone repository (2026-10-26):

| Finding | Change |
|---|---|
| the project lived in `openwrt-shadow-vpn/` of the desktop repository | it is its own repository (`stansful/ssh-vpn-client-luci-app-shadow-ucode`), the former folder is the root; desktop sources and the desktop spec are links (3.1); the vector generators read a desktop checkout from `DESKTOP_SRC` and the committed JSON stays what the tests use (7.4) |
| install.sh read a rolling `openwrt-latest` release published with `make_latest: false`, because the desktop updater reads `/releases/latest` of the desktop repository | install.sh reads `releases/latest` of this repository; the release workflow publishes `vX.Y.Z` marked latest (not when a newer version is the latest one); the one-liner is `raw.githubusercontent.com/<repo>/HEAD/install.sh`, so it follows the default branch (11) |
| no CI | `ci.yml` on GitHub's `ubuntu-24.04-arm`: unit, host docker and lab jobs (12) |
| the lab assumed OrbStack: it always set the `bridge-nf-call-*` sysctls, which Docker refuses on a host kernel without br_netfilter; it hashed with `shasum`; on Linux the lab secrets were written as root through the bind mount and the host user could not read them; on Docker older than 28 the WAN and LAN interfaces would silently swap; `rpcd-smoke.sh` gave rpcd a fixed 2 s | `tests/lab/lib/host.sh` asks a throwaway container which per-namespace sysctls exist; `sha256sum` or `shasum`; `gen-state.sh` hands `state/` to the host user; up.sh checks eth0/eth1 by MAC; rpcd-smoke polls for the object (12) |
| Linux Docker host (Ubuntu 24.04, Docker 29, `bridge-nf-call-iptables=1`): every direct LAN connection to shadow-web timed out. Docker's default "nat" gateway mode drops, in raw PREROUTING, packets to a container address that arrive from another bridge, and the client's packets to 203.0.113.10 are bridged on shadow-lan on their way to the router | the lab networks use `gateway_mode_ipv4=nat-unprotected`; up.sh's smoke check polls the LAN's direct path and stops the lab when it is broken (12) |

Changes from the review of the standalone repository (2026-10-26):

| Finding | Change |
|---|---|
| release.yml published the latest release without running a single test, and a tag push does not trigger `ci.yml` | `ci.yml` is also a reusable workflow; release.yml runs it on the tagged commit and builds only after it passes (11) |
| `core.autocrlf=input` and no `.gitattributes`: the first commit would turn the CRLF fixtures (`edge.po`, the `ssh -E` logs) into LF, and their CRLF cases would silently stop being tested | `.gitattributes`: `-text` for those fixtures, `binary` for `.lmo`, LF for the rest |
| the README promised the installer's hint while the kill switch blocks the router, but then not even install.sh downloads | README: full mode with the kill switch and a dead tunnel ends with wget's error, turn Shadow off first; the installer's hint only when the tunnel goes down during a run (11) |
| install.sh from the default branch meets the packages of the latest release, and nothing checked that pair | the rule in 11; `install_test.sh` installs the latest release from GitHub with the tree's install.sh |
| with no release published, install.sh asked to check access to github.com | HTTP 404 for the latest release: "no release is published yet" (11) |
| the release notes were English only | Russian first, then English |

Changes for the release scripts (2026-10-26; owner: two scripts and a release CI like the desktop app's, the
release commit made automatically):

| Finding | Change |
|---|---|
| a release needed a hand-edited `build/VERSION` and a hand-pushed `vX.Y.Z` tag; nothing checked that the version went up | `scripts/make-release.sh`: shows the current version and the last tag, suggests the next patch, refuses a version that is not X.Y.Z or not higher than the current one and every local or origin tag, commits only `build/VERSION` as `feat: release - version X.Y.Z`; no push (by hand), no tags (11) |
| the release build lived in the workflow, so a local build could differ from the release | `scripts/build-release.sh`: the same build for a developer, CI's `unit` job and release.yml; `SHA256SUMS` also covers `install.sh`; same commit, same sums on macOS, Linux and CI (11) |
| release.yml started from a tag push, unlike the desktop app | the desktop model: every push to the default branch runs the whole CI, and a version without a release is built and published as `X.Y.Z` (plain tag on the built commit, draft first, uploads checked, latest); a released version ends with a notice to bump it; gate in `release-state.sh` (new/retry/released, not higher than a tag, tag elsewhere) (11) |
| with release.yml calling ci.yml on every default-branch push, that push would run the whole CI and the lab twice | every ci.yml job skips a push to the default branch unless release.yml called it (`inputs.release`); `publishing` alone decides the published-release check (11, 12) |
| a running release's tests could be cancelled by ci.yml's `cancel-in-progress` | `cancel-in-progress: ${{ !inputs.release }}` |
| shellcheck through actionlint covers only `run:` blocks | `lint` job: shellcheck `-x -f gcc` over the release scripts and their tests, then `tests/unit/release/run.sh` (12) |
| shellcheck of the pinned actionlint image crashed ("commitBuffer: invalid argument") when a finding's source line has Cyrillic, whatever the locale | `-f gcc`, which prints no source lines (12) |
| nothing kept release.yml's asset list, build-release.sh and the files install.sh downloads in step | `tests/unit/release/assets_test.sh` (12) |
| the first real release failed: publish looked its new draft up in the release list a second after creating it, and the list did not have it yet ("Expected exactly one draft") | the draft is created through `POST /releases`, whose id the job keeps; assets go to `uploads.github.com` for that id; the asset check polls the draft by id; the release list only serves the clean-up of old drafts (11) |
| a push to master started ci.yml as well as release.yml: a second, fully skipped CI run | `ci.yml` has `branches-ignore: [master]` and no per-job skip conditions; `release.yml` runs on `master` (11, 12) |
| make-release.sh asked to push and had `--push` | the push is gone: the script commits, the owner pushes (11) |
