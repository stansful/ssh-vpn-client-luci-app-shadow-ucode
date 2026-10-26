# Shadow for OpenWrt

[Русский](README.md) · **English**

> **Disclaimer.** This app is a test of whether today's neural networks can build applications with minimal
> developer involvement. The answer is **yes**.

Shadow for OpenWrt sends the traffic of your whole home network through your own server, over SSH or through Xray
(VLESS, VMess, Trojan, Hysteria 2). It is the router edition of the
[Shadow desktop app](https://github.com/stansful/ssh-vpn-client-electron): it installs with one command and lives in
LuCI under **Services → Shadow**.

## Features

- **Two ways to connect.** An SSH tunnel to any server you can SSH into, with a password or a key and nothing to
  install on the server. Or an Xray profile from a `vless://`, `vmess://`, `trojan://` or `hysteria2://` link: paste
  one or many, one per line.
- **The whole network or only what you pick.** Send all LAN traffic through the server, or only the sites, IP
  addresses and devices (by MAC or IP) you choose; everything else stays direct. Rules import and export in the
  desktop app's format.
- **Ready-made site lists.** Turn on the "Blocked in Russia" list with one switch instead of adding hundreds of rules.
  The "Russian services" list keeps Russian sites direct, even when everything else goes through the tunnel. Both
  come from [itdoginfo/allow-domains](https://github.com/itdoginfo/allow-domains) and refresh on their own.
- **Kill switch by default.** When the tunnel is down, the sites that should go through it do not open directly,
  and everything else keeps working. Settings can let them go direct instead.
- **DNS through the tunnel.** Names that go through the tunnel are resolved through the server (DoH), so your ISP
  does not see them. The router catches the LAN's DNS queries, so domain rules work for every device.
- **Reconnects on its own.** A dead tunnel is noticed in about 10 seconds; Shadow brings it back when the server or
  the WAN returns. There is a tunnel check and a log.
- **Easy on the router.** No resident process of its own: only xray and, in SSH mode, ssh run. Direct traffic stays
  in the kernel, hardware offload included.
- **Keeps secrets safe.** Passwords, keys and links live in `/etc/shadow-vpn` with mode `0600` and never reach UCI,
  LuCI responses or the log. The server's host key is remembered on first connect, and you can pin a fingerprint.

The LuCI pages are in English and Russian.

## Router and requirements

- **OpenWrt 25.12 or newer** (the apk package manager). The installer refuses 24.10 and older: their xray-core is
  too old.
- **About 45 MB of free flash** (xray-core alone takes about 30 MB) and about 50 MB of free memory.
- The reference router is the **Cudy TR3000 256MB v1** (MediaTek MT7981B) on OpenWrt 25.12.6. Shadow's packages are
  architecture-independent, and xray-core, OpenSSH and dnsmasq-full come from the official OpenWrt feed, so any
  router the feed builds them for works.
- The installer replaces `dnsmasq` with `dnsmasq-full` (your `/etc/config/dhcp` stays as it is) and sets the router
  clock over NTP when it is off: HTTPS does not work without the right time.

**Before you install, turn off other routing tools**: Podkop, Forkop, passwall, passwall2 and the like, or remove
them. They change the same DNS settings and nftables rules, and with Shadow they would get in each other's way.

## Install

SSH into the router and run:

```sh
sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh)
```

The installer checks the router, downloads the packages from the
[latest release](https://github.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/releases/latest), verifies their
checksums and installs them. The Russian translation comes along when LuCI is in Russian (otherwise it asks).

Shadow is off after a fresh install. Open LuCI → Services → Shadow, add an SSH server or an Xray profile, pick a mode
on the Routing tab and turn Shadow on on the Overview tab.

## Update

Run the same command. If Shadow was on, it stays on. LuCI shows the command too: Shadow → Settings → About.

When Shadow is on in "All traffic through the tunnel" mode with the kill switch and its tunnel is down, the router
cannot download anything, not even the installer: the command ends with a wget error. Turn Shadow off first
(LuCI → Services → Shadow → Turn off), run the command and turn Shadow back on. If the tunnel goes down while the
installer runs, it stops and tells you the same.

## Uninstall

```sh
sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh) --uninstall
```

Shadow turns off and its packages are removed; `dnsmasq-full` stays, so DNS and DHCP keep working. The settings stay
in `/etc/config/shadow-vpn` and `/etc/shadow-vpn`: delete them if you no longer need them.

## What it looks like

No screenshots yet. The LuCI section has six tabs: Overview (status, the big button, server picker, tunnel check),
SSH (servers and keys), Xray (profiles), Routing (mode, lists, rules), Log and Settings.

## How it works

nftables (table `inet shadow_vpn`) hands the traffic that should be tunnelled to xray transparently (TPROXY). xray
sends it to the server: over the Xray link or, in SSH mode, through the SOCKS port of `ssh -D`. Rules and lists decide
which addresses go to the tunnel: dnsmasq puts the addresses of listed domains into nftables sets as they are
resolved. xray's own health check watches the tunnel and switches its traffic to blocked (kill switch) or direct when
it goes down. The details are in [docs/DESIGN.md](docs/DESIGN.md), the module interfaces in
[docs/CONTRACTS.md](docs/CONTRACTS.md).

Known limits (browser DoH bypasses split mode, for one) are listed in
[section 13 of DESIGN.md](docs/DESIGN.md#13-known-limits).

## For developers

```text
shadow-vpn/            the backend package: init script, ucode modules, helpers
luci-app-shadow-vpn/   the LuCI pages, the rpcd plugin, translations
build/                 mk_apk.sh (builds the .apk files in Alpine), po2lmo.py, VERSION
install.sh             the installer
tests/unit/            unit tests (ucode in the router image) and Docker tests
tests/lab/             the lab: TR3000 firmware in Docker
```

Everything runs in Docker on an arm64 machine: OrbStack on an Apple Silicon Mac, or Linux arm64 with Docker
Engine 28+. The lab boots the real Cudy TR3000 firmware (OpenWrt 25.12.6) with procd, next to a LAN client, an
"Internet" and a VPN server with sshd and xray. What the host needs and how the lab is built:
[tests/lab/README.md](tests/lab/README.md).

```bash
BUILD_ONLY=1 tests/lab/up.sh          # the lab images (once)
tests/unit/run.sh                     # unit tests
node tests/unit/luci/check_views.mjs  # the LuCI pages and the Russian catalog
build/mk_apk.sh                       # packages into out/

tests/lab/up.sh                       # bring the lab up
tests/lab/e2e-shadow.sh install stage1 stage2 stage3   # install and the scenarios, about 8 minutes
tests/lab/down.sh                     # remove the lab
```

Docker tests outside the lab: `tests/unit/packaging/install_test.sh` (the installer on the factory firmware),
`tests/unit/luci/rpcd-smoke.sh`, `tests/unit/ssh/e2e.sh`. The link parser's vectors were computed by the desktop
app's code: the scripts in `tests/unit/vectors/` and `tests/unit/links/` recompute them from its sources
(`DESKTOP_SRC`).

**CI** (`.github/workflows/ci.yml`) runs all of it on every push and pull request on GitHub's arm64 runners.

Routers take `install.sh` from the default branch and the packages from the latest release, so the `install.sh` on
the branch must install the current release: `install_test.sh` in CI installs the real release from GitHub with it,
and while there is none, checks that the installer says so. Change the release's file names and the `SHA256SUMS`
format only compatibly: GitHub serves the old `install.sh` from its cache for up to 5 minutes after a push.

**Releases:** bump `build/VERSION`, tag a commit whose CI is green with `vX.Y.Z` and push the tag.
`.github/workflows/release.yml` runs the whole CI on that commit once more, and only then builds the packages and
publishes a release marked latest, which is where the installer takes the packages from. When that CI fails,
nothing is released: re-run the failed jobs, or fix the commit and move the tag.

Shadow for your computer (Windows, macOS, Linux): [stansful/ssh-vpn-client-electron](https://github.com/stansful/ssh-vpn-client-electron).
