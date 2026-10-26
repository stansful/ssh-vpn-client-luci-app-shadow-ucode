'use strict';

// Routing (DESIGN §7): which names go to which dnsmasq-filled set, the nft ruleset and the dnsmasq
// files. Every value reaching a rendered file passes a validator here; invalid ones are skipped.

import { NFT_TABLE, MARK_TPROXY, MARK_XRAY, PORT_TPROXY, PORT_DNS } from 'shadow-vpn.const';
import { domain_rule, ip_rule, device_rule, ip_address, dns_name, ifname } from 'shadow-vpn.validate';

const T = `inet ${NFT_TABLE}`;
const MARK = sprintf('0x%08x', MARK_TPROXY);
const XRAY_MARK = sprintf('0x%08x', MARK_XRAY);
const TUNNEL_DNS = `127.0.0.1#${PORT_DNS}`;
const KINDS = [ 'user', 'proxy', 'direct' ];
const MAX_LINE = 1024;
const ELEMENTS_PER_LINE = 256;

const LOCAL4 = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
	'192.168.0.0/16', '224.0.0.0/4', '240.0.0.0/4' ];
const LOCAL6 = [ '::/127', 'fc00::/7', 'fe80::/10', 'ff00::/8' ];

// The definitions never depend on settings, so a re-render keeps the table and the elements dnsmasq
// added. Changing one needs `recreate` (see nft_needs_recreate).
const SETS = [
	[ 'local4', 'type ipv4_addr; flags interval; auto-merge;' ],
	[ 'local6', 'type ipv6_addr; flags interval; auto-merge;' ],
	[ 'server4', 'type ipv4_addr; flags interval; auto-merge;' ],
	[ 'server6', 'type ipv6_addr; flags interval; auto-merge;' ],
	[ 'user4', 'type ipv4_addr;' ],
	[ 'user6', 'type ipv6_addr;' ],
	[ 'user4_net', 'type ipv4_addr; flags interval; auto-merge;' ],
	[ 'user6_net', 'type ipv6_addr; flags interval; auto-merge;' ],
	[ 'proxy4', 'type ipv4_addr;' ],
	[ 'proxy6', 'type ipv6_addr;' ],
	[ 'direct4', 'type ipv4_addr;' ],
	[ 'direct6', 'type ipv6_addr;' ],
	[ 'dev4', 'type ipv4_addr; flags interval; auto-merge;' ],
	[ 'dev6', 'type ipv6_addr; flags interval; auto-merge;' ],
	[ 'dev_mac', 'type ether_addr;' ],
	[ 'lan_if', 'type ifname;' ],
	[ 'dns_upstream4', 'type ipv4_addr;' ],
	[ 'dns_upstream6', 'type ipv6_addr;' ],
	[ 'fetch4', 'type ipv4_addr; flags timeout; timeout 60s;' ]
];

// Sets whose content comes from UCI or ctx; every render flushes and refills them.
export const STATIC_SETS = [ 'local4', 'local6', 'server4', 'server6', 'user4_net', 'user6_net', 'dev4', 'dev6',
	'dev_mac', 'lan_if', 'dns_upstream4', 'dns_upstream6' ];
// Sets dnsmasq fills; a render keeps them (flush them with changed_sets()).
export const DNSMASQ_SETS = [ 'user4', 'user6', 'proxy4', 'proxy6', 'direct4', 'direct6' ];

const CHAINS = [ 'dns_hijack', 'prerouting', 'divert', 'gate', 'output', 'gate_out' ];
const HOOKS = {
	dns_hijack: 'type nat hook prerouting priority dstnat - 5; policy accept;',
	prerouting: 'type filter hook prerouting priority mangle - 1; policy accept;',
	output: 'type route hook output priority mangle - 1; policy accept;'
};

function uniq_sorted(list) {
	let seen = {};

	for (let v in list)
		seen[v] = true;

	return sort(keys(seen));
}

function parent(name) {
	let dot = index(name, '.');

	return (dot >= 0) ? substr(name, dot + 1) : null;
}

// The value of the nearest strict ancestor of name in map, or null.
function ancestor(name, map) {
	for (let n = parent(name); n != null; n = parent(n))
		if (exists(map, n))
			return map[n];

	return null;
}

