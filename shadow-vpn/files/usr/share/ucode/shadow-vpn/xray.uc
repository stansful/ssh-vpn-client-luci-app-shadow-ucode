'use strict';

import {
	MARK_XRAY, PORT_TPROXY, PORT_DNS, PORT_SSH, PORT_CHECK, PORT_METRICS, OBSERVATORY, PRIVATE_NETS, DOH_SERVER,
	DNS_STALE_SEC
} from 'shadow-vpn.const';

// Shadow's debug keeps xray at info: info already logs several lines per connection (the device's address,
// the sniffed name), and xray's own debug adds far more, which would push Shadow's lines out of logd's ring
// buffer within seconds (DESIGN.md 6.8).
const LOG_LEVELS = { debug: 'info', info: 'info', warning: 'warning', error: 'error' };

function clone(v) {
	return json(sprintf('%J', v));
}

function with_mark(outbound) {
	outbound.streamSettings ??= {};
	outbound.streamSettings.sockopt ??= {};
	outbound.streamSettings.sockopt.mark = MARK_XRAY;

	return outbound;
}

function tproxy_inbound(tag, listen) {
	return {
		tag, listen, port: PORT_TPROXY, protocol: 'dokodemo-door',
		settings: { network: 'tcp,udp', followRedirect: true },
		streamSettings: { sockopt: { tproxy: 'tproxy', mark: MARK_XRAY } },
		sniffing: { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: false }
	};
}

function parse_cidr(value) {
	let parts = split(value, '/');
	let addr = iptoarr(parts[0]);

	if (!addr)
		return null;

	let bits = length(addr) * 8;
	let prefix = (length(parts) > 1) ? int(parts[1]) : bits;

	return (prefix >= 0 && prefix <= bits) ? { addr, prefix } : null;
}

function overlaps(a, b) {
	if (length(a.addr) != length(b.addr))
		return false;

	let n = min(a.prefix, b.prefix);

	for (let i = 0; i < length(a.addr) && n > 0; i++, n -= 8) {
		let mask = (n >= 8) ? 255 : ((255 << (8 - n)) & 255);

		if ((a.addr[i] & mask) != (b.addr[i] & mask))
			return false;
	}

	return true;
}

// User IP rules that point into a private range (a network behind the server, e.g. 10.8.0.0/16) must
// win over the private-target block, so they get an allow rule placed before it.
function private_user_ips(model) {
	let private_nets = map(PRIVATE_NETS, parse_cidr);
	let out = [];

	for (let r in model.rules) {
		if (!r.enabled || r.type != 'ip')
			continue;

		let net = parse_cidr(r.value);

		if (!net)
			continue;

		for (let p in private_nets) {
			if (overlaps(net, p)) {
				push(out, r.value);
				break;
			}
		}
	}

	return out;
}

function proxy_outbound(model, ctx) {
	if (model.main.transport == 'ssh')
		return { ok: true, outbound: {
			tag: 'proxy', protocol: 'socks',
			settings: { address: '127.0.0.1', port: PORT_SSH },
			streamSettings: { sockopt: { mark: MARK_XRAY } }
		} };

	let ob = ctx?.outbound;

	if (type(ob) != 'object' || type(ob.protocol) != 'string')
		return { ok: false, error: 'The selected Xray profile has no usable outbound.' };

	ob = clone(ob);
	ob.tag = 'proxy';

	return { ok: true, outbound: with_mark(ob) };
}

// The whole xray config of DESIGN.md 7.4 for the current model. ctx: { outbound, vision }.
function render(model, ctx) {
	let m = model.main;
	let proxy = proxy_outbound(model, ctx);

	if (!proxy.ok)
		return proxy;

	// ::1 is bound only when IPv6 is diverted; with ipv6=0 nft rejects IPv6 before it reaches xray.
	let tproxy_tags = m.ipv6 ? [ 'tproxy-in', 'tproxy6-in' ] : [ 'tproxy-in' ];
	let inbounds = [ tproxy_inbound('tproxy-in', '127.0.0.1') ];

	if (m.ipv6)
		push(inbounds, tproxy_inbound('tproxy6-in', '::1'));

	push(inbounds,
		{ tag: 'dns-in', listen: '127.0.0.1', port: PORT_DNS, protocol: 'dokodemo-door',
		  settings: { address: '1.1.1.1', port: 53, network: 'tcp,udp' } },
		{ tag: 'check-in', listen: '127.0.0.1', port: PORT_CHECK, protocol: 'socks',
		  settings: { auth: 'noauth', udp: false } });

	let rules = [
		{ inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' },
		{ inboundTag: [ 'check-in' ], outboundTag: 'proxy' }
	];

	// ssh -D carries no UDP: block it here too, in case nft let some through.
	if (m.transport == 'ssh')
		push(rules, { inboundTag: tproxy_tags, network: 'udp', outboundTag: 'block' });

	let allowed = private_user_ips(model);

	if (length(allowed))
		push(rules, { inboundTag: tproxy_tags, ip: allowed, balancerTag: 'tunnel' });

	push(rules,
		{ inboundTag: tproxy_tags, domain: [ 'full:localhost' ], outboundTag: 'block' },
		{ inboundTag: tproxy_tags, ip: [ ...PRIVATE_NETS ], outboundTag: 'block' },
		{ inboundTag: [ ...tproxy_tags, 'dns-internal' ], balancerTag: 'tunnel' });

	let config = {
		log: { loglevel: LOG_LEVELS[m.log_level] ?? 'warning', access: 'none', dnsLog: false },
		policy: { levels: { '0': { handshake: 4, connIdle: 300, uplinkOnly: 1, downlinkOnly: 1, bufferSize: 4 } } },
		metrics: { tag: 'metrics', listen: `127.0.0.1:${PORT_METRICS}` },
		burstObservatory: { subjectSelector: [ 'proxy' ], pingConfig: { ...OBSERVATORY } },
		// a short stall of the tunnel no longer fails lookups of names in use: their expired records answer at once
		dns: { tag: 'dns-internal', queryStrategy: m.ipv6 ? 'UseIP' : 'UseIPv4', serveStale: true,
			serveExpiredTTL: DNS_STALE_SEC, servers: [ DOH_SERVER ] },
		inbounds,
		outbounds: [
			proxy.outbound,
			{ tag: 'direct', protocol: 'freedom', streamSettings: { sockopt: { mark: MARK_XRAY } } },
			{ tag: 'block', protocol: 'blackhole' },
			{ tag: 'dns-out', protocol: 'dns', settings: { nonIPQuery: 'reject' } }
		],
		routing: {
			domainStrategy: 'AsIs',
			balancers: [ {
				tag: 'tunnel', selector: [ 'proxy' ],
				fallbackTag: m.kill_switch ? 'block' : 'direct',
				strategy: { type: 'random' }
			} ],
			rules
		}
	};

	return { ok: true, config };
}

export { render, private_user_ips, parse_cidr, overlaps };
