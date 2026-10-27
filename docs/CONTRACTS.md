# Shadow for OpenWrt: module contracts

Companion to [DESIGN.md](DESIGN.md). It fixes the names, signatures and file formats that the parts of the
implementation share, so they can be written in parallel and fit together. When code and this file disagree, fix
one of them in the same change.

## 1. Repository layout

```text
ssh-vpn-client-luci-app-shadow-ucode/                              (repository root)
  install.sh                                    owner: packaging
  build/mk_apk.sh build/po2lmo.py build/VERSION owner: packaging
  scripts/make-release.sh scripts/build-release.sh scripts/lib/version.sh   releases (DESIGN.md §11), owner: packaging
  shadow-vpn/
    control                                     package metadata (name, depends), owner: packaging
    files/etc/init.d/shadow-vpn                 owner: runtime
    files/etc/hotplug.d/iface/99-shadow-vpn     owner: runtime
    files/etc/uci-defaults/80-shadow-vpn        owner: runtime
    files/lib/upgrade/keep.d/shadow-vpn         owner: runtime
    files/usr/share/nftables.d/chain-pre/input/30-shadow-vpn.nft   owner: runtime
    files/usr/libexec/shadow-vpn/
      apply job gate-set xray-run fw4-hook tunnel-check            owner: runtime
      ssh-run ssh-up ssh-askpass ssh-hostkey ssh-classify          owner: ssh
      lists                                                        owner: routing
      update                                                       owner: packaging (the updater, DESIGN.md §11.1)
    files/usr/share/ucode/shadow-vpn/
      const.uc config.uc secrets.uc state.uc xray.uc               owner: runtime
      links.uc                                                     owner: links
      validate.uc lists.uc routing.uc                              owner: routing
      ssh.uc keys.uc                                               owner: ssh
      update.uc                                                    owner: packaging
  luci-app-shadow-vpn/                                             owner: luci
    htdocs/luci-static/resources/view/shadow-vpn/{overview,ssh,xray,routing,log,settings}.js
    htdocs/luci-static/resources/shadow-vpn/common.js
    root/usr/share/luci/menu.d/luci-app-shadow-vpn.json
    root/usr/share/rpcd/acl.d/luci-app-shadow-vpn.json
    root/usr/share/rpcd/ucode/luci.shadow-vpn
    po/templates/shadow-vpn.pot po/ru/shadow-vpn.po
  tests/unit/<area>_test.uc, tests/unit/run.sh                     each owner writes its own *_test.uc
  tests/lab/                                                       Docker lab (see its README)
  tests/lab/e2e-shadow.sh                                          lab scenario checks, grouped by stage
  tests/unit/release/*_test.sh, tests/unit/release/run.sh          the release scripts' tests (host bash + git)
  .github/workflows/ci.yml .github/workflows/release.yml           CI and releases (DESIGN.md §11, §12)
  .github/scripts/release-state.sh .github/scripts/release-notes.sh   the release workflow's gate and notes
```