function covered(name, set) {
	return exists(set, name) || ancestor(name, set) != null;
}

// desktop isLocalDestinationHost for a name pattern. A single label from a list ('ua') is a suffix,
// not an intranet host, so only localhost and the mDNS domain count.
function local_name(name) {
	return name == 'localhost' || name == 'local' || substr(name, -6) == '.local';
}

function list_names(model, lists, kind) {
	if (model?.lists?.[kind]?.enabled === false)
		return [];

	let out = [];

	for (let d in lists?.[kind] ?? [])
		if (type(d) == 'string' && d != '')
			push(out, (substr(d, 0, 1) == '.') ? substr(d, 1) : d);

	return out;
}

// Names that must never resolve through the tunnel: the VPN server hosts and the router's NTP servers (a
// router without a battery clock boots with a stale time, and TLS and VMess need the right one before the
// tunnel works). IP literals need no exemption; the rest is normalized.
function exempt_names(server_hosts) {
	let out = [];

	for (let h in server_hosts ?? []) {
		let s = replace(trim(`${h ?? ''}`), /^\[(.*)\]$/, '$1');

		if (ip_address(s) == null && dns_name(s) != null)
			push(out, dns_name(s));
	}

	return uniq_sorted(out);
}

// DESIGN §7.2: dnsmasq uses only the longest matching nftset= entry, so every pattern P goes to exactly
// one set, chosen by the desktop decision (traffic-policy.ts) for the name P. Every pattern matching a
// name N is a suffix of N, so the longest one carries the decision for N. Device rules match by source
// and the mode decides only what no pattern names, so neither changes the set of a pattern; proxy-list
// patterns are kept in full mode too, so an address shared with a direct name stays tunnelled.
// server_hosts: the server hosts and the NTP server names (exempt_names).
export function patterns(model, lists, server_hosts) {
	let user = {}, proxy = {}, direct = {};

	for (let r in model?.rules ?? []) {
		if (r?.enabled && r.type == 'domain') {
			let d = domain_rule(r.value);

			if (d.value)
				user[d.value] = true;
		}
	}

	for (let d in list_names(model, lists, 'proxy')) proxy[d] = true;
	for (let d in list_names(model, lists, 'direct')) direct[d] = true;

	let exempt = exempt_names(server_hosts), skip = {};
	let out = { user: [], proxy: [], direct: [], exempt };

	for (let h in exempt)
		skip[h] = true;

	for (let p in uniq_sorted([ ...keys(user), ...keys(proxy), ...keys(direct) ])) {
		if (skip[p])
			continue;

		if (covered(p, user))
			push(out.user, p);
		else if (local_name(p) || covered(p, direct))
			push(out.direct, p);
		else
			push(out.proxy, p);
	}

	return out;
};

function kinds_map(p) {
	let map = {};

	for (let kind in KINDS)
		for (let name in p?.[kind] ?? [])
			map[name] = kind;

	return map;
}

// Both kinds send their addresses into the tunnel, so a name moving between them changes nothing.
function both_divert(a, b) {
	return a != 'direct' && b != 'direct';
}

// dnsmasq-filled sets that hold addresses the new patterns route another way (DESIGN §6.5): a pattern that
// moved into or out of the direct set, a removed user rule or direct pattern, or a new pattern under an old
// one of another set (its names used to land in the old set). A flush empties the whole set, so it is left
// out where nothing would change: a move between the user and the proxy set, both of which divert, and a
// name a list refresh dropped from the proxy list (its stale addresses err on the tunnel side and go at Off
// or reboot). A proxy list that is gone as a whole (turned off) is flushed.
export function changed_sets(old_patterns, new_patterns) {
	let old_map = kinds_map(old_patterns), new_map = kinds_map(new_patterns), flush = {};
	let proxy_gone = length(old_patterns?.proxy ?? []) > 0 && !length(new_patterns?.proxy ?? []);

	for (let name, kind in old_map) {
		let now = new_map[name];

		if (now == kind || (now != null && both_divert(kind, now)))
			continue;

		if (now == null && kind == 'proxy' && !proxy_gone)
			continue;

		flush[kind] = true;
	}

	for (let name, kind in new_map) {
		if (exists(old_map, name))
			continue;

		let was = ancestor(name, old_map);

		if (was != null && was != kind && !both_divert(was, kind))
			flush[was] = true;
	}

	let out = [];

	for (let kind in KINDS)
		if (flush[kind])
			push(out, `${kind}4`, `${kind}6`);

	return out;
};

