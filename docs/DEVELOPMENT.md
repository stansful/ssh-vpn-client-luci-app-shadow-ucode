# Shadow for OpenWrt: development

The developer half of what the README used to carry: how the parts fit, the repository, the tests, CI and
releases. The README files are for people who install Shadow; the design is in [DESIGN.md](DESIGN.md), the module
interfaces in [CONTRACTS.md](CONTRACTS.md), the Docker lab in [tests/lab/README.md](../tests/lab/README.md).

## How it works

nftables (table `inet shadow_vpn`) hands the traffic that should be tunnelled to xray transparently (TPROXY). xray
sends it to the server: over the Xray link or, in SSH mode, through the SOCKS port of `ssh -D`. Rules and lists decide
which addresses go to the tunnel: dnsmasq puts the addresses of listed domains into nftables sets as they are
resolved. xray's own health check watches the tunnel and switches its traffic to blocked (kill switch) or direct when
it goes down. The details are in [DESIGN.md](DESIGN.md), the module interfaces in [CONTRACTS.md](CONTRACTS.md).

Known limits (browser DoH bypasses split mode, for one) are listed in
[section 13 of DESIGN.md](DESIGN.md#13-known-limits).

## Repository

```text
shadow-vpn/            the backend package: init script, ucode modules, helpers
luci-app-shadow-vpn/   the LuCI pages, the rpcd plugin, translations
build/                 mk_apk.sh (builds the .apk files in Alpine), po2lmo.py, VERSION
scripts/               make-release.sh (a new version), build-release.sh (the release build)
install.sh             the installer
tests/unit/            unit tests (ucode in the router image) and Docker tests
tests/lab/             the lab: TR3000 firmware in Docker
docs/                  DESIGN.md, CONTRACTS.md, this file; images/ holds the README screenshots
```

## Tests and builds

Everything runs in Docker on an arm64 machine: OrbStack on an Apple Silicon Mac, or Linux arm64 with Docker
Engine 28+. The lab boots the real Cudy TR3000 firmware (OpenWrt 25.12.6) with procd, next to a LAN client, an
"Internet" and a VPN server with sshd and xray. What the host needs and how the lab is built:
[tests/lab/README.md](../tests/lab/README.md).

```bash
BUILD_ONLY=1 tests/lab/up.sh          # the lab images (once)
tests/unit/run.sh                     # unit tests
node tests/unit/luci/check_views.mjs  # the LuCI pages and the Russian catalog
tests/unit/release/run.sh             # the release scripts' tests (bash and git, no Docker)
build/mk_apk.sh                       # packages into out/
scripts/build-release.sh              # the release files into out/, as CI builds them (--test: tests first)

tests/lab/up.sh                       # bring the lab up
tests/lab/e2e-shadow.sh install stage1 stage2 stage3   # install and the scenarios, about 8 minutes
tests/lab/down.sh                     # remove the lab
```

Docker tests outside the lab: `tests/unit/packaging/install_test.sh` (the installer on the factory firmware),
`tests/unit/luci/rpcd-smoke.sh`, `tests/unit/ssh/e2e.sh`. The link parser's vectors were computed by the desktop
app's code: the scripts in `tests/unit/vectors/` and `tests/unit/links/` recompute them from its sources
(`DESKTOP_SRC`).

## CI

`.github/workflows/ci.yml` runs all of it on every pull request and every push to a branch other than `master` on
GitHub's arm64 runners; a push to `master` is tested by `.github/workflows/release.yml` (the same CI, once).

Routers take `install.sh` from the default branch and the packages from the latest release, so the `install.sh` on
the branch must install the current release: `install_test.sh` in CI installs the real release from GitHub with it,
and while there is none, checks that the installer says so. Change the release's file names and the `SHA256SUMS`
format only compatibly: GitHub serves the old `install.sh` from its cache for up to 5 minutes after a push, and the
updater on every router, whatever its version, installs the new releases with its own old code (the full list of
what must stay is in [section 11.1 of DESIGN.md](DESIGN.md#111-updates-from-luci)).

## Releases

```bash
scripts/make-release.sh               # shows the current version, asks for the new one (Enter: next patch), commits
git push                              # a push to the default branch starts the release
```

`scripts/make-release.sh` checks that the tree is clean and that the new version X.Y.Z (no "v") is higher than the
current one and every release tag, writes it to `build/VERSION` and commits only that file as
`feat: release - version X.Y.Z`. Without questions: `scripts/make-release.sh 0.2.0 --yes`. It never pushes and
creates no tags. On every push to the default branch `.github/workflows/release.yml` runs the whole CI (the lab
included) and, when the version in `build/VERSION` has no release yet, builds the files with
`scripts/build-release.sh` and publishes release `X.Y.Z`: the tag `X.Y.Z` on that commit, a draft first, the uploads
checked, then published as the latest release, which is where the installer takes the packages from. When the
version is released already, the run ends with a hint to bump it. When the CI fails, nothing is released: re-run the
failed jobs, or push a fix.

A release that the updaters on the routers must not install (one that moves files between packages, merges or
renames packages, or needs a LuCI package they would skip; the full rule is in
[section 11.1 of DESIGN.md](DESIGN.md#111-updates-from-luci)) is marked before it is published: commit a file
`build/CONSOLE_UPDATE` that holds its version, then make the release as usual.

```bash
echo 0.3.0 > build/CONSOLE_UPDATE && git add build/CONSOLE_UPDATE && git commit -m 'chore: 0.3.0 installs from the console'
scripts/make-release.sh 0.3.0 --yes && git push
```

`.github/scripts/release-notes.sh` then ends the release notes with a line `shadow-update: console`, and the release
is created and published with those notes, so no router sees it as the latest without the marker (an edit after
publishing would come too late for the routers that checked meanwhile). Every updater refuses such a release and
shows the install command instead; install.sh installs it. A `CONSOLE_UPDATE` that names another version marks
nothing, so the file can stay for the next releases.

A local release build is `scripts/build-release.sh` (what CI runs): the packages, `install.sh` and `SHA256SUMS` in
`out/`; the files get the commit's time, so one commit gives the same files as its release.

## The README

`README.md` (Russian) and `README.en.md` (English) are the user-facing pages: what Shadow does, what it needs,
install, update, removal. They say the same thing, and a change to one goes into the other in the same commit. The
release notes link to both by these names (`.github/scripts/release-notes.sh`, checked by
`tests/unit/release/release-notes_test.sh`), so keep the file names.

The pictures are in `docs/images/ru/` and `docs/images/en/`, the same file names in both: one PNG per LuCI page
(`overview`, `ssh`, `xray`, `routing`, `log`, `settings`) and `traffic.svg`, a hand-written diagram whose colours
follow `prefers-color-scheme` (light and dark GitHub). When a page changes visibly, retake its screenshot in both
languages; when the README's wording about routing or the kill switch changes, check the diagram's labels.

The screenshots come from the lab router, so they show real pages with the lab's own servers (documentation
addresses `203.0.113.0/24`); never put a real server, link or key on them. How they were taken:

- The lab after `tests/lab/e2e-shadow.sh install stage1`: Shadow connected over Xray.
- Readable demo data through the rpc methods (`ubus call luci.shadow-vpn …`): the lab servers and keys renamed
  (Russian names for the Russian shots), the six lab profiles renamed after their protocol with two of them
  pinned, the "Reality Vision" profile selected, "Selected only" mode with both lists on and refreshed, own rules
  (`chatgpt.com`, `claude.ai`, `discord.com`, `149.154.160.0/20` and two devices, named by lines added to
  `/tmp/dhcp.leases`), then a tunnel check right before the Overview shot.
- The LuCI language per set: `uci set luci.main.lang=ru` (or `en`), `uci commit luci`, then remove
  `/tmp/luci-indexcache*` and `/tmp/luci-modulecache`.
- Headless Chrome through the DevTools protocol at a 1280 px wide viewport, device scale 1.5, light colour
  scheme, logged in as the lab's root. Each shot runs from the top of the page (LuCI's menu bar included) to
  24 px below `#view`, and from 24 px left of `#maincontent` to 24 px right of it; LuCI's poll badge
  (`#indicators`) and the footer are hidden.
- Afterwards the lab goes back to the state stage1 leaves, because `e2e-shadow.sh` finds the lab servers, keys
  and profiles by name and checks that state: the names back (servers "Lab password", "Lab key", "Lab pkcs8";
  keys "Lab key", "Lab pkcs8"; profiles `lab-reality-vision` … `lab-vless-kcp`, none pinned), the demo rules
  and the added `/tmp/dhcp.leases` lines removed, the rule `tunnel.shadow.lab` back, both lists off and their
  downloaded files deleted (`/etc/shadow-vpn/lists/*.lst` and `*.sha256`: stage3's `luci` group expects a list
  that was never downloaded), "All traffic" mode with `lab-vless-kcp` selected, and the LuCI language back to
  `auto`.
