'use strict';

import { cursor } from 'uci';
import { load, selected, targets, dnsmasq_instance } from 'shadow-vpn.config';
import { ok, eq, done, HERE } from 'rt';

const U = `${HERE}/uci`;

function errors_for(model, section, option) {
	return filter(model.errors, (e) => e.section == section && (option == null || e.option == option));
}

// good: every option of DESIGN.md 5 set away from its default
let m = load(cursor(`${U}/good`));

eq('config/good: main', m.main, {
	enabled: true, autostart: false, transport: 'xray', ssh_server: 's_0123456789ab', xray_profile: 'p_0123456789ab',
	mode: 'selected-rules', kill_switch: false, check_endpoint: 'example.com:8443', check_after_connect: false,
	ssh_udp: 'direct', tunnel_dns: false, ipv6: true, dns_redirect: false, router_traffic: false,
	lists_refresh: 12, log_level: 'info', update: 'auto'
});
eq('config/good: lists', m.lists, { proxy: { enabled: true }, direct: { enabled: false } });
eq('config/good: no errors', m.errors, []);
eq('config/good: server', m.servers[0], {
	sid: 's_0123456789ab', note: 'office', host: 'vpn.example.com', username: 'alice', port: 2222,
	fingerprint: 'SHA256:iiz2FAGUCt5ARI+B19jscb1conLj0qI+FMUYP3I1LXY', keepalive: 30, name: 'Home server',
	auth: 'key', key: 'k_0123456789ab'
});
eq('config/good: key', m.keys, [ { sid: 'k_0123456789ab', name: 'laptop', type: 'ed25519', format: 'openssh', encrypted: true } ]);

let p = m.profiles[0];

ok('config/good: profile', p && p.sid == 'p_0123456789ab' && p.protocol == 'vless' && p.port == 443 && p.pinned === true &&
	p.supported === true && p.created == 1761000000 && p.updated == 1761000100 && p.flow == 'xtls-rprx-vision',
	sprintf('%J', p));
eq('config/good: rule types', map(m.rules, (r) => [ r.sid, r.type, r.enabled ]),
	[ [ 'r_000000000001', 'domain', true ], [ 'r_000000000002', 'ip', true ], [ 'r_000000000003', 'device', false ] ]);
eq('config/good: domain rule normalized', m.rules[0].value, 'example.org');
eq('config/good: ip rule family', m.rules[1].family, 4);
eq('config/good: selected is the profile', selected(m)?.sid, 'p_0123456789ab');
ok('config/good: split mode with the proxy list has targets', targets(m));

m.lists.proxy.enabled = false;
ok('config/good: enabled rules are targets too', targets(m));

m.rules = filter(m.rules, (r) => !r.enabled);
ok('config/good: nothing enabled means nothing to route', !targets(m));

m.main.mode = 'proxy-all';
ok('config/good: proxy-all always has targets', targets(m));

m.main.transport = 'ssh';
eq('config/good: selected is the server in ssh mode', selected(m)?.sid, 's_0123456789ab');

// bad: invalid values are dropped and reported, never thrown
let b = load(cursor(`${U}/bad`));

eq('config/bad: main falls back to defaults', b.main, {
	enabled: false, autostart: true, transport: 'ssh', ssh_server: null, xray_profile: null, mode: 'proxy-all',
	kill_switch: true, check_endpoint: 'youtube.com:443', check_after_connect: true, ssh_udp: 'reject',
	tunnel_dns: true, ipv6: false, dns_redirect: true, router_traffic: true, lists_refresh: 24, log_level: 'warning',
	update: 'notify'
});

for (let opt in [ 'enabled', 'transport', 'mode', 'kill_switch', 'lists_refresh', 'check_endpoint', 'ssh_server', 'log_level',
	'update' ])
	ok(`config/bad: main.${opt} reported`, length(errors_for(b, 'main', opt)) == 1, sprintf('%J', errors_for(b, 'main', null)));

eq('config/bad: only the server with a bad keepalive survives', map(b.servers, (s) => [ s.sid, s.keepalive ]),
	[ [ 's_00000000000c', 15 ] ]);
ok('config/bad: bad host reported', length(errors_for(b, 's_00000000000a', 'host')) == 1);
ok('config/bad: malformed pin drops the server', length(errors_for(b, 's_00000000000b', 'fingerprint')) == 1);
ok('config/bad: keepalive reported', length(errors_for(b, 's_00000000000c', 'keepalive')) == 1);
ok('config/bad: missing key reported', length(errors_for(b, 's_00000000000d', 'key')) == 1);
ok('config/bad: port out of range reported', length(errors_for(b, 's_00000000000e', 'port')) == 1);
ok('config/bad: anonymous server section reported',
	length(filter(b.errors, (e) => match(e.section ?? '', /^cfg/) && e.option == null)) == 1, sprintf('%J', b.errors));
eq('config/bad: unsupported profile dropped', b.profiles, []);
ok('config/bad: profile protocol reported', length(errors_for(b, 'p_00000000000a', 'protocol')) == 1);
eq('config/bad: invalid rules dropped', b.rules, []);
ok('config/bad: rule type reported', length(errors_for(b, 'r_00000000000a', 'type')) == 1);
ok('config/bad: ip rule reported', length(errors_for(b, 'r_00000000000b', 'value')) == 1);
ok('config/bad: domain rule reported', length(errors_for(b, 'r_00000000000c', 'value')) == 1);
eq('config/bad: no selection', selected(b), null);
ok('config/bad: every error has a message', length(filter(b.errors, (e) => type(e.message) != 'string' || e.message == '')) == 0);

// keys: an encrypted PKCS#8 key hides its algorithm ('unknown') and is kept; other unknown types are not
let k = load(cursor(`${U}/keys`));

eq('config/keys: only the encrypted PKCS#8 key of unknown type survives', k.keys,
	[ { sid: 'k_00000000000a', name: 'encrypted pkcs8', type: 'unknown', format: 'pkcs8', encrypted: true } ]);
eq('config/keys: the others are reported as unsupported types',
	map(filter(k.errors, (e) => e.option == 'type'), (e) => e.section), [ 'k_00000000000b', 'k_00000000000c', 'k_00000000000d' ]);

// empty file: the defaults of DESIGN.md 5
let e = load(cursor(`${U}/empty`));

eq('config/empty: defaults', [ e.main.enabled, e.main.autostart, e.main.kill_switch, e.main.mode, e.main.tunnel_dns,
	e.main.ipv6, e.main.dns_redirect, e.main.router_traffic, e.main.lists_refresh, e.main.log_level, e.main.check_endpoint,
	e.main.ssh_udp, e.main.update ],
	[ false, true, true, 'proxy-all', true, false, true, true, 24, 'warning', 'youtube.com:443', 'reject', 'notify' ]);
eq('config/empty: no errors', e.errors, []);

// the dnsmasq instance serving the LAN and its confdir
let d = dnsmasq_instance(cursor(`${U}/dhcp-default`));

ok('config/dnsmasq: anonymous default instance', d && match(d.name, /^cfg[0-9a-f]+$/) && d.confdir == `/tmp/dnsmasq.${d.name}.d`,
	sprintf('%J', d));
eq('config/dnsmasq: explicit confdir, guest-only instance skipped', dnsmasq_instance(cursor(`${U}/dhcp-confdir`)),
	{ name: 'main', confdir: '/tmp/custom.d' });

done();