function options(model, ctx) {
	let m = model?.main ?? {};
	let ssh = (m.transport ?? 'ssh') != 'xray';
	let full = (m.mode ?? 'proxy-all') != 'selected-rules';

	return {
		ssh, full,
		ipv6: m.ipv6 ?? false,
		router_traffic: m.router_traffic ?? true,
		dns_redirect: m.dns_redirect ?? true,
		tunnel_dns: m.tunnel_dns ?? true,
		// UDP cannot cross ssh -D; 'direct' is offered in full mode only (DESIGN §5)
		udp_direct: ssh && full && m.ssh_udp == 'direct',
		// ctx.vision_udp443: the profile is VLESS Vision without -udp443, which drops QUIC itself
		vision_udp443: !ssh && !!ctx?.vision_udp443,
		gate: (ctx?.gate == 'accept') ? 'accept' : ''
	};
}

// Rule pairs for both families: v46('daddr @user%d goto divert').
function v46(fmt) {
	return [ 'ip ' + sprintf(fmt, 4), 'ip6 ' + sprintf(fmt, 6) ];
}

// LAN hosts that are the router's own upstreams (Pi-hole, AdGuard Home) are exempt, or their queries
// would loop back into dnsmasq.
function dns_hijack_rules() {
	return map(v46('saddr != @dns_upstream%d meta l4proto { tcp, udp } th dport 53 fib daddr type != local redirect to :53'),
		(r) => `iifname @lan_if ${r}`);
}

function prerouting_rules(o) {
	let rules = [
		`iifname @lan_if meta l4proto tcp socket transparent 1 meta mark set ${MARK} accept`,
		`iif "lo" meta l4proto tcp socket transparent 1 meta mark set ${MARK} accept`,
		'ct direction reply return',
		'ct status dnat return',
		// only TCP and UDP can be tproxied: ICMP (ping, PMTU) and other protocols always go direct
		'meta l4proto != { tcp, udp } return',
		`iif "lo" meta mark & ${MARK} == ${MARK} goto divert`,
		'iifname != @lan_if return',
		// the router itself, and LAN broadcast and multicast (DHCP, SSDP, mDNS): before the user sets, so a
		// rule as wide as 0.0.0.0/0 never takes them from dnsmasq and the other local listeners
		'fib daddr type { local, broadcast, multicast } return',
		'ip6 daddr ff00::/8 return',
		'th dport 53 return',
		...v46('daddr @server%d accept'),
		...v46('daddr @user%d goto divert'),
		...v46('daddr @user%d_net goto divert'),
		...v46('daddr @local%d return'),
		...v46('saddr @dev%d goto divert'),
		'ether saddr @dev_mac goto divert',
		...v46('daddr @proxy%d goto divert'),
		...v46('daddr @direct%d return')
	];

	if (o.full)
		push(rules, 'goto divert');

	return rules;
}

function divert_rules(o) {
	let rules = [ 'jump gate' ];

	if (!o.ipv6)
		push(rules, 'meta nfproto ipv6 reject with icmpx admin-prohibited');

	if (o.ssh)
		push(rules, o.udp_direct ? 'meta l4proto udp return' : 'meta l4proto udp reject with icmpx port-unreachable');
	else if (o.vision_udp443)
		push(rules, 'udp dport 443 reject with icmpx port-unreachable');

	push(rules, `meta nfproto ipv4 meta l4proto { tcp, udp } meta mark set ${MARK} tproxy ip to 127.0.0.1:${PORT_TPROXY} accept`);

	if (o.ipv6)
		push(rules, `meta nfproto ipv6 meta l4proto { tcp, udp } meta mark set ${MARK} tproxy ip6 to [::1]:${PORT_TPROXY} accept`);

	// reached only when nothing listens on the tproxy port: fail fast instead of a black hole
	push(rules, 'meta l4proto tcp reject with tcp reset', 'reject with icmpx port-unreachable');

	return rules;
}