Modules are ucode files imported as `import { x } from 'shadow-vpn.<name>';` (installed under
`/usr/share/ucode/shadow-vpn/`, which is on ucode's default search path). Every module starts with
`'use strict';`. Shell helpers start with a plain `#!/bin/sh` line (no trailing comment on the shebang).

## 2. Constants (`const.uc`)

```js
export const UCI = 'shadow-vpn';
export const ETC = '/etc/shadow-vpn', RUN = '/var/run/shadow-vpn', LOCK = '/var/lock/shadow-vpn.lock';
export const LIBEXEC = '/usr/libexec/shadow-vpn';
export const NFT_TABLE = 'shadow_vpn';
export const MARK_TPROXY = 0x00400000, MARK_XRAY = 0x00800000, RT_TABLE = 106, RT_PRIO = 106;
export const PORT_TPROXY = 12345, PORT_DNS = 5300, PORT_SSH = 12346, PORT_CHECK = 12347, PORT_METRICS = 12348;
export const OBSERVATORY = { destination: 'http://www.gstatic.com/generate_204', interval: '5s', sampling: 2, timeout: '3s' };
export const XRAY_DOWN_FALLBACK_SEC = 10;   // fallback mode: gate=accept after xray has been down this long
export const LIST_URLS = {
	proxy: 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst',
	direct: 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-raw.lst'
};
export const LIMITS = { profiles: 1000, rules: 10000, list_domains: 20000, download_bytes: 2097152,
	import_chars: 2097152, import_lines: 2000, link_chars: 65536 };
export const SID_RE = /^[skpr]_[0-9a-f]{12}$/;   // s_ server, k_ key, p_ profile, r_ rule
export const REPO = 'stansful/ssh-vpn-client-luci-app-shadow-ucode';
export const APK_DB = '/lib/apk/db/installed';        // rpcd versions() and update.uc read it
export const UPDATE = {                                // the updater, DESIGN §11.1
	api: `https://api.github.com/repos/${REPO}/releases`,      // + '/latest' or '/tags/<tag>'
	download: `https://github.com/${REPO}/releases/download`,  // + '/<tag>/<file>': pinned to the checked release
	asset_api: `https://api.github.com/repos/${REPO}/releases/assets/`, // asset url = this + digits
	page: `https://github.com/${REPO}/releases/`,              // html_url kept only with this prefix
	state: `${RUN}/update.json`,          // tmpfs: last check, last install result, banner
	run: `${RUN}/update.run.json`,        // tmpfs: the install in progress
	work: `${RUN}/update.work`,           // tmpfs work dir (0700), removed before and after
	base_url: `${RUN}/update.base_url`,   // tmpfs test hook (lab): used when env SHADOW_BASE_URL is unset
	auto: `${ETC}/update.state`,          // flash: automatic attempts (survive reboots), written only on change
	lock: '/var/lock/shadow-vpn-update.lock',
	interval: 86400, retry: 10800, slack: 600,   // due: re-check after interval (ok) / retry (failed), minus slack
	window: [ 3, 6 ],                     // automatic installs start at local hours 3, 4, 5
	attempt_gap: 72000, max_tries: 3,     // one automatic attempt per version per night, at most 3 per version
	fetch_ms: 60000, total_ms: 300000, tries: 3, pause: 3, check_ms: 90000, // per attempt / all downloads / check budget
	json_max: 262144, file_max: 8388608,
	apk_update_ms: 300000,
	tunnel_wait: 15, settle: 90,          // seconds: first tunnel verdict (install.sh TUNNEL_WAIT) / tunnel back after install
	stable: 10,                           // seconds the tunnel must stay back (consecutive polls) within settle
	free_kb: 5120, mem_kb: 16384,         // install.sh NEED_FREE_UPGRADE_KB / NEED_MEM_UPGRADE_KB
	clock_floor: 1792886400,              // install.sh CLOCK_FLOOR
	notes_max: 4000
};
```

`REPO`, the URL shapes and the `state`, `run`, `auto` and `lock` paths fall under the updater's compatibility rule
(DESIGN §11.1): an installed updater of any older version keeps using them to install the later releases. So do
the parts of the runtime it reads after it installed a newer release: `RUN` and `RUN/state.json` with the phase
`connected`, `RUN/active`, `PORT_METRICS` with xray's `/debug/vars` and `observatory.proxy.alive` (the observatory
subject `proxy`), `UCI` with `main.enabled`, and `/etc/init.d/shadow-vpn` as a procd service named `shadow-vpn`
(tests/unit/runtime/cases/update.uc `update/compat`).

Detection target (owner, 2026-10-25): a dead tunnel is noticed in about 10 s. The observatory values above are the
starting point; tune them in the lab and keep this file and DESIGN.md §6.7 in sync.

## 3. Data model (`config.uc`)

`load(cursor?)` reads UCI and returns a normalized model. Invalid values are dropped from the model and listed in
`errors` (never thrown):

```js
{
  main: { enabled, autostart, kill_switch, check_after_connect, tunnel_dns, ipv6, dns_redirect, router_traffic: bool,
          transport: 'ssh'|'xray', ssh_server: sid|null, xray_profile: sid|null,
          mode: 'proxy-all'|'selected-rules', check_endpoint: 'host:port', ssh_udp: 'reject'|'direct',
          lists_refresh: int /* hours, 0 = manual */, log_level: 'info'|'warning'|'error',
          update: 'manual'|'notify'|'auto' /* default 'notify', DESIGN §11.1 */ },
  lists: { proxy: { enabled: bool }, direct: { enabled: bool } },
  servers:  [ { sid, name, host, port: int, username, auth: 'password'|'key', key: sid|null,
                fingerprint: 'SHA256:...'|'', keepalive: int, note } ],
  keys:     [ { sid, name, type: 'ed25519'|'ecdsa'|'rsa'|'unknown', format: 'openssh'|'pem'|'pkcs8', encrypted: bool } ],
            // 'unknown' only for format 'pkcs8' with encrypted true (the algorithm is inside the encrypted part)
  profiles: [ { sid, name, protocol: 'vless'|'vmess'|'trojan'|'hysteria2', host, port: int, hop_ports: string,
                transport, security, flow, fingerprint: 'hmac:<hex>', pinned: bool, insecure_without_pin: bool,
                supported: bool, created: int, updated: int } ],
  rules:    [ { sid, id: uuid, type: 'domain'|'ip'|'device', value, enabled: bool } ],
  errors:   [ { section, option, message } ]
}
```

A profile's `fingerprint` is `secrets.profile_identity()` of the link parser's one (`'sha256:<hex>'` of earlier
builds still loads; uci-defaults rewrites it). Server and key names are at most 64 code points and notes 500
(`validate.ROUTER_NAME_LENGTH`, `ROUTER_NOTE_LENGTH`), on save and on load.

Defaults are DESIGN.md §5. `selected(model)` returns the selected server or profile (or `null`), and
`targets(model)` returns whether split mode has anything to route. Also exported: `dnsmasq_instance(cursor)` →
`{ name, confdir }` of the enabled instance serving `lan` (or `null`), `parse_bool(v)`.

## 4. Secrets (`secrets.uc`)

```js
valid_sid(sid) -> bool                                // SID_RE, checked before any path is built
path(sid, kind) -> string|null                        // kind: 'password'|'passphrase'|'link'|'key'
read(sid, kind) -> string|null
write(sid, kind, text, opts?) -> bool                  // umask 077, tmp + fsync + rename, dirs 0700;
                                                       // opts.sync false leaves the flush to sync()
