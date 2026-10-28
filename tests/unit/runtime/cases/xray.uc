'use strict';

import { writefile, unlink } from 'fs';
import { render } from 'shadow-vpn.xray';
import { OBSERVATORY, MARK_XRAY, PRIVATE_NETS } from 'shadow-vpn.const';
import { ok, eq, run, done } from 'rt';

// What links.outbound() returns for a VLESS REALITY Vision link (fake credentials).
const OUTBOUND = {
	tag: 'proxy', protocol: 'vless',
	settings: { vnext: [ { address: '203.0.113.20', port: 443,
		users: [ { id: '772e13a3-c056-46fb-a72a-27e02c860cd6', flow: 'xtls-rprx-vision', encryption: 'none' } ] } ] },
	streamSettings: { network: 'raw', security: 'reality',
		realitySettings: { serverName: 'web.example', fingerprint: 'chrome',
			publicKey: 'uoa3YWTsfWaK12FGB7IpsfJM7SZqDL0j-DPrdlvegMk', shortId: '8da5a403f24009e8' } }
};

function model(main, rules) {
	return {
		main: {
			enabled: true, autostart: true, transport: 'ssh', ssh_server: 's_0123456789ab', xray_profile: null,
			mode: 'proxy-all', kill_switch: true, check_endpoint: 'youtube.com:443', check_after_connect: true,
			ssh_udp: 'reject', tunnel_dns: true, ipv6: false, dns_redirect: true, router_traffic: true,
			lists_refresh: 24, log_level: 'warning', ...main
		},
		lists: { proxy: { enabled: false }, direct: { enabled: false } },
		servers: [], keys: [], profiles: [], rules: rules ?? [], errors: []
	};
}

function xray_test(name, config) {
	let path = `/tmp/rt-xray-${name}.json`;

	writefile(path, sprintf('%.2J\n', config));

	let t = run(`xray run -test -c ${path}`);

	unlink(path);

	return ok(`xray/${name}: xray run -test accepts it`, t.rc == 0, t.out);
}

function by_tag(list, tag) {
	return filter(list, (x) => x.tag == tag)[0];
}

function rule_index(rules, pred) {
	for (let i = 0; i < length(rules); i++)
		if (pred(rules[i]))
			return i;

	return -1;
}

// SSH mode, kill switch on (defaults)
let ssh = render(model({}), {});

ok('xray/ssh: renders', ssh.ok, ssh.error);

let c = ssh.config;

xray_test('ssh', c);
eq('xray/ssh: proxy is the local ssh -D socks', by_tag(c.outbounds, 'proxy'),
	{ tag: 'proxy', protocol: 'socks', settings: { address: '127.0.0.1', port: 12346 }, streamSettings: { sockopt: { mark: MARK_XRAY } } });
eq('xray/ssh: balancer falls back to block', c.routing.balancers,
	[ { tag: 'tunnel', selector: [ 'proxy' ], fallbackTag: 'block', strategy: { type: 'random' } } ]);
eq('xray/ssh: observatory from const', c.burstObservatory, { subjectSelector: [ 'proxy' ], pingConfig: OBSERVATORY });

// xray 26.6.1 and later raise a burstObservatory interval under 10 s to 10 s (healthping.go `< 10*time.Second`),
// which doubles detection with OBSERVATORY's 5 s (DESIGN.md 13). Its warning about that is logged asynchronously
// and `xray run -test` usually exits before printing it, so the image's xray version is checked instead.
let xv = match(run('xray version').out, /Xray ([0-9]+)\.([0-9]+)\.([0-9]+)/);

ok('xray: OBSERVATORY assumes an xray before 26.6.1, which keeps the 5 s interval (DESIGN.md 13)',
	xv != null && int(xv[1]) * 1000000 + int(xv[2]) * 1000 + int(xv[3]) < 26006001, xv?.[0]);
eq('xray/ssh: metrics on 12348', c.metrics, { tag: 'metrics', listen: '127.0.0.1:12348' });
eq('xray/ssh: only the v4 tproxy inbound with ipv6=0', map(c.inbounds, (i) => i.tag), [ 'tproxy-in', 'dns-in', 'check-in' ]);
eq('xray/ssh: tproxy inbound', by_tag(c.inbounds, 'tproxy-in'), {
	tag: 'tproxy-in', listen: '127.0.0.1', port: 12345, protocol: 'dokodemo-door',
	settings: { network: 'tcp,udp', followRedirect: true },
	streamSettings: { sockopt: { tproxy: 'tproxy', mark: MARK_XRAY } },
	sniffing: { enabled: true, destOverride: [ 'http', 'tls', 'quic' ], routeOnly: false }
});
eq('xray/ssh: check-in socks without udp', by_tag(c.inbounds, 'check-in').settings.udp, false);
eq('xray/ssh: direct is marked', by_tag(c.outbounds, 'direct').streamSettings.sockopt.mark, MARK_XRAY);
eq('xray/ssh: dns-out rejects non-IP queries', by_tag(c.outbounds, 'dns-out').settings, { nonIPQuery: 'reject' });
eq('xray/ssh: DoH, IPv4 answers only, stale answers for an hour', c.dns,
	{ tag: 'dns-internal', queryStrategy: 'UseIPv4', serveStale: true, serveExpiredTTL: 3600, servers: [ 'https://1.1.1.1/dns-query' ] });