// Router traffic is marked here and re-enters prerouting on lo (table 106); fetch4 is the list
// download's way through the tunnel (DESIGN §9) and works without router_traffic.
function output_rules(o) {
	let rules = [
		'ct direction reply return',
		`meta mark & ${XRAY_MARK} == ${XRAY_MARK} return`,
		'th dport 53 return',
		'ip daddr @fetch4 jump gate_out'
	];

	if (o.router_traffic) {
		push(rules,
			'udp dport { 67, 68, 123 } return',
			'fib daddr type { local, broadcast, multicast } return',
			'ip6 daddr ff00::/8 return',
			...v46('daddr @server%d return'),
			...v46('daddr @local%d return'),
			...v46('daddr @user%d jump gate_out'),
			...v46('daddr @user%d_net jump gate_out'),
			...v46('daddr @proxy%d jump gate_out'));

		if (o.full)
			push(rules, ...v46('daddr != @direct%d jump gate_out'));
	}

	return rules;
}

function gate_out_rules(o) {
	// UDP that goes direct in SSH mode must not be marked: on lo it would reach no socket.
	return [ 'jump gate', `meta l4proto ${o.udp_direct ? 'tcp' : '{ tcp, udp }'} meta mark set ${MARK} accept` ];
}

function definitions() {
	let lines = [ `table ${T} {` ];

	for (let s in SETS)
		push(lines, `\tset ${s[0]} { ${s[1]} }`);

	for (let c in CHAINS)
		push(lines, HOOKS[c] ? `\tchain ${c} { ${HOOKS[c]} }` : `\tchain ${c} { }`);

	push(lines, '}');

	return lines;
}

function add_cidr(list, v, family) {
	let r = ip_rule(v);

	if (r.cidr && r.family == family)
		push(list, r.cidr);
}

function static_elements(model, ctx) {
	let e = {
		local4: [ ...LOCAL4 ], local6: [ ...LOCAL6 ], server4: [], server6: [], user4_net: [], user6_net: [],
		dev4: [], dev6: [], dev_mac: [], lan_if: [], dns_upstream4: [], dns_upstream6: []
	};

	for (let v in ctx?.server4 ?? []) add_cidr(e.server4, v, 4);
	for (let v in ctx?.server6 ?? []) add_cidr(e.server6, v, 6);

	// the router's own LAN-side networks (a delegated IPv6 prefix on every segment, a routed public
	// subnet): traffic between them stays local like RFC 1918 does
	for (let v in ctx?.local_nets ?? []) {
		add_cidr(e.local4, v, 4);
		add_cidr(e.local6, v, 6);
	}

	for (let r in model?.rules ?? []) {
		if (!r?.enabled)
			continue;

		if (r.type == 'ip') {
			add_cidr(e.user4_net, r.value, 4);
			add_cidr(e.user6_net, r.value, 6);
		}
		else if (r.type == 'device') {
			let d = device_rule(r.value);

			if (d.kind == 'mac') push(e.dev_mac, d.value);
			else if (d.kind == 'ip4') push(e.dev4, d.value);
			else if (d.kind == 'ip6') push(e.dev6, d.value);
		}
	}

	for (let v in ctx?.dns_upstream4 ?? []) {
		let a = ip_address(v);

		if (a?.family == 4) push(e.dns_upstream4, a.addr);
	}

	for (let v in ctx?.dns_upstream6 ?? []) {
		let a = ip_address(v);

		if (a?.family == 6) push(e.dns_upstream6, a.addr);
	}

	for (let v in ctx?.lan_ifs ?? [])
		if (ifname(v)) push(e.lan_if, `"${v}"`);

	if (!length(e.lan_if))
		push(e.lan_if, '"br-lan"');

	return e;
}

function element_lines(e) {
	let lines = [];

	for (let name in STATIC_SETS) {
		let list = uniq_sorted(e[name]);

		for (let i = 0; i < length(list); i += ELEMENTS_PER_LINE)
			push(lines, `add element ${T} ${name} { ${join(', ', slice(list, i, i + ELEMENTS_PER_LINE))} }`);
	}

	return lines;
}

function chain_block(name, rules) {
	let lines = [ `\tchain ${name} {` ];

	if (HOOKS[name])
		push(lines, `\t\t${HOOKS[name]}`);

	for (let r in rules)
		push(lines, `\t\t${r}`);

	push(lines, '\t}');

	return lines;
}