sync() -> void                                         // one `sync` after a batch of { sync: false } writes
remove(sid) -> void                                    // every file of that sid
profile_identity(fp) -> 'hmac:<hex>'|null              // HMAC-SHA256 of a links.uc fingerprint under ETC/fingerprint.key
```

Files: `ETC/secrets/<sid>.password|.passphrase|.link`, `ETC/keys/<sid>`, `ETC/fingerprint.key` (64 hex, made on first
use with O_EXCL). Nothing else reads these directories.

## 5. Links (`links.uc`), ported from the desktop

```js
parse(link) -> { ok: true, profile, link } | { ok: false, error }
	// profile: { name, protocol, host, port, hop_ports, transport, security, flow, insecure_without_pin,
	//            supported, fingerprint, hosts: [server hosts, for DNS exemption] }
	// link: the trimmed input that is stored as the secret
parse_import(text) -> { results: [ { line, ok, profile?, link?, error? } ], skipped: int }
outbound(link) -> { ok: true, outbound } | { ok: false, error }
	// xray outbound object with tag 'proxy'; no sockopt.mark (the caller adds it)
normalize_name(s) -> string
ascii_host(value) -> string|null    // a host as dialled: an IDN in punycode (tunnel-check's endpoint)
```

Semantics, messages and test vectors: [`src/core/proxy/*.ts`](https://github.com/stansful/ssh-vpn-client-electron/blob/master/src/core/proxy) in the desktop app
(`stansful/ssh-vpn-client-electron`). `tests/unit/vectors/links.json` and `tests/unit/links/extra.json` hold what the
desktop's own code returns for the test links; `tests/unit/vectors/vectors.mjs` and `tests/unit/links/gen-extra.mjs`
recompute them from a desktop checkout named by `DESKTOP_SRC`, and the committed JSON is what the tests use.
Malformed credentials (VLESS/VMess
id, REALITY `pbk`/`sid`, passwords) are rejected here, so xray never echoes them. Router extension: TLS links also
take `pcs` → `tlsSettings.pinnedPeerCertSha256` and `vcn` → `verifyPeerCertByName` (the desktop reads them for
Hysteria 2 only; DESIGN §7.4); a malformed `pcs` gives `Invalid pcs: expected a SHA-256 certificate hash.` Router
limits the desktop does not have: a host longer than 253 characters (`Proxy server address is longer than 253
characters.`), more than 128 query parameters (`Proxy link has more than 128 parameters.`), and a host of more than
4096 bytes as written is no host at all.

## 6. Validation, lists, routing (`validate.uc`, `lists.uc`, `routing.uc`)

```js
// validate.uc: each returns { value } or { error } with the desktop's English message
domain_rule(v)  ip_rule(v) /* adds family: 4|6 */  device_rule(v) /* adds kind: 'mac'|'ip4'|'ip6' */
endpoint(v)  fingerprint(v)  keepalive(v)  port(v)  name(v, max)  host(v)  username(v)  cplen(s)
ssh_username(v)     // username() and nothing OpenSSH refuses (' ` " ; & < > | ( ) { } $ \ %, a leading '-')
server(fields) -> { values } | { errors: { field: message } }   // name 64, note 500 code points, ssh_username

// lists.uc
parse(text) -> { domains: [sorted unique] } | { error }
load(kind) -> [domains]                       // ETC/lists/<kind>.lst, [] when missing or hash mismatch
store(kind, domains) -> { changed: bool, count }   // tmp + fsync + rename, writes .sha256, only on change
info(kind) -> { count, updated: epoch|null }

// routing.uc
patterns(model, lists, exempt_names) -> { user: [], proxy: [], direct: [], exempt: [names] }
	// exempt_names: the server hosts and the router's NTP server names (apply); IP literals are dropped
render_nft(model, ctx) -> string
	// ctx: { gate: ''|'accept', server4: [], server6: [], lan_ifs: ['br-lan'], local_nets: [cidrs], dns_upstream4: [],
	//        dns_upstream6: [], vision_udp443: bool, patterns }   output is one `nft -f` transaction (DESIGN §6.3
	//        step 4, §7.3); local_nets: the router's LAN-side networks, added to local4/6
render_dnsmasq(model, ctx) -> { conf: string }
	// ctx: { wan_dns: [ips], bootstrap_dns: [ips], host_addrs: { name: [ips] }, tunnel_dns_up: bool, patterns,
	//        uci: { max_ttl } }
	// one conf-dir file with the tunnel server= lines in it, never a servers-file= (an instance may have its own);
	// tunnel_dns_up=false renders the variant for "xray down in fallback mode" (normal upstream for tunnelled
	// names); ctx.uci.max_ttl set: no max-ttl line of ours; exempt names go to bootstrap_dns in full mode, with
	// none to the WAN servers plus a host-record= per address in host_addrs (DESIGN §6.5)
changed_sets(old_patterns, new_patterns) -> [set names to flush]
	// only what routes another way: user and proxy are both "divert", a name a list refresh dropped from the
	// proxy list keeps the set, the proxy list gone as a whole flushes it (DESIGN §6.5)
nft_needs_recreate(old_text, new_text) -> bool    // set/chain definitions differ: render with ctx.recreate
upstream_of(v) -> { addr, family, port, text, loopback, local } | null   // one "addr" | "addr#port"
dns_leak(model, uci_servers) -> [upstreams]       // full mode + tunnel_dns: the instance's plain UCI `server`
	// upstreams ("addr" | "addr#port") that would take lookups past the tunnel; [] otherwise (DESIGN §6.5);
	// never dnsmasq itself, our port, or a resolver tunnelled_upstreams() names
tunnelled_upstreams(model, list) -> [upstreams]   // full mode + router_traffic: forwarders on the router and
	// remote servers on another port than 53, whose own lookups the tunnel carries
