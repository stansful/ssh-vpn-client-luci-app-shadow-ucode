'use strict';

import { access, readfile, writefile, unlink, lsdir, stat, mkdir, rmdir } from 'fs';
import { cursor } from 'uci';
import { write, remove } from 'shadow-vpn.secrets';
import { ok, eq, run, done, HERE, UCODE, LIBEXEC } from 'rt';

const APPLY = `${UCODE} ${LIBEXEC}/apply`;
const LINK = 'vless://772e13a3-c056-46fb-a72a-27e02c860cd6@203.0.113.20:443?type=tcp&security=reality' +
	'&pbk=uoa3YWTsfWaK12FGB7IpsfJM7SZqDL0j-DPrdlvegMk&fp=chrome&sni=web.example&sid=8da5a403f24009e8' +
	'&flow=xtls-rprx-vision&encryption=none#rt-reality';

if (access('/etc/shadow-vpn')) {
	print('ok apply/render # skipped: /etc/shadow-vpn already exists\n');
	done();
}

// fake secrets in the throwaway container
write('s_0000000000a1', 'password', 'fake-test-password');
write('p_0000000000a1', 'link', LINK);

const RUN = '/var/run/shadow-vpn';

function render(name, cfg) {
	let dir = `/tmp/rt-render-${name}`;

	run(`rm -rf ${dir}`);

	let r = run(`${APPLY} render ${dir} --config ${HERE}/uci/render-${cfg ?? name}`);
	let res = null;

	try {
		res = json(r.out);
	}
	catch (e) { }

	ok(`apply/render ${name}: succeeds`, r.rc == 0 && res?.ok, r.out);

	return { dir, res: res ?? {} };
}

function files_of(dir) {
	return sort(lsdir(dir) ?? []);
}

function checks(name, dir) {
	let x = run(`xray run -test -c ${dir}/xray.json`);

	ok(`apply/render ${name}: xray accepts xray.json`, x.rc == 0, x.out);

	for (let v in [ 'table.open.nft', 'table.accept.nft' ]) {
		let n = run(`nft -c -f ${dir}/${v}`);

		ok(`apply/render ${name}: nft -c accepts ${v}`, n.rc == 0, n.out);
	}

	for (let v in [ 'dnsmasq.conf', 'dnsmasq.down.conf' ]) {
		let d = run(`dnsmasq --test -C ${dir}/${v}`);

		ok(`apply/render ${name}: dnsmasq --test accepts ${v}`, d.rc == 0, d.out);
	}

	ok(`apply/render ${name}: no servers-file in the dnsmasq confs`,
		index((readfile(`${dir}/dnsmasq.conf`) ?? '') + (readfile(`${dir}/dnsmasq.down.conf`) ?? ''), 'servers-file') < 0);

	let modes = map(files_of(dir), (f) => [ f, (stat(`${dir}/${f}`)?.mode ?? 0) & 0o777 ]);

	eq(`apply/render ${name}: every file is 0600`, filter(modes, (m) => m[1] != 0o600), []);
	ok(`apply/render ${name}: no secret in the non-secret files`,
		length(filter(files_of(dir), (f) => f != 'xray.json' && index(readfile(`${dir}/${f}`) ?? '', 'fake-test-password') >= 0)) == 0);
}

// SSH mode, proxy-all, kill switch
let s = render('ssh');

eq('apply/render ssh: files', files_of(s.dir), [
	'dnsmasq', 'dnsmasq.conf', 'dnsmasq.down.conf', 'fallback', 'lan_state', 'patterns', 'pin.s_0000000000a1',
	'ssh.files', 'ssh.s_0000000000a1.params', 'ssh.sid', 'table.accept.nft', 'table.nft', 'table.open.nft', 'transport',
	'wan_dns', 'wan_networks', 'xray.json'
]);
checks('ssh', s.dir);

let sx = json(readfile(`${s.dir}/xray.json`));

eq('apply/render ssh: proxy is the ssh socks', filter(sx.outbounds, (o) => o.tag == 'proxy')[0]?.settings, { address: '127.0.0.1', port: 12346 });
eq('apply/render ssh: kill switch', trim(readfile(`${s.dir}/fallback`)), 'block');
eq('apply/render ssh: transport', trim(readfile(`${s.dir}/transport`)), 'ssh');
eq('apply/render ssh: pin rendered from UCI', trim(readfile(`${s.dir}/pin.s_0000000000a1`)), 'SHA256:rf4RpEA8ny11z3M9Q7BhLw8wItqLCTIC54xVHNqDmQo');
eq('apply/render ssh: procd watches the password file', trim(readfile(`${s.dir}/ssh.files`)), '/etc/shadow-vpn/secrets/s_0000000000a1.password');
ok('apply/render ssh: server address stays direct', index(readfile(`${s.dir}/table.open.nft`), '203.0.113.20') >= 0);
ok('apply/render ssh: closed gate variant is current', readfile(`${s.dir}/table.nft`) == readfile(`${s.dir}/table.open.nft`));
ok('apply/render ssh: the accept variant differs only by the gate', readfile(`${s.dir}/table.accept.nft`) != readfile(`${s.dir}/table.open.nft`));
ok('apply/render ssh: private user IP allowed in xray', length(filter(sx.routing.rules, (r) => r.balancerTag == 'tunnel' && r.ip != null &&
	index(r.ip, '10.8.0.0/16') >= 0)) == 1);