// The whole ruleset of DESIGN §7.3 as ONE `nft -f` transaction. It keeps the table, so the sets dnsmasq
// filled keep their elements, but flushes every rule and every static set before re-adding them, so a
// deleted rule or device stops matching at once. ctx.recreate deletes the table first (a set definition
// changed); keep the render without it as table.nft, which heals re-apply. ctx: see CONTRACTS §6;
// ctx.patterns is not needed here (dnsmasq fills the name sets).
export function render_nft(model, ctx) {
	let o = options(model, ctx);
	let out = [ `# shadow-vpn ruleset: mode=${o.full ? 'proxy-all' : 'selected-rules'} transport=${o.ssh ? 'ssh' : 'xray'} gate=${o.gate || 'empty'}` ];

	if (ctx?.recreate)
		push(out, `table ${T}`, `delete table ${T}`);

	push(out, ...definitions(), `flush table ${T}`);

	for (let s in STATIC_SETS)
		push(out, `flush set ${T} ${s}`);

	if (!o.dns_redirect)
		push(out, `delete chain ${T} dns_hijack`);

	push(out, ...element_lines(static_elements(model, ctx)), `table ${T} {`);

	if (o.dns_redirect)
		push(out, ...chain_block('dns_hijack', dns_hijack_rules()));

	push(out,
		...chain_block('prerouting', prerouting_rules(o)),
		...chain_block('divert', divert_rules(o)),
		...chain_block('gate', (o.gate == 'accept') ? [ 'accept' ] : []),
		...chain_block('output', output_rules(o)),
		...chain_block('gate_out', gate_out_rules(o)),
		'}');

	return join('\n', out) + '\n';
};

// The definitions block of a rendered ruleset: from the first `table … {` line to its `}`.
function definitions_of(text) {
	let lines = split(text ?? '', '\n'), start = index(lines, `table ${T} {`);

	if (start < 0)
		return null;

	let end = index(slice(lines, start), '}');

	return (end < 0) ? null : join('\n', slice(lines, start, start + end));
}

// True when the table loaded from old_text has other set or chain definitions than new_text, so the new
// render must use ctx.recreate (the kernel refuses to redefine a set in place).
export function nft_needs_recreate(old_text, new_text) {
	let old_defs = definitions_of(old_text);

	return old_defs != null && old_defs != definitions_of(new_text);
};

// True when addr (canonical) lies in one of the CIDRs.
function in_nets(addr, nets) {
	let a = iptoarr(addr);

	for (let cidr in nets ?? []) {
		let p = split(cidr, '/'), n = iptoarr(p[0]);

		if (!a || !n || length(a) != length(n))
			continue;

		let bits = (length(p) > 1) ? +p[1] : length(n) * 8, same = true;

		for (let i = 0; bits > 0 && same; i++, bits -= 8) {
			let mask = (bits >= 8) ? 0xff : (0xff << (8 - bits)) & 0xff;

			same = (a[i] & mask) == (n[i] & mask);
		}

		if (same)
			return true;
	}

	return false;
}