bootstrap_upstreams(model, list, lan_cidrs) -> [upstreams]   // what can resolve exempt names: not tunnelled,
	// not in the LAN, never dnsmasq itself (127.0.0.1#53, ::1#53)
HEADER                                            // the first line of the conf (teardown recognises our file by it)
STATIC_SETS, DNSMASQ_SETS                         // set names render_nft refills / leaves to dnsmasq
```

`/usr/libexec/shadow-vpn/lists refresh <proxy|direct|due>`: download (uclient-fetch, 15 s, 2 MiB), parse, store,
retry through the tunnel when the direct download fails and Shadow is active, then `job converge` if a stored list
changed. `due` refreshes enabled lists older than `lists_refresh` hours (cron calls it hourly).

## 7. SSH (`ssh.uc`, `keys.uc`, helpers)

```js
// keys.uc
normalize(text) -> { text, type, format, encrypted, security_key: bool } | { error }   // desktop private-key.ts rules
// ssh.uc
argv(server, ctx) -> [ '/usr/libexec/ssh-openssh', ... ]   // DESIGN §8.1; ctx: { server_ip, key_path|null }
params(server) -> string                                    // non-secret content of RUN/ssh.<sid>.params
classify(log_text, ctx) -> { code, fatal: bool, message }   // ctx: { reconnecting: bool, prev_code }
reset_backoff(sid) -> bool       // job wan-up: the next attempt starts at once; the reconnect series is kept
session(sid) -> { up, up_at }    // whether ssh-up saw the current run's session start (uptime)
session_stale(sid, link_age) -> bool   // job wan-up: no session, or one older than its link (seconds up; null = unknown)
step(name, sid) -> exit code     // ssh-run's entry: 'plan' (wait seconds | 'fatal') and 'launch' (the exec line), on fd 3
session_up(sid)  cap_log(sid)  after_up(sid)  context(sid)  plan(sid)  launch(sid)   // ssh-up and the tests
```

`keys.normalize` returns `type: 'unknown'` only for an encrypted PKCS#8 key; it returns `{ error }` for DSA and `sk-`
keys (the desktop's texts) and for anything else it cannot type.

Helpers: `ssh-run <sid>`, `ssh-up <sid>`, `ssh-askpass <prompt>`, `ssh-hostkey %I %H %t %f %K`, `ssh-classify <log>`.
`RUN/ssh.<sid>.addr` is the exact address ssh-run resolved and connected to; apply puts it into `@server4/6` in SSH
mode and fw4-hook adds it back after restoring `table.nft`, so a render or heal never diverts ssh's own packets.
`RUN/ssh.<sid>.state` keeps the reconnect series (fails, attempt, session, prev, up_at, reset, gen, launched: ssh was
exec'd and its run not classified yet, so an empty log is a failed run). ssh-run reads
`SHADOW_GEN` from the instance environment: a generation other than the series' one means a new Connect (apply
changes it on `converge --connect`, and the ssh part of it whenever the selected server's params or secret files
change), so the old log goes to logd unclassified and the first-connect rules apply again. A missing state file with a log that shows a session counts as a reset.
Host-key files: `ETC/known_hosts` (lines `shadow-<sid> <type> <key>`), `ETC/trusted.<sid>` (`<type> <fp> <epoch>`),
`RUN/pin.<sid>` (rendered from UCI `fingerprint`), `RUN/hostkey.<sid>.seen` (`<type> <fp> <key>`),
`RUN/hostkey.<sid>.status` (`changed|pin_mismatch expected=<fp> got=<fp> type=<t>`).

## 8. Runtime (`xray.uc`, `state.uc`, `apply`, `job`, `gate-set`, init)

```js
// xray.uc
render(model, ctx) -> { ok, config } | { ok: false, error }   // DESIGN §7.4; ctx: { outbound, vision: bool }
// state.uc
read() -> state     write(patch) -> state                       // RUN/state.json
uptime() -> int                                                 // seconds since boot (since_up, ages)
attention_add(code, message, extra?)  attention_dismiss(id)  attention_list()  attention_clear(code)
job_write(id, patch)  job_read(id)
tunnel_health(timeout_ms?) -> { alive: bool|null, fallback, delay_ms, answered: bool, probed: bool }
	// answered: xray's metrics answered at all; probed: they had observatory.proxy. So "xray does not answer"
	// (down) and "no probe yet" (wait) differ (the updater's kill-switch test, DESIGN §11.1)
// update.uc (DESIGN §11.1). Every external command and system path comes from opts, with production defaults:
// bin (a stub dir: tests), run (dir of the tmpfs files), etc (dir of the flash file), lock, db (APK_DB), base_url,
// config / confdir, limits (over UPDATE), now, uptime, hour, mode, sleep(s), blocked(), connected(), spawn(version).
// Children get </dev/null and their output in a work-dir file or /dev/null: stdout carries only the CLI's JSON.
parse_version(s) -> [x, y, z]|null      // 'X.Y.Z', 'vX.Y.Z', 'X.Y.Z-rN'; no leading zeros (scripts/lib/version.sh)
compare(a, b) -> -1|0|1|null            // null when either is not a version
installed(opts) -> { version: 'X.Y.Z'|null, packages: { <name>: 'X.Y.Z-rN' } }
	// from APK_DB: shadow-vpn and every package starting with luci-app-shadow-vpn or luci-i18n-shadow-vpn-