// ssh is connected to another address of the server: the render keeps exactly that one direct
if (!access(RUN)) {
	mkdir('/var/run', 0o755);
	mkdir(RUN, 0o700);
	writefile(`${RUN}/ssh.s_0000000000a1.addr`, '198.51.100.7\n');

	let a = render('ssh-addr', 'ssh');
	let table = readfile(`${a.dir}/table.open.nft`) ?? '';

	ok('apply/render ssh-addr: the address ssh uses is in @server4', index(table, 'server4 { 198.51.100.7 }') >= 0, table);
	ok('apply/render ssh-addr: no other server address', index(table, '203.0.113.20') < 0);

	unlink(`${RUN}/ssh.s_0000000000a1.addr`);
	rmdir(RUN);
	run(`rm -rf ${a.dir}`);
}

// Xray mode, split, fallback to direct, IPv6, plain Vision
let x = render('xray');

eq('apply/render xray: files', files_of(x.dir), [
	'dnsmasq', 'dnsmasq.conf', 'dnsmasq.down.conf', 'fallback', 'lan_state', 'patterns', 'table.accept.nft', 'table.nft',
	'table.open.nft', 'transport', 'wan_dns', 'wan_networks', 'xray.json'
]);
eq('apply/render xray: the wan zone networks for the iface hook',
	readfile(`${x.dir}/wan_networks`), 'wan\nwan6\n');
checks('xray', x.dir);

let xx = json(readfile(`${x.dir}/xray.json`));
let proxy = filter(xx.outbounds, (o) => o.tag == 'proxy')[0];

eq('apply/render xray: outbound from the link', [ proxy?.protocol, proxy?.settings?.vnext?.[0]?.address ], [ 'vless', '203.0.113.20' ]);
eq('apply/render xray: outbound marked', proxy?.streamSettings?.sockopt?.mark, 0x00800000);
eq('apply/render xray: fallback', trim(readfile(`${x.dir}/fallback`)), 'direct');
eq('apply/render xray: balancer fallback', xx.routing.balancers[0].fallbackTag, 'direct');
ok('apply/render xray: plain Vision rejects QUIC in nft', match(readfile(`${x.dir}/table.open.nft`), /udp dport 443 reject/) != null);
ok('apply/render xray: user domain in the patterns', index(json(readfile(`${x.dir}/patterns`)).user, 'example.net') >= 0);
ok('apply/render xray: tunnel DNS lines in the conf', index(readfile(`${x.dir}/dnsmasq.conf`), 'server=/example.net/127.0.0.1#5300') >= 0);
ok('apply/render xray: the fallback conf resolves them through the normal upstream',
	index(readfile(`${x.dir}/dnsmasq.down.conf`), '127.0.0.1#5300') < 0);

// the instance has its own servers-file and max-ttl: ours never names a servers-file, and leaves max-ttl out
let c = cursor(), sec = null;

c.foreach('dhcp', 'dnsmasq', (s) => { sec ??= s['.name']; });

if (sec) {
	c.set('dhcp', sec, 'serversfile', '/tmp/rt-adblock.servers');
	c.set('dhcp', sec, 'max_ttl', '60');
	c.commit('dhcp');

	let i = render('xray-own', 'xray');
	let conf = readfile(`${i.dir}/dnsmasq.conf`) ?? '';

	checks('xray-own', i.dir);
	ok('apply/render xray-own: no servers-file of ours', index(conf, 'servers-file=') < 0, conf);
	ok('apply/render xray-own: no max-ttl of ours', index(conf, 'max-ttl') < 0, conf);
	ok('apply/render xray-own: tunnel DNS lines in the conf', index(conf, 'server=/example.net/127.0.0.1#5300') >= 0, conf);

	c = cursor();
	c.delete('dhcp', sec, 'serversfile');
	c.delete('dhcp', sec, 'max_ttl');
	c.commit('dhcp');
	run(`rm -rf ${i.dir}`);
}

// a missing secret is an error, not a half-rendered directory
remove('p_0000000000a1');

let missing = run(`${APPLY} render /tmp/rt-render-missing --config ${HERE}/uci/render-xray`);
let mres = json(missing.out);

ok('apply/render: missing link reported', missing.rc == 1 && mres.ok === false && mres.code == 'xray_config', missing.out);

remove('s_0000000000a1');
run('rm -rf /tmp/rt-render-ssh /tmp/rt-render-xray /tmp/rt-render-missing /etc/shadow-vpn');

done();