eq('xray/ssh: idle connections live 300 s', c.policy.levels['0'].connIdle, 300);
eq('xray/ssh: log', c.log, { loglevel: 'warning', access: 'none', dnsLog: false });

let rules = c.routing.rules;

eq('xray/ssh: first rules', slice(rules, 0, 3), [
	{ inboundTag: [ 'dns-in' ], outboundTag: 'dns-out' },
	{ inboundTag: [ 'check-in' ], outboundTag: 'proxy' },
	{ inboundTag: [ 'tproxy-in' ], network: 'udp', outboundTag: 'block' }
]);
eq('xray/ssh: private targets blocked before the tunnel', slice(rules, -3), [
	{ inboundTag: [ 'tproxy-in' ], domain: [ 'full:localhost' ], outboundTag: 'block' },
	{ inboundTag: [ 'tproxy-in' ], ip: PRIVATE_NETS, outboundTag: 'block' },
	{ inboundTag: [ 'tproxy-in', 'dns-internal' ], balancerTag: 'tunnel' }
]);
ok('xray/ssh: the check never goes through the balancer',
	rule_index(rules, (r) => index(r.inboundTag, 'check-in') >= 0 && r.balancerTag != null) < 0);

// Xray mode, fallback to direct, IPv6 diverted, user IP rules behind the server
let user_rules = [
	{ sid: 'r_000000000001', type: 'ip', value: '10.8.0.0/16', enabled: true, family: 4 },
	{ sid: 'r_000000000002', type: 'ip', value: '8.8.8.0/24', enabled: true, family: 4 },
	{ sid: 'r_000000000003', type: 'ip', value: 'fd00:1::/64', enabled: true, family: 6 },
	{ sid: 'r_000000000004', type: 'ip', value: '192.168.50.0/24', enabled: false, family: 4 },
	{ sid: 'r_000000000005', type: 'domain', value: 'example.org', enabled: true }
];
let x = render(model({ transport: 'xray', kill_switch: false, ipv6: true, log_level: 'error' }, user_rules),
	{ outbound: OUTBOUND, vision: true });

ok('xray/xray: renders', x.ok, x.error);
c = x.config;
xray_test('xray', c);

let proxy = by_tag(c.outbounds, 'proxy');

eq('xray/xray: outbound from links, marked', proxy.streamSettings.sockopt, { mark: MARK_XRAY });
eq('xray/xray: outbound keeps its settings', proxy.settings, OUTBOUND.settings);
ok('xray/xray: the links object is not modified', OUTBOUND.streamSettings.sockopt == null);
eq('xray/xray: balancer falls back to direct', c.routing.balancers[0].fallbackTag, 'direct');
eq('xray/xray: both tproxy inbounds with ipv6=1', map(c.inbounds, (i) => [ i.tag, i.listen ]),
	[ [ 'tproxy-in', '127.0.0.1' ], [ 'tproxy6-in', '::1' ], [ 'dns-in', '127.0.0.1' ], [ 'check-in', '127.0.0.1' ] ]);
eq('xray/xray: DoH answers both families', c.dns.queryStrategy, 'UseIP');
ok('xray/xray: the stale DNS cache stays bounded (serveExpiredTTL 0 never cleans it)',
	c.dns.serveStale === true && c.dns.serveExpiredTTL > 0);
eq('xray/xray: log level follows log_level', c.log.loglevel, 'error');
eq('xray/xray: Shadow debug keeps xray at info (its debug logs every connection)',
	render(model({ transport: 'xray', log_level: 'debug' }, user_rules), { outbound: OUTBOUND, vision: true }).config?.log?.loglevel,
	'info');

rules = c.routing.rules;

ok('xray/xray: no UDP block in Xray mode', rule_index(rules, (r) => r.network == 'udp') < 0);

let allow = rule_index(rules, (r) => r.ip != null && r.balancerTag == 'tunnel');
let block = rule_index(rules, (r) => r.ip != null && r.outboundTag == 'block');

ok('xray/xray: private user IPs allowed before the private block', allow >= 0 && allow < block, sprintf('%J', rules));
eq('xray/xray: only enabled rules inside private ranges', rules[allow].ip, [ '10.8.0.0/16', 'fd00:1::/64' ]);
eq('xray/xray: tunnel rule covers both tproxy inbounds and xray DNS', rules[length(rules) - 1],
	{ inboundTag: [ 'tproxy-in', 'tproxy6-in', 'dns-internal' ], balancerTag: 'tunnel' });

// hysteria-style outbound that already has sockopt keeps it and gains the mark
let hy = render(model({ transport: 'xray' }), { outbound: {
	tag: 'x', protocol: 'hysteria', settings: { version: 2, address: '203.0.113.20', port: 8444 },
	streamSettings: { network: 'hysteria', hysteriaSettings: { version: 2, auth: 'fake-hy2-auth' }, security: 'tls',
		tlsSettings: { serverName: 'vpn.example', alpn: [ 'h3' ] }, sockopt: { tcpFastOpen: false } } } });

ok('xray/hysteria: renders', hy.ok, hy.error);
eq('xray/hysteria: sockopt merged', by_tag(hy.config.outbounds, 'proxy').streamSettings.sockopt, { tcpFastOpen: false, mark: MARK_XRAY });
xray_test('hysteria', hy.config);

let none = render(model({ transport: 'xray' }), {});

ok('xray/xray: no outbound is an error, not a config', none.ok === false && type(none.error) == 'string');

done();