release_info(text, base?) -> { version, tag, url, published: epoch|null, notes, console: bool,
	assets: { <name>: { url, size, digest } } } | { error }
	// text > json_max refused; tag_name must parse; url kept only under UPDATE.page (under a base URL: under the
	// base); asset names ^[A-Za-z0-9._+-]+$, url only UPDATE.asset_api + digits (none under a base URL), size an
	// int, digest only 'sha256:<64 hex>'; notes without CR, cut to notes_max at a line end; console: a body line
	// exactly `shadow-update: console`
parse_sums(text) -> { <name>: sha256 }|null   // every non-empty line `<64 hex>  <name>` (install.sh), else null
install_set(sums, inst) -> { files: [names] } | { error }
	// every *.apk in SHA256SUMS minus luci-* packages not installed now; shadow-vpn.apk required
check(opts) -> { ok, installed, latest, available, console, error? }
install(opts, auto?) -> { ok, changed, from, to, error?, rolled_back? }
	// auto: the version due saw (--auto). Nothing newer, or a newer release than auto: { ok: true, changed: false,
	// version } and nothing recorded. Busy: { ok: false, error }, or with auto { ok: true, changed: false,
	// skipped: 'busy' }. Every other --auto run is an attempt in UPDATE.auto, also one that a precondition or its
	// check stopped before any download. changed: Shadow's packages differ from before (apk's database decides,
	// not its exit code); rolled_back: an automatic install put the previous version back (after a tunnel that did
	// not come back within settle s, or a release that went in only in part). The wait for the tunnel restarts the
	// procd instances that kept their pid over `apk add` (ubus service delete + the init script's start) and needs
	// new pids, phase connected and tunnel_health().alive on consecutive polls over `stable` s
due(opts) -> { ok, mode, checked?, available?, error?, spawned? } | { ok: true, skipped: 'busy' }
	// check, install and due take UPDATE.lock themselves (a lock that cannot be opened: { ok: false, error });
	// the work they do under it is internal and assumes the lock is held
```

CLIs (all take the lock themselves unless noted):

| Command | Does |
|---|---|
| `apply converge [--connect] [--from-init] [--boot]` | DESIGN §6.3 (desired state from UCI). `--connect` (an explicit Connect) clears `fatal`, `xray.fatal`, `xray.quick` under the lock and writes a new `gen`, so procd restarts both instances |
| `apply teardown [--from-init]` | DESIGN §6.4 |
| `apply render <dir> [--config <uci dir>]` | renders every file into `<dir>` without touching the system (unit/e2e tests) |
| `gate-set` | recomputes the gate verdict (DESIGN §6.7); when the installed dnsmasq conf is not the verdict's variant it leaves `pending`, and the converge that follows installs it; `flock -n` |
| `job <name> [args]` | detached (start-stop-daemon -b); names: `converge [--connect]`, `check [host:port]`, `list-refresh <proxy\|direct\|due>`, `wan-up`, `post-start <gen> [--check]`, `update-check`, `update-install [--auto X.Y.Z]`; prints the job id (`<monotonic s>-<ns>`). The `update-*` jobs' result is `{ rc, ...json }` of the last non-empty line the updater printed |
| `tunnel-check [host:port]` | DESIGN §10, prints the JSON result and writes `RUN/check.json` |
| `update check \| install [--auto X.Y.Z] \| due` | DESIGN §11.1. Takes `UPDATE.lock` (close-on-exec, `xn`), never Shadow's lock; busy: `check` and `install` answer with an error, `install --auto` and `due` exit 0 quietly. Sets the log level from UCI and prints exactly one JSON line (the result of `check` / `install` / `due`) on stdout; exit 0 ok, 1 failure, 2 usage (the usage line on stderr, nothing on stdout). `due` closes the lock, then spawns `job update-install --auto <v>` |

Internal entry points (one helper calls another; not for LuCI): `apply post-start <gen> [--check]` (the detached
step 6 of DESIGN §6.3), `apply state <phase> [message] [code]` (xray-run's state writes), `apply xray-fatal <file>`
(xray-run found a config error in a crash loop), `gate-set --locked` (caller holds the lock) / `--dry-run` (print the
verdict) / `--verdict <fallback> <listening 0|1> <down seconds> <fatal 0|1>` (the pure decision, tests),
`fw4-hook --iface` (from the iface hotplug hook: also re-renders on a WAN DNS change, and runs `apply lan-check`
for an interface outside the WAN zone), `apply lan-check` (converges when the LAN devices or the router's LAN-side
networks differ from `RUN/lan_state`; no lock, no waiting), `xray-run --watch` (the detached watcher of DESIGN §6.7). `SHADOW_DECLARE=1 /etc/init.d/shadow-vpn start` only declares the procd
instances from `RUN` (apply calls it after every converge, outside its lock).

### File formats

```js
// RUN/state.json
{ phase: 'disconnected'|'connecting'|'connected'|'reconnecting'|'error', since: epoch, since_up: uptime,
  attempt: int, message: string, code: string|null, transport: 'ssh'|'xray', target: { kind, name, addr } }
	// since and since_up are stamped together on a phase change; status turns since_up into `age`
