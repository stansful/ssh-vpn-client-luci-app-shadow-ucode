# Shadow for OpenWrt: module contracts

Companion to [DESIGN.md](DESIGN.md). It fixes the names, signatures and file formats that the parts of the
implementation share, so they can be written in parallel and fit together. When code and this file disagree, fix
one of them in the same change.

## 1. Repository layout

```text
ssh-vpn-client-luci-app-shadow-ucode/                              (repository root)
  install.sh                                    owner: packaging
  build/mk_apk.sh build/po2lmo.py build/VERSION owner: packaging
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
    files/usr/share/ucode/shadow-vpn/
      const.uc config.uc secrets.uc state.uc xray.uc               owner: runtime
      links.uc                                                     owner: links
      validate.uc lists.uc routing.uc                              owner: routing
      ssh.uc keys.uc                                               owner: ssh
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
  .github/workflows/ci.yml .github/workflows/release.yml           CI and releases (DESIGN.md §11, §12)
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
```

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
          lists_refresh: int /* hours, 0 = manual */, log_level: 'info'|'warning'|'error' },
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
attention_add(code, message, extra?)  attention_dismiss(id)  attention_list()
job_write(id, patch)  job_read(id)
```

CLIs (all take the lock themselves unless noted):

| Command | Does |
|---|---|
| `apply converge [--connect] [--from-init] [--boot]` | DESIGN §6.3 (desired state from UCI). `--connect` (an explicit Connect) clears `fatal`, `xray.fatal`, `xray.quick` under the lock and writes a new `gen`, so procd restarts both instances |
| `apply teardown [--from-init]` | DESIGN §6.4 |
| `apply render <dir> [--config <uci dir>]` | renders every file into `<dir>` without touching the system (unit/e2e tests) |
| `gate-set` | recomputes the gate verdict (DESIGN §6.7); when the installed dnsmasq conf is not the verdict's variant it leaves `pending`, and the converge that follows installs it; `flock -n` |
| `job <name> [args]` | detached (start-stop-daemon -b); names: `converge [--connect]`, `check [host:port]`, `list-refresh <proxy\|direct\|due>`, `wan-up`, `post-start <gen> [--check]`; prints the job id (`<monotonic s>-<ns>`) |
| `tunnel-check [host:port]` | DESIGN §10, prints the JSON result and writes `RUN/check.json` |

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
	// when a session comes up), not by other converges; Off clears every code of a run (DESIGN §6.4)
// RUN/jobs/<id>.json
{ id, name, state: 'running'|'done'|'failed', started: epoch, finished: epoch|null, result: {} }
// RUN/check.json
{ ok: bool, outcome: 'tls'|'tls-alert'|'http'|'bytes'|'silent'|'refused'|'local'|'timeout', detail, ms, endpoint, at: epoch,
  message, socks_code? }
	// detail: the HTTP status line for 'http', the RFC 1928 reply code also in socks_code for 'refused', a
	// sentence otherwise; message: the log line
// RUN/gate: '' | 'accept'
// RUN/patterns: JSON from routing.patterns()
```

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
`pin.<sid>`, `next/` (the render being checked). The dnsmasq conf in the confdir is 0644, written through
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

Writes made through the plugin are committed with the ucode `uci` cursor and followed by `job converge` (no
`config.change` event is emitted for them). `set_enabled(true)` spawns `job converge --connect` when it turns Shadow
on, when `RUN/fatal` exists or when the phase is `error` (an explicit Connect), a plain `job converge` otherwise.
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

## 10. Tests

- `tests/unit/run.sh [pattern]` runs every `tests/unit/*_test.uc` in a throwaway container of the lab image
  `shadow-testenv/tr3000-deps:25.12.6` with `--cap-add NET_ADMIN` and a copy of the package tree at `/src`
  (streamed in with tar, not bind-mounted: OrbStack bind mounts can serve a stale copy of a fresh file):
  `ucode -L /src/shadow-vpn/files/usr/share/ucode <test>`. Tests may run `nft -c -f`, `dnsmasq --test` and
  `xray run -test` there. A test prints `ok <name>` / `not ok <name>: <why>` and exits non-zero on failure.
- E2E runs in the lab (`tests/lab/`); only one agent drives it at a time. `tests/lab/e2e-shadow.sh [install]
  [stage1] …` installs the build the real way (install.sh with `SHADOW_BASE_URL` from a throwaway package server on
  the lab WAN) and runs the scenario checks of each stage (`stage1` main paths, `stage2` failure handling,
  `stage2.<group>` one group of it, `stage3` boot/upgrade/removal/LuCI, `stage3.<group>` one group of it); it is
  re-runnable on a lab from `up.sh`. Host-side docker tests outside run.sh: `tests/unit/ssh/e2e.sh`,
  `tests/unit/luci/rpcd-smoke.sh`, `tests/unit/packaging/install_test.sh` (the factory rootfs: refusals, an
  unreachable source and one with no release, fresh install, `apk del` on the factory world, a new latest release
  during the download, upgrade, downgrade, `--uninstall`, and at the end the latest release published on GitHub,
  installed by this install.sh the way a router does, or "no release is published yet" while there is none;
  `PUBLISHED_RELEASE=skip` skips that part, release runs do). Like run.sh they copy sources and builds into their containers with tar, never through a bind
  mount. `node tests/unit/luci/check_views.mjs` compiles the views as LuCI does, checks their msgids against the
  template and that every backend message translates through the Russian catalog.
- All of it runs on any arm64 Docker host (OrbStack on Apple Silicon, a Linux arm64 machine) and in CI
  (`.github/workflows/ci.yml` on GitHub's `ubuntu-24.04-arm`: jobs `unit`, `host-docker` and `lab`), which
  `.github/workflows/release.yml` also runs (`workflow_call`) on the commit it releases before it builds anything.
- Every test is deterministic: no assertion races random jitter or a tight timer window.
