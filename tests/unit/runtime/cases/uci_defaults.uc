'use strict';

import { access, readfile, writefile, unlink, stat } from 'fs';
import { cursor } from 'uci';
import { load } from 'shadow-vpn.config';
import { ok, eq, run, done } from 'rt';

const SCRIPT = '/src/shadow-vpn/files/etc/uci-defaults/80-shadow-vpn';

if (access('/etc/config/shadow-vpn') || access('/etc/shadow-vpn')) {
	print('ok uci_defaults # skipped: shadow-vpn config already present\n');
	done();
}

let firewall = readfile('/etc/config/firewall');
let r = run(`sh ${SCRIPT}`);

ok('uci_defaults: exits 0', r.rc == 0, r.out);

let m = load(cursor());

eq('uci_defaults: the defaults of DESIGN.md 5', m.main, {
	enabled: false, autostart: true, transport: 'ssh', ssh_server: null, xray_profile: null, mode: 'proxy-all',
	kill_switch: true, check_endpoint: 'youtube.com:443', check_after_connect: true, ssh_udp: 'reject',
	tunnel_dns: true, ipv6: false, dns_redirect: true, router_traffic: true, lists_refresh: 24, log_level: 'warning',
	update: 'notify'
});
eq('uci_defaults: both lists, off', m.lists, { proxy: { enabled: false }, direct: { enabled: false } });
eq('uci_defaults: config has no errors', m.errors, []);

let inc = cursor().get_all('firewall', 'shadow_vpn');

eq('uci_defaults: fw4 script include', [ inc?.['.type'], inc?.type, inc?.path, inc?.fw4_compatible ],
	[ 'include', 'script', '/usr/libexec/shadow-vpn/fw4-hook', '1' ]);
eq('uci_defaults: /etc/shadow-vpn is 0700', (stat('/etc/shadow-vpn')?.mode ?? 0) & 0o777, 0o700);

// a user setting survives a second run (upgrade)
let c = cursor();

c.set('shadow-vpn', 'main', 'kill_switch', '0');
c.commit('shadow-vpn');
run(`sh ${SCRIPT}`);
eq('uci_defaults: an upgrade keeps user settings', cursor().get('shadow-vpn', 'main', 'kill_switch'), '0');
eq('uci_defaults: one include only', length(filter(split(readfile('/etc/config/firewall'), '\n'), (l) => index(l, 'fw4-hook') >= 0)), 1);

unlink('/etc/config/shadow-vpn');
run('rm -rf /etc/shadow-vpn');

if (firewall != null)
	writefile('/etc/config/firewall', firewall);

done();