// RUN/attention.json
[ { id: string, code: string, message: string, since: epoch, extra?: {} } ]
	// codes: nothing_to_route, ssh_fatal, xray_config, nft_rejected, port_busy, dns_rejected, dns_upstream_leak
	// (extra: { servers }), dns_bootstrap (extra: { servers, bootstrap }: full mode, resolvers the tunnel
	// carries or none outside it), list_failed (id list_failed:<kind>, gone with the next good refresh of that
	// list), rules_invalid; ssh_fatal and xray_config are cleared with RUN/fatal and RUN/xray.fatal (and ssh_fatal
	// when a session comes up), not by other converges; Off clears every code of a run (DESIGN §6.4).
	// The updater's (DESIGN §11.1), which Off keeps: update_available ('Shadow %s is available.'; notify and auto
	// modes, once per version; cleared when installed >= latest, by every install and due, and in manual mode),
	// update_failed (extra: { version, installed }: the version the automatic install was about and the one
	// installed when it failed or was found interrupted; cleared by a successful install, and once installed >=
	// version while installed != extra.installed)
// RUN/jobs/<id>.json
{ id, name, state: 'running'|'done'|'failed', started: epoch, finished: epoch|null, result: {} }
// RUN/check.json
{ ok: bool, outcome: 'tls'|'tls-alert'|'http'|'bytes'|'silent'|'refused'|'local'|'timeout', detail, ms, endpoint, at: epoch,
  message, socks_code? }
	// detail: the HTTP status line for 'http', the RFC 1928 reply code also in socks_code for 'refused', a
	// sentence otherwise; message: the log line
// RUN/gate: '' | 'accept'
// RUN/patterns: JSON from routing.patterns()
// RUN/update.json (UPDATE.state; state.write_json, read by rpcd)
{ checked: epoch, checked_up: uptime, ok: bool|null, error: string|null, installed: 'X.Y.Z'|null, latest, tag, url,
  published, notes, console: bool, announced: 'X.Y.Z'|null,
  last: { ok, changed, from, to, error, auto: bool, rolled_back: bool|null, at: epoch, at_up: uptime } | null }
	// latest … console come from the last successful check: a failed check keeps them; announced: the version
	// update_available was raised for (tmpfs, so a reboot may show the banner once more); last: the last install
	// that tried something (rolled_back null: no rollback was tried); one that finds nothing newer records nothing
// RUN/update.run.json (UPDATE.run): the install in progress, rewritten at each stage, removed on every way out
{ pid, stage: 'check'|'download'|'install'|'settle'|'rollback'|'finish', version, auto: bool, started: epoch,
  started_up: uptime }
// ETC/update.state (UPDATE.auto, flash, 0600, tmp + fsync + rename, written only when it changes)
{ version, tries: int, at: epoch, finished: bool, ok: bool, error: string|null }   // the last automatic attempt
	// written unfinished before the downloads, finished when the run ends; a run stopped before the downloads (a
	// precondition, its check) is written once, finished. tries counts the attempts at that version
```

The readers of the three update files tolerate fields they do not know and fields that are missing: the file may
come from an updater of another version (DESIGN §11.1).

Other files in `RUN` (all 0600 unless noted; runtime-internal): `table.open.nft` / `table.accept.nft` (the two gate
variants; `table.nft` is a copy of the current one), `table.apply.nft` (the last transaction), `dnsmasq.conf` /
`dnsmasq.down.conf` (the two rendered DNS variants: tunnel, and normal upstream while the gate is open), `dnsmasq`
(`<instance> <confdir>`), `wan_dns` (`# <resolvfile>` + its nameservers at the last render), `wan_networks` (the
`wan` zone's networks, one per line), `lan_state` (JSON `{ ifs, nets }`: the LAN devices and the router's LAN-side
networks of the last render), `fallback`
(`block|direct`), `transport`, `ssh.sid`, `ssh.files` (secret files of the ssh instance), `ssh.stamp` (params and
secret files of the selected server), `ssh.gen` (renewed when `ssh.stamp` changes), `gen` (the instance generation,
`SHADOW_GEN`; the ssh instance gets `<gen>.<ssh.gen>`), `applied` (the token of the last applied converge), `pending`, `active`,
`flush.sets`, `patterns.applied`, `dnsmasq.restart` / `dnsmasq.hup` (post-start's to-do), `xray.down` (uptime when
xray went away), `xray.quick` (`<quick exits> <last start> <tested>`), `xray.fatal`, `fatal`, `xray-watch.pid`,
`pin.<sid>`, `next/` (the render being checked), `update.work/` (0700: the updater's downloads, apk cache and log,
the rollback packages in `rollback/` and what the upgrade purges in `rollback/deps/`; removed before and after an
install), `update.base_url` (the updater's test
hook: a base URL used when `SHADOW_BASE_URL` is unset). The dnsmasq conf in the confdir is 0644, written through
`.shadow-vpn.conf.tmp` (conf-dir skips dot files); one with our header there while `RUN/dnsmasq` is missing is a
leftover that teardown removes. A `.shadow-vpn.servers` of earlier builds is removed from the confdir on sight.
A teardown while Shadow stays on keeps `fatal`, `xray.fatal` and `ssh.stamp`.

## 9. rpcd object `luci.shadow-vpn`

All methods return quickly; anything slow returns `{ job }` and the view polls `job_status`. Errors are
`{ error: message }`. Section ids are validated with `valid_sid` before use.