// One dnsmasq upstream ("addr" or "addr#port") taken apart, or null when it is not one.
export function upstream_of(v) {
	let m = match(trim(`${v ?? ''}`), /^([0-9A-Fa-f.:]+)(#([0-9]{1,5}))?$/);
	let a = m ? ip_address(m[1]) : null;
	let port = m?.[3] ? +m[3] : 53;

	if (!a || port < 1 || port > 65535)
		return null;

	return {
		addr: a.addr, family: a.family, port, text: (port == 53) ? a.addr : `${a.addr}#${port}`,
		loopback: a.addr == '::1' || match(a.addr, /^127\./) != null,
		local: in_nets(a.addr, (a.family == 4) ? LOCAL4 : LOCAL6)
	};
};

// dnsmasq itself (an instance listing itself would loop) or our tunnel DNS port.
function own_resolver(u) {
	return u.loopback && (u.port == PORT_DNS || (u.port == 53 && (u.addr == '127.0.0.1' || u.addr == '::1')));
}

// Upstreams for `server=` ("addr" or "addr#port"), never dnsmasq itself or our tunnel DNS port. A forwarder
// on another loopback address (dnscrypt-proxy on 127.0.0.53, say) is a real upstream.
function upstreams(list) {
	let out = [];

	for (let v in list ?? []) {
		let u = upstream_of(v);

		if (u && !own_resolver(u))
			push(out, u.text);
	}

	return uniq_sorted(out);
}

// In full mode the router's own traffic goes through the tunnel (router_traffic), so does a resolver whose
// lookups leave the router other than as plain DNS: a forwarder on the router (https-dns-proxy, stubby,
// dnscrypt-proxy: their upstream is encrypted) or a server on another port than 53 outside the local
// ranges. Such a resolver can never resolve the name of the VPN server that the tunnel needs.
function router_tunnelled(o, u) {
	return o.full && o.router_traffic && (u.loopback || (u.port != 53 && !u.local));
}

// The upstreams whose lookups go through the tunnel in full mode (DESIGN §7.2), [] otherwise.
export function tunnelled_upstreams(model, list) {
	let o = options(model, {}), out = [];

	for (let v in list ?? []) {
		let u = upstream_of(v);

		if (u && !own_resolver(u) && router_tunnelled(o, u))
			push(out, u.text);
	}

	return uniq_sorted(out);
};

// The upstreams that can resolve what must never wait for the tunnel (the VPN server's name, the router's
// time servers) in full mode: plain DNS on port 53 (the output chain lets it out directly) to a server
// outside the LAN (a LAN resolver forwards from the LAN, which full mode tunnels, and may use DoH itself).
export function bootstrap_upstreams(model, list, lan_nets) {
	let o = options(model, {}), out = [];

	for (let v in list ?? []) {
		let u = upstream_of(v);

		if (u && !own_resolver(u) && !router_tunnelled(o, u) && !in_nets(u.addr, lan_nets))
			push(out, u.text);
	}

	return uniq_sorted(out);
};

// "prefix=/a/b/c/target" lines with as many names per line as fit MAX_LINE.
function domain_lines(prefix, names, target) {
	let lines = [], line = null;

	for (let n in names) {
		if (line != null && length(line) + length(n) + length(target) + 2 > MAX_LINE) {
			push(lines, `${line}/${target}`);
			line = null;
		}

		line = (line == null) ? `${prefix}=/${n}` : `${line}/${n}`;
	}

	if (line != null)
		push(lines, `${line}/${target}`);

	return lines;
}

function pattern_names(p, kind) {
	let out = [];

	for (let n in p?.[kind] ?? [])
		if (dns_name(n) == n)
			push(out, n);

	return out;
}

// name -> set ('user', 'proxy', 'direct') of every valid pattern
function sets_of(p) {
	let set_of = {};

	for (let kind in KINDS)
		for (let n in pattern_names(p, kind))
			set_of[n] = kind;

	return set_of;
}

// dnsmasq uses only the longest matching server=/name/ (as for nftset=), so a name needs its own line
// only where its resolver differs from the one its nearest listed ancestor, or the default, gives.
// Exempt names (server hosts, time servers) always get one: they must never wait for the tunnel they
// bring up. Resolvers: 'tunnel', 'normal' (direct names) and 'exempt'.
function upstream_lines(set_of, exempt, fallback) {
	let resolver = {}, forced = {}, out = { normal: [], tunnel: [], exempt: [] };

	for (let n, kind in set_of)
		resolver[n] = (kind == 'direct') ? 'normal' : 'tunnel';

	for (let n in exempt) {
		resolver[n] = 'exempt';
		forced[n] = true;
	}

	for (let n in sort(keys(resolver)))
		if (forced[n] || resolver[n] != (ancestor(n, resolver) ?? fallback))
			push(out[resolver[n]], n);

	return out;
}

// Full mode with tunnel DNS makes the tunnel dnsmasq's default upstream (no-resolv), but the plain
// upstreams of the instance's own UCI `server` list stay default upstreams next to it, so dnsmasq sends
// some lookups there directly. Returns those upstreams ("addr" or "addr#port"); per-domain entries
// (/zone/addr) are the user's explicit choice, and dnsmasq itself and our own port are not counted, nor
// is a resolver whose lookups go through the tunnel anyway (a forwarder on the router while
// router_traffic is on: tunnelled_upstreams).
export function dns_leak(model, uci_servers) {
	let o = options(model, {});

	if (!o.full || !o.tunnel_dns)
		return [];

	let list = (type(uci_servers) == 'array') ? uci_servers : (type(uci_servers) == 'string' ? [ uci_servers ] : []);
	let out = [];

	for (let v in list) {
		let u = upstream_of(v);

		if (u && !own_resolver(u) && !router_tunnelled(o, u))
			push(out, u.text);
	}

	return uniq_sorted(out);
};

export const HEADER = '# Generated by shadow-vpn. Do not edit.';

// host-record lines for the exempt names whose last known addresses ctx.host_addrs gives.
function host_records(exempt, host_addrs) {
	let out = [];

	for (let n in exempt) {
		for (let ip in uniq_sorted(host_addrs?.[n] ?? [])) {
			let a = ip_address(ip);

			if (a)
				push(out, `host-record=${n},${a.addr}`);
		}
	}

	return out;
}

// The dnsmasq conf-dir file (DESIGN §6.5, §7.2): the nftset= lines, the names that must use the normal
// upstream and the tunnel server= lines, or, with ctx.tunnel_dns_up false (fallback mode while xray is
// down), the normal upstream for everything. dnsmasq reads it only at start, so switching between the two
// variants is a restart.
//
// Exempt names (the VPN server's, the router's time servers) go to ctx.bootstrap_dns in full mode: plain
// DNS outside the tunnel (bootstrap_upstreams). With none, they keep the normal upstream and the server
// names are answered from their last known addresses (ctx.host_addrs), so the tunnel never waits for itself.
//
// No servers-file= of ours: it may be given once only, and an instance that gets its own later (an ad
// blocker's UCI serversfile) would then refuse to start, taking DNS and DHCP down. max-ttl is the same, so
// it is left out when the instance sets max_ttl in UCI (ctx.uci.max_ttl).
export function render_dnsmasq(model, ctx) {
	let o = options(model, ctx);
	let p = ctx?.patterns ?? {};
	let wan = upstreams(ctx?.wan_dns), boot = upstreams(ctx?.bootstrap_dns);
	let no_resolv = o.full && o.tunnel_dns;
	let tunnel_up = o.tunnel_dns && ctx?.tunnel_dns_up !== false;
	let exempt = pattern_names(p, 'exempt');
	let conf = [ HEADER ];

	if (!ctx?.uci?.max_ttl)
		push(conf, 'max-ttl=300');

	if (no_resolv)
		push(conf, 'no-resolv');

	if (o.full && !o.ipv6)
		push(conf, 'filter-AAAA');

	let set_of = sets_of(p), names = sort(keys(set_of));

	for (let kind in KINDS)
		push(conf, ...domain_lines('nftset', filter(names, (n) => set_of[n] == kind && ancestor(n, set_of) != kind),
			`4#inet#${NFT_TABLE}#${kind}4,6#inet#${NFT_TABLE}#${kind}6`));

	// without tunnel DNS no name goes to the tunnel's DNS; full mode still keeps the exempt ones on a
	// resolver outside the tunnel
	let up = o.tunnel_dns ? upstream_lines(set_of, exempt, o.full ? 'tunnel' : 'normal')
		: { normal: [], tunnel: [], exempt: o.full ? exempt : [] };

	// once no-resolv is set, '#' would mean the tunnel default: name the WAN servers instead
	let normal = no_resolv ? wan : [ '#' ];
	let for_exempt = !o.full ? [ '#' ] : length(boot) ? boot : o.tunnel_dns ? normal : [];

	for (let a in normal)
		push(conf, ...domain_lines('server', up.normal, a));

	for (let a in for_exempt)
		push(conf, ...domain_lines('server', up.exempt, a));

	if (o.full && !length(boot))
		push(conf, ...host_records(exempt, ctx?.host_addrs));

	if (tunnel_up) {
		if (o.full)
			push(conf, `server=${TUNNEL_DNS}`);

		push(conf, ...domain_lines('server', up.tunnel, TUNNEL_DNS));
	}
	else if (no_resolv) {
		for (let a in wan)
			push(conf, `server=${a}`);
	}

	return { conf: join('\n', conf) + '\n' };
};