| Method | Args | Returns |
|---|---|---|
| `status` | — | `{ enabled, phase, since, attempt, message, code, transport, target, tunnel: { alive, fallback: 'block'\|'direct', delay_ms }, check, attention, routing: { mode, proxy, direct, rules: { domain, ip, device } }, memory: { xray_kb, ssh_kb, free_kb, total_kb }, versions: { shadow, xray, openssh } }` (`tunnel.alive` is `null` until the observatory has a result) |
| `set_enabled` | `enabled` | `{ job }` |
| `select` | `transport, sid` | `{ ok }`; while Shadow is on, `{ error }` for a transport with nothing usable selected |
| `servers` / `server_save` / `server_delete` | — / `sid?, values, password?` / `sid` | `{ servers }` (with host-key status) / `{ sid } \| { errors }` / `{ ok }` |
| `hostkey_pin` / `hostkey_forget` | `sid, fingerprint` / `sid` | `{ ok, fingerprint? }`; `hostkey_pin` pins only while `fingerprint` (the key the page showed) is the last key seen |
| `keys` / `key_save` / `key_delete` / `key_show` | — / `sid?, name, text?, passphrase?` / `sid` / `sid` | `{ keys }` / `{ sid, key } \| { errors }` / `{ ok } \| { error }` / `{ text }` |
| `profiles` / `profiles_import` | — / `text, source: 'manual'\|'import'` | `{ profiles }` / `{ added, updated, skipped, failed, errors: [{ line, message }] }` |
| `profile_rename` / `profile_pin` / `profile_delete` / `profiles_delete_unpinned` / `profile_link` | `sid, name` / `sid, pinned` / `sid` / — / `sid` | `{ ok }` … / `{ link }` |
| `lists` / `list_set` / `list_refresh` / `list_view` | — / `kind, enabled` / `kind` / `kind` | `{ proxy, direct }` / `{ job }` / `{ job }` / `{ domains }` |
| `rules` / `rule_add` / `rule_set` / `rule_delete` | — / `type, value` / `sid, enabled` / `sid` | `{ rules }` / `{ sid } \| { error }` / `{ ok }` / `{ ok }` |
| `rules_import` / `rules_export` | `text, apply: bool` / — | `{ total, imported, skipped: { unsupported, invalid, duplicates, malformed } }` / `{ json }` |
| `leases` | — | `{ leases: [{ name, ip, mac }] }` |
| `check` / `job_status` | — / `id` | `{ job }` / job JSON |
| `logs` | `lines` | `{ lines: [string] }` (constant `logread` args; filter by tag in ucode) |
| `attention_dismiss` | `id` | `{ ok }` |
| `settings_set` | `values: { mode?, check_endpoint?, lists_refresh? }` | `{ ok } \| { errors: { field: message } }`; converges only when `mode` changed |
| `update_status` | — | `{ mode, installed, latest, available, console, url, published, notes, checked_age, check_ok, check_error, running: { stage, version, auto, age } \| null, last: { ok, changed, from, to, error, auto, rolled_back, age } \| null, auto: { version, tries, ok, finished, error, stopped } \| null, clock: { time: 'HH:MM', zone } }` |
| `update_check` / `update_install` | — / — | `{ job }` (`update-check` / `update-install`); `{ error: 'An update is already running.' }` while one runs |

Writes made through the plugin are committed with the ucode `uci` cursor and followed by `job converge` (no
`config.change` event is emitted for them). `set_enabled(true)` spawns `job converge --connect` when it turns Shadow
on, when `RUN/fatal` exists or when the phase is `error` (an explicit Connect), a plain `job converge` otherwise.
`server_save`, `profiles_import` and the deletes keep `main.ssh_server` and `main.xray_profile` on an existing server
and supported profile (the first one when the selected one is gone). While `enabled=0`, saving the first server or
importing the first supported profile also sets `main.transport` to its transport when the current one has nothing
usable selected (DESIGN §10).
Settings use LuCI's `form.Map('shadow-vpn')`, whose `uci apply` triggers procd's reload; `settings_set` covers the
settings outside that form (the Overview check endpoint, the Routing mode cards and list auto-refresh).

Additive fields beyond the table (the views rely on them; no field above is renamed or removed):

- `status`: `active`, `selected: { ssh_server, xray_profile }`, `mode`, `kill_switch`, `check_endpoint`, `hostkey`
  (the selected server's host-key problem or `null`), `tunnel.last_seen`, `routing.targets`, and ages worked out
  on the router: `age` (seconds since the phase changed, from the uptime clock), `tunnel.last_seen_age`,
  `check.age`; `xray_running` (`null` while not active). Its model is cached until the UCI file or its delta
  changes (one minute at most).
- `servers`: per server `has_password`, `selected`, `key_name`, `hostkey: { trusted, seen, problem }`.
- `keys`: per key `used` (servers using it), `has_passphrase`; `type` may be `unknown` (encrypted PKCS#8).
- `profiles`: per profile `selected`.
- `server_save` and `key_save` return field errors as `{ errors: { field: message } }`; `rule_add` returns
  `{ sid, value }` (the normalized value); `profile_rename` returns `{ ok, name }`; `profiles_delete_unpinned`
  returns `{ ok, deleted }` and never deletes the selected profile; `rules_import` `skipped` also counts `apps`
  (desktop process rules, included in `unsupported`).
- `profiles_import` strips the desktop's `Line N: ` prefix from the error text into `errors[].line`, takes at most
  `LIMITS.import_lines` lines, refuses a line whose host or port `config.load()` would drop, and stores the keyed
  identity (`secrets.profile_identity`) with one `sync` before the commit.
- `list_set(kind, true)` on a list that was never downloaded returns the `list-refresh <kind>` job (it converges
  itself); `check` returns `{ error }` while `RUN/active` is missing.
- Secret reads (`key_show`, `profile_link`) are in the ACL's write group.
- `update_status` (read group) reads `RUN/update.json`, `RUN/update.run.json`, `ETC/update.state` and `APK_DB` (as
  `versions` in `status` does): `installed` is `X.Y.Z` or `null`; `available` comes from a version compare of the
  plugin's own (it does not import `update.uc`); `checked_age` from `checked_up` (else `checked`), `running.age`
  and `last.age` likewise from the uptime twins; `running` only while the run file's `pid` is a live process whose
  `/proc/<pid>/cmdline` contains `/usr/libexec/shadow-vpn/update` (looked at before `RUN/update.json` is read: the
  updater writes `last` before it removes the run file, so `running: null` comes with the final `last`);
  `auto.stopped` is `tries >= max_tries` and not
  `ok`; `clock.zone` is `system.@system[0].zonename`, else `timezone`, else `UTC`. Fields the files lack or do not
  know are tolerated (an updater of another version may have written them). `update_check` and `update_install`
  (write group) take no arguments: LuCI never picks the version, the updater installs the latest release.

## 10. Tests

- `tests/unit/run.sh [pattern]` runs every `tests/unit/*_test.uc` in a throwaway container of the lab image
  `shadow-testenv/tr3000-deps:25.12.6` with `--cap-add NET_ADMIN` and a copy of the package tree at `/src`
  (streamed in with tar, not bind-mounted: OrbStack bind mounts can serve a stale copy of a fresh file):
  `ucode -L /src/shadow-vpn/files/usr/share/ucode <test>`. Tests may run `nft -c -f`, `dnsmasq --test` and
  `xray run -test` there. A test prints `ok <name>` / `not ok <name>: <why>` and exits non-zero on failure.
- The updater: `tests/unit/runtime/cases/update.uc` (in `runtime_test.uc`'s cases) runs `update.uc` and the CLI
  against a stub uclient-fetch (serves fixture files by URL, records its argv, and prints `HTTP error N` and exits
  8 only when called without `-q`, like the real one), a stub apk (records its argv, exits 99 for a `--cache-dir`
  that does not exist as apk 3.0.5 does, can fail, exit 1 after installing or after a partial install, answer a
  dry run with purged packages, fetch, and leave a detached `start-stop-daemon -S -b -x /bin/sleep -- 30` as a
  post-install would), a stub `ubus` and init script that play procd (an instance keeps its pid until it is
  deleted and declared again), a stub df and a stub fsync that records the order of the files an install leaves,
  through `opts.bin` and the `opts` paths. `tests/unit/luci_test.uc` checks `update_status` from fixture files and an
  `APK_DB` fixture, running detection with a live process whose cmdline names the updater, and the refusals while
  it runs. `tests/unit/luci/rpcd-smoke.sh` and the lab's `LUCI_METHODS` know the three methods.
- E2E runs in the lab (`tests/lab/`); only one agent drives it at a time. `tests/lab/e2e-shadow.sh [install]
  [stage1] …` installs the build the real way (install.sh with `SHADOW_BASE_URL` from a throwaway package server on
  the lab WAN) and runs the scenario checks of each stage (`stage1` main paths, `stage2` failure handling,
  `stage2.<group>` one group of it, `stage3` boot/upgrade/removal/LuCI and updates from LuCI, `stage3.<group>` one
  group of it); it is re-runnable on a lab from `up.sh`. Its package server also serves `release.json` in GitHub's
  shape and per-tag subdirectories for the updater's base URL; only `stage3.update` runs `update_check` and
  `update_install`, and never against the real GitHub. Host-side docker tests outside run.sh: `tests/unit/ssh/e2e.sh`,
  `tests/unit/luci/rpcd-smoke.sh`, `tests/unit/packaging/install_test.sh` (the factory rootfs: refusals, an
  unreachable source and one with no release, fresh install, `apk del` on the factory world, a new latest release
  during the download, upgrade, downgrade, `--uninstall`, and at the end the latest release published on GitHub,
  installed by this install.sh the way a router does, or "no release is published yet" while there is none;
  `PUBLISHED_RELEASE=skip` skips that part, a release run that publishes a new version does). It also checks the
  updater's cron line (installed once, kept once by an upgrade and a reinstall, gained by an upgrade from the
  published release that had only the lists line, removed by `apk del` and `--uninstall`) and, in the published
  release part, `update check` against GitHub, the download step for the published tag through both paths, and,
  once the published release ships `/usr/libexec/shadow-vpn/update`, its install of this tree's build from a base
  URL. Like run.sh they copy sources and builds into their containers with tar, never through a bind
  mount. `node tests/unit/luci/check_views.mjs` compiles the views as LuCI does, checks their msgids against the
  template and that every backend message translates through the Russian catalog.
- `tests/unit/release/run.sh` runs the release scripts' tests on the host (bash 3.2+ and git, no Docker):
  `make-release_test.sh`, `release-state_test.sh` (a curl stub for the GitHub API), `release-notes_test.sh`,
  `assets_test.sh` (also: `SHA256SUMS` and `shadow-vpn.apk`, which the updater requires, are release assets); same
  `ok`/`not ok` output.
- All of it runs on any arm64 Docker host (OrbStack on Apple Silicon, a Linux arm64 machine) and in CI
  (`.github/workflows/ci.yml`: job `lint` on `ubuntu-24.04`, jobs `unit`, `host-docker` and `lab` on GitHub's
  `ubuntu-24.04-arm`). On a
  push to `master` `.github/workflows/release.yml` runs that workflow (`workflow_call`) before it builds anything;
  `ci.yml` itself ignores pushes to `master`.
- Every test is deterministic: no assertion races random jitter or a tight timer window.
