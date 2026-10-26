'use strict';

// Started by tests/unit/routing_test.uc with the package tree root as ARGV[0].

import * as fs from 'fs';
import * as validate from 'shadow-vpn.validate';
import * as lists from 'shadow-vpn.lists';
import * as routing from 'shadow-vpn.routing';

const ROOT = ARGV[0];
const SRC = `${ROOT}/shadow-vpn/files/usr/share/ucode`;
const FIX = `${ROOT}/tests/unit/routing`;
const CLI = `${ROOT}/shadow-vpn/files/usr/libexec/shadow-vpn/lists`;
const TMP = '/tmp/shv-routing';
const CLI_TMP = '/tmp/shv-routing-cli';
const WWW = `${TMP}/www`;
const HTTP_PORT = 18781;
const T = 'inet shadow_vpn';

let failures = 0;

// ---- helpers --------------------------------------------------------------------------------------

function canon(v) {
	if (type(v) == 'array')
		return map(v, canon);

	if (type(v) == 'object') {
		let o = {};

		for (let k in sort(keys(v)))
			o[k] = canon(v[k]);

		return o;
	}

	return v;
}

function report(name, pass, why) {
	if (pass) {
		print(`ok ${name}\n`);
	}
	else {
		failures++;
		print(`not ok ${name}: ${why ?? 'assertion failed'}\n`);
	}
}

function eq(name, got, want) {
	let g = sprintf('%J', canon(got)), w = sprintf('%J', canon(want));

	report(name, g == w, `got ${g}, want ${w}`);
}

function contains(name, text, needle, want) {
	let has = index(text ?? '', needle) >= 0;

	report(name, has == (want ?? true), `${(want ?? true) ? 'missing' : 'unexpected'} ${sprintf('%J', needle)}`);
}

function sh(cmd) {
	let p = fs.popen(`${cmd} 2>&1`, 'r');
	let out = p.read('all');

	return { rc: p.close(), out };
}

// s repeated n times, by doubling (2 MiB test bodies stay cheap).
function rep(s, n) {
	let out = '';

	for (let part = s; n > 0; n >>= 1, part += part)
		if (n & 1)
			out += part;

	return out;
}

function parse_json(text) {
	try {
		return json(text);
	}
	catch (e) {
		return null;
	}
}

function write(path, text) {
	fs.writefile(path, text);

	return path;
}

function lines_of(text) {
	return filter(split(text ?? '', '\n'), (l) => l != '');
}

// ---- validate.uc: desktop tests/validation.test.ts and ipc-validation ------------------------------

function test_validate() {
	eq('domain_rule accepts exact and wildcard patterns',
		[ validate.domain_rule('youtube.com'), validate.domain_rule('*.googlevideo.com'), validate.domain_rule(' YouTube.COM ') ],
		[ { value: 'youtube.com', wildcard: false }, { value: 'googlevideo.com', wildcard: true }, { value: 'youtube.com', wildcard: false } ]);

	for (let c in [
		[ '', 'Domain pattern is required.' ],
		[ '   ', 'Domain pattern is required.' ],
		[ 'localhost', 'Domain pattern must include at least two labels.' ],
		[ '*.localhost', 'Domain pattern must include at least two labels.' ],
		[ '-bad.example.com', 'Domain labels may contain letters, numbers, and internal hyphens.' ],
		[ 'bad..example.com', 'Domain labels may contain letters, numbers, and internal hyphens.' ],
		[ 'bad_label.example.com', 'Domain labels may contain letters, numbers, and internal hyphens.' ],
		[ rep('a', 250) + '.com', 'Domain pattern is too long.' ]
	])
		eq(`domain_rule rejects ${sprintf('%J', substr(c[0], 0, 24))}`, validate.domain_rule(c[0]), { error: c[1] });

	eq('domain_rule: a label may have 63 characters, not 64',
		[ validate.domain_rule(rep('a', 63) + '.com').value != null, validate.domain_rule(rep('a', 64) + '.com'),
		  lists.normalize_domain(rep('b', 63) + '.com') != null, lists.normalize_domain(rep('b', 64) + '.com') ],
		[ true, { error: 'Domain labels may contain letters, numbers, and internal hyphens.' }, true, null ]);

	for (let v in [ '8.8.8.8', '142.250.0.0/15', '2a00:1450::/32', '0.0.0.0/0', '10.0.0.0/8', '10.0.0.0/10', '::/0', '2001:db8::/100' ])
		report(`ip_rule accepts ${v}`, validate.ip_rule(v).cidr != null, sprintf('%J', validate.ip_rule(v)));

	for (let c in [
		[ '', 'IP address or CIDR is required.' ],
		[ '1.2.3.4/8/9', 'CIDR may contain only one slash.' ],
		[ '999.1.1.1', 'IP address must be valid IPv4 or IPv6.' ],
		[ '01.2.3.4', 'IP address must be valid IPv4 or IPv6.' ],
		[ '::ffff:1.2.3.4', 'IP address must be valid IPv4 or IPv6.' ],
		[ 'fe80::1%eth0', 'IP address must be valid IPv4 or IPv6.' ],
		[ '1::2::3', 'IP address must be valid IPv4 or IPv6.' ],
		[ '1:2:3:4:5:6:7:8:9', 'IP address must be valid IPv4 or IPv6.' ],
		[ '1.2.3.4/x', 'CIDR prefix must be a number.' ],
		[ '1.1.1.1/33', 'CIDR prefix must be between 0 and 32.' ],
		[ '2a00:1450::/129', 'CIDR prefix must be between 0 and 128.' ],
		[ '10.0.0.0/08', 'CIDR prefix must not have leading zeros.' ],
		[ '10.0.0.0/00', 'CIDR prefix must not have leading zeros.' ],
		[ '1.1.1.1/032', 'CIDR prefix must not have leading zeros.' ],
		[ '2001:db8::/032', 'CIDR prefix must not have leading zeros.' ],
		[ '2001:db8::/0064', 'CIDR prefix must not have leading zeros.' ]
	])
		eq(`ip_rule rejects ${c[0] || 'empty'}`, validate.ip_rule(c[0]), { error: c[1] });

	eq('ip_rule gives the network with host bits cleared, IPv6 compressed',
		map([ '10.1.2.3/8', '2001:DB8:0:0:1::1/64', '2001:db8:0:0:0:0:0:1', '2001:db8:1::/127', '0.0.0.0/0', '8.8.8.8' ],
			(v) => [ validate.ip_rule(v).family, validate.ip_rule(v).cidr ]),
		[ [ 4, '10.0.0.0/8' ], [ 6, '2001:db8::/64' ], [ 6, '2001:db8::1' ], [ 6, '2001:db8:1::/127' ], [ 4, '0.0.0.0/0' ], [ 4, '8.8.8.8' ] ]);

	eq('canonical_ip_rule rewrites a zero-padded prefix of an earlier version',
		map([ '10.0.0.0/08', '2001:db8::/032', '10.0.0.0/8', 'x' ], validate.canonical_ip_rule),
		[ '10.0.0.0/8', '2001:db8::/32', '10.0.0.0/8', 'x' ]);

	eq('fingerprint accepts a SHA256 pin and empty (trust on first use)',
		[ validate.fingerprint(`SHA256:${rep('A', 43)}`), validate.fingerprint(' ') ],
		[ { value: `SHA256:${rep('A', 43)}` }, { value: '' } ]);
	eq('fingerprint rejects other formats', validate.fingerprint('sha256:not-a-pin'),
		{ error: 'SSH server fingerprint must use the OpenSSH SHA256:base64 format (43 characters after SHA256:).' });

	for (let v in [ 'youtube.com:443', ' youtube.com:443 ', 'db.example.org:5432', 'localhost:8080', '1.1.1.1:53',
	                '[2606:4700::1111]:443', '[::1]:80', 'пример.рф:443', 'example.com.:443' ])
		report(`endpoint accepts ${v}`, validate.endpoint(v).value == trim(v), sprintf('%J', validate.endpoint(v)));

	for (let v in [ 'https://youtube.com', 'https://youtube.com:443', 'tcp://youtube.com:443', 'youtube.com/watch',
	                'youtube.com:443/', '/youtube.com:443', 'user@youtube.com:443', 'youtube.com:443?x=1', 'youtube.com:443#top' ])
		eq(`endpoint asks for host:port instead of ${v}`, validate.endpoint(v), { error: validate.CHECK_ENDPOINT_FORMAT_MESSAGE });

	eq('endpoint format message', validate.CHECK_ENDPOINT_FORMAT_MESSAGE,
		'Enter host:port without https:// or a path — for example youtube.com:443.');
	eq('endpoint empty', validate.endpoint('  '), { error: 'Endpoint is required. Use host:port.' });

	for (let v in [ 'youtube.com', 'youtube.com:', 'youtube.com:0', 'youtube.com:65536', 'youtube.com:https', '[::1]' ])
		eq(`endpoint port message for ${v}`, validate.endpoint(v), { error: 'Endpoint must use host:port with a valid TCP port.' });

	for (let v in [ 'bad host:443', '-bad.example.com:443', 'bad..example.com:443', '999.1.1.1:443', '2001:db8::1:443',
	                '[zz]:443', ':443', 'a—b.example:443' ])
		eq(`endpoint host message for ${v}`, validate.endpoint(v), { error: 'Endpoint must use host:port, for example youtube.com:443.' });

	let device_error = 'Enter a MAC address (aa:bb:cc:dd:ee:ff), an IP address or a CIDR.';

	for (let c in [
		[ 'AA-BB-CC-DD-EE-FF', { value: 'aa:bb:cc:dd:ee:ff', kind: 'mac' } ],
		[ ' aa:bb:cc:dd:ee:01 ', { value: 'aa:bb:cc:dd:ee:01', kind: 'mac' } ],
		[ '192.168.1.50', { value: '192.168.1.50', kind: 'ip4' } ],
		[ '192.168.1.7/24', { value: '192.168.1.0/24', kind: 'ip4' } ],
		[ 'FD00::50/64', { value: 'fd00::/64', kind: 'ip6' } ],
		[ '', { error: 'MAC address, IP address or CIDR is required.' } ],
		[ '01:00:5e:00:00:01', { error: device_error } ],
		[ 'ff:ff:ff:ff:ff:ff', { error: device_error } ],
		[ '00:00:00:00:00:00', { error: device_error } ],
		[ 'aa:bb:cc:dd:ee', { error: device_error } ],
		[ 'printer', { error: device_error } ],
		[ '192.168.1.0/33', { error: 'CIDR prefix must be between 0 and 32.' } ],
		[ '192.168.1.0/08', { error: 'CIDR prefix must not have leading zeros.' } ]
	])
		eq(`device_rule ${c[0] || 'empty'}`, validate.device_rule(c[0]), c[1]);

	eq('port accepts 1..65535 as number or text', map([ 22, '8022', ' 65535 ' ], (v) => validate.port(v).value), [ 22, 8022, 65535 ]);

	for (let v in [ 0, 65536, '22a', '', null, -1 ])
		eq(`port rejects ${sprintf('%J', v)}`, validate.port(v), { error: 'Enter a port from 1 to 65535.' });

	eq('keepalive accepts 5..3600', map([ 5, '3600', '15' ], (v) => validate.keepalive(v).value), [ 5, 3600, 15 ]);

	for (let v in [ 4, 3601, '1.5', 'x' ])
		eq(`keepalive rejects ${v}`, validate.keepalive(v), { error: 'Keepalive must be a whole number of seconds from 5 to 3600.' });

	eq('server accepts a valid form, trimmed',
		validate.server({ name: ' Frankfurt ', host: ' 203.0.113.10 ', port: '22', username: 'root', auth: 'password',
		                  fingerprint: '', keepalive: '15', note: ' n ' }),
		{ values: { name: 'Frankfurt', host: '203.0.113.10', port: 22, username: 'root', auth: 'password', key: null,
		            fingerprint: '', keepalive: 15, note: 'n' } });

	eq('server keeps the key only for key sign-in',
		map([ 'key', 'password' ], (auth) => validate.server({ name: 'a', host: 'h', username: 'u', auth, key: 'k_0123456789ab' }).values?.key),
		[ 'k_0123456789ab', null ]);

	eq('server reports every field with the desktop messages',
		validate.server({ name: '', host: 'root@h', port: 0, username: 'a b', auth: 'agent', key: '../x', keepalive: 1 }),
		{ errors: {
			name: 'Name is required.',
			host: 'Enter only the server address in Host.',
			port: 'Enter a port from 1 to 65535.',
			username: 'Enter only the user name in Username.',
			keepalive: 'Keepalive must be a whole number of seconds from 5 to 3600.',
			auth: 'Sign-in method must be one of: password, key.',
			key: 'The selected SSH key no longer exists. Pick another key.'
		} });

	eq('server length limits count characters',
		[ validate.server({ name: rep('a', 257), host: rep('h', 256), username: rep('u', 257) }).errors,
		  validate.name(rep('я', 256)).value != null, validate.username(rep('я', 257)).error ],
		[ { name: 'Name is too long.', host: 'Host is too long.', username: 'Username is too long.' }, true, 'Username is too long.' ]);

	eq('dns_name normalizes names dnsmasq can carry',
		map([ ' Vpn.Example.ORG. ', '_sip._tcp.example.com', 'myvps', '1.2.3.4', 'a/b', 'a b', '' ], validate.dns_name),
		[ 'vpn.example.org', '_sip._tcp.example.com', 'myvps', null, null, null, null ]);
}

// ---- lists.uc --------------------------------------------------------------------------------------

function test_list_parse() {
	// desktop tests/network-proxy.test.ts "domain proxy list parser"
	eq('list parse: whitespace-separated inside-raw domains',
		lists.parse('.ua  gosuslugi.ru\n*.example.com https://ignored.test/path #comment'),
		{ domains: [ '.example.com', '.ua', 'gosuslugi.ru' ] });

	eq('list parse: rejects invalid label-wise domains',
		map([ 'aa..bb', 'aa.-bad.com', 'aa.bad-.com', 'localhost', '*example.com' ], lists.normalize_domain),
		[ null, null, null, null, null ]);

	eq('list parse: keeps dot-prefixed TLD suffixes',
		lists.parse('aa..bb aa.-bad.com localhost Valid.Example. .ru'), { domains: [ '.ru', 'valid.example' ] });

	eq('list parse: dedupes, lowercases, sorts bytewise',
		lists.parse('b.example\r\nA.example\tb.example. *.c.example .c.example\n# note x.example'),
		{ domains: [ '.c.example', 'a.example', 'b.example', 'x.example' ] });

	eq('list parse: drops names over 253 characters', lists.parse(`${rep('a.', 126)}com ok.example`), { domains: [ 'ok.example' ] });

	let names = [];

	for (let i = 0; i < 20000; i++)
		push(names, `host-${i}.example`);

	let at_limit = lists.parse(join('\n', names));

	report('list parse: 20000 entries are allowed', length(at_limit.domains ?? []) == 20000, at_limit.error);
	eq('list parse: more than 20000 entries fail', lists.parse(join('\n', names) + '\nextra.example'),
		{ error: 'Domain proxy list is larger than 20000 entries.' });
	eq('list parse: an empty result fails per kind', [ lists.parse('# only\n\n', 'proxy'), lists.parse('localhost', 'direct') ],
		[ { error: 'Routing proxy list refresh returned no domains.' }, { error: 'Routing direct list refresh returned no domains.' } ]);
}

function sha256_hex(text) {
	let path = write(`${TMP}/hash.in`, text);

	return substr(sh(`sha256sum ${path}`).out, 0, 64);
}

function test_list_store() {
	let dir = `${TMP}/lists`, run = `${TMP}/run`, opts = { dir, run };

	sh(`rm -rf ${dir} ${run}`);

	eq('list store: missing list loads empty', [ lists.load('proxy', opts), lists.info('proxy', opts) ], [ [], { count: 0, updated: null } ]);

	let domains = [ '.ua', 'gosuslugi.ru', 'youtube.com' ];
	let first = lists.store('proxy', domains, opts);
	let sum = fs.readfile(`${dir}/proxy.sha256`);
	let st = fs.stat(`${dir}/proxy.lst`);

	eq('list store: first store writes', first, { changed: true, count: 3 });
	eq('list store: round trip', lists.load('proxy', opts), domains);
	report('list store: files are 0600 and the hash is sha256sum format',
		st?.mode == 0o600 && fs.stat(`${dir}/proxy.sha256`)?.mode == 0o600 && match(sum, /^[0-9a-f]{64}  proxy\.lst\n$/),
		sprintf('%o %J', st?.mode, sum));
	report('list store: sha256sum -c accepts it', sh(`cd ${dir} && sha256sum -c proxy.sha256`).rc == 0, 'sha256sum -c failed');
	report('list store: no tmp files left', !fs.access(`${dir}/proxy.lst.tmp`) && !fs.access(`${dir}/proxy.sha256.tmp`), 'tmp left');

	let mtime = fs.stat(`${dir}/proxy.lst`).mtime;

	sh(`touch -t 200109090146.40 ${dir}/proxy.lst`);
	eq('list store: an unchanged list is not rewritten', lists.store('proxy', domains, opts), { changed: false, count: 3 });
	eq('list store: ...and keeps its mtime', fs.stat(`${dir}/proxy.lst`).mtime, 1000000000);

	let i = lists.info('proxy', opts);

	report('list info: count and the refresh stamp', i.count == 3 && i.updated >= mtime, sprintf('%J', i));

	fs.writefile(`${dir}/proxy.lst`, '.ua\ngosuslugi.ru\nevil.example\n');
	eq('list store: a list that does not match its hash loads empty',
		[ lists.load('proxy', opts), lists.info('proxy', opts).count ], [ [], 0 ]);
	eq('list store: the next store repairs it', [ lists.store('proxy', domains, opts).changed, lists.load('proxy', opts) ], [ true, domains ]);

	// a store cut off between the list rename and the hash rename
	let next = [ 'new.example' ];
	let body = 'new.example\n';

	fs.writefile(`${dir}/proxy.sha256.tmp`, `${sha256_hex(body)}  proxy.lst\n`);
	fs.writefile(`${dir}/proxy.lst`, body);
	eq('list store: an interrupted store is finished on load', lists.load('proxy', opts), next);
	report('list store: ...and its hash moved into place', fs.readfile(`${dir}/proxy.sha256`) == `${sha256_hex(body)}  proxy.lst\n`
		&& !fs.access(`${dir}/proxy.sha256.tmp`), 'hash not recovered');

	eq('list store: unknown kinds are refused', [ lists.store('../x', domains, opts).changed, lists.load('../x', opts) ], [ false, [] ]);
}

let httpd_pid = null;

function start_httpd() {
	sh(`mkdir -p ${WWW}`);
	write(`${WWW}/ok`, 'ok\n');

	httpd_pid = trim(sh(`uhttpd -f -p 127.0.0.1:${HTTP_PORT} -h ${WWW} >/dev/null 2>&1 & echo $!`).out);

	for (let i = 0; i < 20; i++) {
		if (sh(`uclient-fetch -q -O /dev/null http://127.0.0.1:${HTTP_PORT}/ok`).rc == 0)
			return true;

		sh('sleep 1');
	}

	return false;
}

function stop_httpd() {
	if (httpd_pid)
		sh(`kill ${httpd_pid}`);
}

function test_list_fetch() {
	let url = (path) => `http://127.0.0.1:${HTTP_PORT}/${path}`;
	let big = rep(rep('a', 1023) + '\n', 2048);

	write(`${WWW}/list.txt`, 'youtube.com\n.ua\n');
	write(`${WWW}/limit.txt`, big);
	write(`${WWW}/big.txt`, big + 'x');

	eq('list fetch: downloads the body', lists.fetch(url('list.txt')), { text: 'youtube.com\n.ua\n' });
	report('list fetch: exactly 2 MiB is allowed', length(lists.fetch(url('limit.txt')).text ?? '') == 2097152, 'limit download failed');
	eq('list fetch: more than 2 MiB fails without a tunnel retry', lists.fetch(url('big.txt')),
		{ error: 'Routing list is larger than the allowed limit.', retry: false });

	let missing = lists.fetch(url('missing.txt'));

	report('list fetch: an HTTP error fails and may retry through the tunnel',
		match(missing.error ?? '', /^Routing list download failed/) && missing.retry === true, sprintf('%J', missing));

	let refused = lists.fetch(`http://127.0.0.1:${HTTP_PORT + 1}/list.txt`);

	report('list fetch: a refused connection fails', match(refused.error ?? '', /^Routing list download failed/) && refused.retry, sprintf('%J', refused));
	eq('list fetch: a URL that is not plain is refused', lists.fetch("http://x/'; touch /tmp/pwned; '"),
		{ error: 'Routing list download failed: invalid URL.' });
}

// ---- routing.patterns ------------------------------------------------------------------------------

function model(mode, rules, opts) {
	let n = 0;

	return {
		main: {
			enabled: true, mode, transport: opts?.transport ?? 'xray', kill_switch: true,
			ipv6: opts?.ipv6 ?? false, router_traffic: opts?.router_traffic ?? true, dns_redirect: opts?.dns_redirect ?? true,
			tunnel_dns: opts?.tunnel_dns ?? true, ssh_udp: opts?.ssh_udp ?? 'reject', lists_refresh: 24
		},
		lists: { proxy: { enabled: opts?.proxy ?? true }, direct: { enabled: opts?.direct ?? true } },
		rules: map(rules ?? [], (r) => ({ sid: sprintf('r_%012x', n++), id: `id-${n}`, type: r[0], value: r[1], enabled: r[2] ?? true }))
	};
}

// The set dnsmasq would fill for a name: its longest matching pattern.
function set_for(p, name) {
	let kind_of = {};

	for (let kind in [ 'user', 'proxy', 'direct' ])
		for (let n in p[kind])
			kind_of[n] = kind;

	for (let n = name; n != null; n = (index(n, '.') >= 0) ? substr(n, index(n, '.') + 1) : null)
		if (exists(kind_of, n))
			return kind_of[n];

	return null;
}

function test_patterns() {
	let p = routing.patterns(model('selected-rules', [ [ 'domain', 'google.com' ] ]), { direct: [ 'mail.google.com' ] }, []);

	eq('patterns: a user rule beats the direct list', [ p.user, p.direct, set_for(p, 'x.mail.google.com') ],
		[ [ 'google.com', 'mail.google.com' ], [], 'user' ]);

	for (let mode in [ 'selected-rules', 'proxy-all' ]) {
		p = routing.patterns(model(mode), { proxy: [ 'youtube.com', 'shared.example' ], direct: [ 'youtube.com', 'shared.example' ] }, []);
		eq(`patterns: a domain in both lists stays direct (${mode})`, [ p.proxy, p.direct ], [ [], [ 'shared.example', 'youtube.com' ] ]);
	}

	p = routing.patterns(model('selected-rules'), { proxy: [ 'blocked.ru', 'example.net' ], direct: [ '.ru', 'cdn.example.net' ] }, []);
	eq('patterns: the direct list beats the proxy list for the same name',
		map([ 'www.blocked.ru', 'a.cdn.example.net', 'www.example.net', 'example.org' ], (n) => set_for(p, n)),
		[ 'direct', 'direct', 'proxy', null ]);

	p = routing.patterns(model('selected-rules', [ [ 'domain', '*.Example.com' ] ]), {}, []);
	eq('patterns: *.x is approximated as x (apex included)', [ p.user, set_for(p, 'example.com'), set_for(p, 'a.example.com') ],
		[ [ 'example.com' ], 'user', 'user' ]);

	p = routing.patterns(model('proxy-all', [ [ 'domain', 'example.org' ] ]), { proxy: [ 'vpn.example.net', 'example.net' ] },
		[ 'VPN.example.net.', '203.0.113.5', '[2001:db8::5]', 'vpn2.example.org', 'bad/host' ]);
	eq('patterns: server hosts are exempt and never land in a set',
		[ p.exempt, p.proxy, p.user, index(p.proxy, 'vpn.example.net') ],
		[ [ 'vpn.example.net', 'vpn2.example.org' ], [ 'example.net' ], [ 'example.org' ], -1 ]);

	// desktop tests/routing-policy.test.ts "the shared routing order"
	let rules = [ [ 'domain', 'mail.service.ru' ], [ 'domain', 'corp.local' ], [ 'ip', '10.0.0.0/8' ], [ 'device', 'aa:bb:cc:dd:ee:01' ] ];
	let names = [ 'mail.service.ru', 'wiki.corp.local', 'news.service.ru', 'cdn.blocked.example', 'example.com' ];

	for (let mode in [ 'selected-rules', 'proxy-all' ]) {
		p = routing.patterns(model(mode, rules), { proxy: [ '.ru', 'blocked.example' ], direct: [ '.ru' ] }, []);
		eq(`patterns: desktop routing order (${mode})`, map(names, (n) => set_for(p, n)), [ 'user', 'user', 'direct', 'proxy', null ]);
	}

	p = routing.patterns(model('selected-rules', [ [ 'domain', 'off.example', false ], [ 'domain', 'not-a-domain' ], [ 'ip', 'x.example' ] ],
		{ proxy: false }), { proxy: [ 'listed.example' ], direct: [ 'ru-service.example' ] }, []);
	eq('patterns: disabled lists and rules, invalid rules are left out', p,
		{ user: [], proxy: [], direct: [ 'ru-service.example' ], exempt: [] });

	p = routing.patterns(model('selected-rules'), { proxy: [ 'printer.local', '.ua', '.local' ] }, []);
	eq('patterns: local names stay direct, a TLD suffix is not local', [ p.direct, p.proxy ], [ [ 'local', 'printer.local' ], [ 'ua' ] ]);

	// apply passes the router's NTP server names along with the server hosts (a clock without a battery
	// must be set before TLS and VMess work, so they never wait for the tunnel)
	p = routing.patterns(model('proxy-all'), { proxy: [ 'ntp.org', '0.openwrt.pool.ntp.org' ] },
		[ 'vpn.example.net', '0.OpenWrt.pool.ntp.org', '1.openwrt.pool.ntp.org' ]);
	eq('patterns: NTP server names are exempt like the server hosts',
		[ p.exempt, p.proxy ], [ [ '0.openwrt.pool.ntp.org', '1.openwrt.pool.ntp.org', 'vpn.example.net' ], [ 'ntp.org' ] ]);
}

function test_changed_sets() {
	let old = { user: [ 'u.example' ], proxy: [ 'google.com', 'a.example' ], direct: [ 'd.example' ], exempt: [] };

	eq('changed_sets: nothing changed', routing.changed_sets(old, old), []);
	eq('changed_sets: additions keep the sets', routing.changed_sets(old, { ...old, proxy: [ ...old.proxy, 'b.example' ] }), []);
	eq('changed_sets: a removed pattern flushes its set', routing.changed_sets(old, { ...old, user: [] }), [ 'user4', 'user6' ]);
	eq('changed_sets: a moved pattern flushes the set it left',
		routing.changed_sets(old, { ...old, proxy: [ 'google.com' ], direct: [ 'a.example', 'd.example' ] }), [ 'proxy4', 'proxy6' ]);
	eq('changed_sets: a new pattern under another set flushes that set',
		routing.changed_sets(old, { ...old, direct: [ 'd.example', 'mail.google.com' ] }), [ 'proxy4', 'proxy6' ]);
	eq('changed_sets: first render', routing.changed_sets(null, old), []);

	// a flush empties the whole set, so every listed site would go direct until clients resolve again
	eq('changed_sets: a list refresh that drops a domain keeps the proxy set',
		routing.changed_sets(old, { ...old, proxy: [ 'google.com' ] }), []);
	eq('changed_sets: the proxy list turned off flushes it', routing.changed_sets(old, { ...old, proxy: [] }), [ 'proxy4', 'proxy6' ]);
	eq('changed_sets: a user rule under a listed domain keeps the proxy set (both divert)',
		routing.changed_sets(old, { ...old, user: [ 'u.example', 'music.google.com' ] }), []);
	eq('changed_sets: a listed name moving between user and proxy keeps both sets',
		[ routing.changed_sets(old, { ...old, user: [ 'u.example', 'a.example' ], proxy: [ 'google.com' ] }),
		  routing.changed_sets(old, { ...old, user: [], proxy: [ 'google.com', 'a.example', 'u.example' ] }) ], [ [], [] ]);
	eq('changed_sets: a removed direct name flushes the direct set', routing.changed_sets(old, { ...old, direct: [] }),
		[ 'direct4', 'direct6' ]);
	eq('changed_sets: a direct name moving into the tunnel flushes the direct set',
		routing.changed_sets(old, { ...old, proxy: [ ...old.proxy, 'd.example' ], direct: [] }), [ 'direct4', 'direct6' ]);
}

// ---- routing.render_nft ----------------------------------------------------------------------------

const RULES = [
	[ 'ip', '10.8.0.0/16' ], [ 'ip', '2001:db8:8::/48' ], [ 'ip', '10.8.1.0/24' ], [ 'ip', '999.1.1.1' ],
	[ 'device', '192.168.1.50' ], [ 'device', 'AA:BB:CC:DD:EE:01' ], [ 'device', 'fd00::50/64' ], [ 'device', 'zz' ],
	[ 'domain', 'google.com' ], [ 'ip', '192.0.2.0/24', false ]
];
const NFT_CTX = {
	server4: [ '203.0.113.10', '203.0.113.10', '2001:db8::10' ], server6: [ '2001:db8::10' ], lan_ifs: [ 'br-lan', 'br-guest', 'bad name;' ],
	dns_upstream4: [ '192.168.1.2', 'x' ], dns_upstream6: [ 'fd00::2' ], vision_udp443: false, gate: ''
};

function nft_variants() {
	let out = [];

	for (let mode in [ 'proxy-all', 'selected-rules' ])
	for (let transport in [ 'ssh', 'xray' ])
	for (let ipv6 in [ false, true ])
	for (let router_traffic in [ false, true ])
	for (let dns_redirect in [ false, true ])
	for (let gate in [ '', 'accept' ])
	for (let vision_udp443 in [ false, true ])
	for (let ssh_udp in [ 'reject', 'direct' ]) {
		let o = { mode, transport, ipv6, router_traffic, dns_redirect, gate, vision_udp443, ssh_udp };
		let m = model(mode, RULES, o);

		push(out, { o, text: routing.render_nft(m, { ...NFT_CTX, gate, vision_udp443 }) });
	}

	return out;
}

function check_variant_text(v) {
	let o = v.o, t = v.text, full = o.mode == 'proxy-all', ssh = o.transport == 'ssh';
	let udp_direct = ssh && full && o.ssh_udp == 'direct';
	let expect = [
		[ '\t\tgoto divert\n', full ],
		[ 'meta l4proto udp reject with icmpx port-unreachable', ssh && !udp_direct ],
		[ 'meta l4proto udp return', udp_direct ],
		[ `meta l4proto tcp meta mark set 0x00400000 accept`, udp_direct ],
		[ 'udp dport 443 reject with icmpx port-unreachable', !ssh && o.vision_udp443 ],
		[ 'meta nfproto ipv6 reject with icmpx admin-prohibited', !o.ipv6 ],
		[ 'tproxy ip6 to [::1]:12345', o.ipv6 ],
		[ 'ip daddr @fetch4 jump gate_out', true ],
		[ 'ip daddr @proxy4 jump gate_out', o.router_traffic ],
		[ 'ip daddr != @direct4 jump gate_out', full && o.router_traffic ],
		[ 'redirect to :53', o.dns_redirect ],
		[ `delete chain ${T} dns_hijack`, !o.dns_redirect ],
		[ '\tchain gate {\n\t\taccept\n\t}', o.gate == 'accept' ],
		[ '\t\tmeta l4proto != { tcp, udp } return\n', true ],
		[ '\t\tfib daddr type { local, broadcast, multicast } return\n\t\tip6 daddr ff00::/8 return\n\t\tth dport 53 return\n', true ],
		[ 'udp dport { 67, 68, 123 } return\n\t\tfib daddr type { local, broadcast, multicast } return\n', o.router_traffic ]
	];
	let wrong = [];

	for (let e in expect)
		if ((index(t, e[0]) >= 0) != e[1])
			push(wrong, `${e[1] ? 'missing' : 'unexpected'} ${sprintf('%J', e[0])}`);

	// ICMP and other non-TCP/UDP protocols never reach divert: the return comes before every goto divert
	let pre = substr(t, index(t, '\tchain prerouting {'));

	pre = substr(pre, 0, index(pre, '\n\t}'));

	if (index(pre, 'meta l4proto != { tcp, udp } return') > index(pre, 'goto divert'))
		push(wrong, 'a goto divert comes before the TCP/UDP-only return');

	// a rule as wide as 0.0.0.0/0 must never take DHCP, SSDP or mDNS from the router's own listeners
	if (index(pre, 'fib daddr type { local, broadcast, multicast } return') > index(pre, '@user4_net goto divert'))
		push(wrong, 'the user sets come before the broadcast and multicast return');

	return wrong;
}

function test_render_nft() {
	let variants = nft_variants();
	let unique = {}, wrong = [];

	for (let v in variants) {
		unique[v.text] = v.o;

		for (let w in check_variant_text(v))
			push(wrong, `${sprintf('%J', v.o)}: ${w}`);
	}

	report(`render_nft: every option shows in its ${length(variants)} variants`, !length(wrong), join('; ', slice(wrong, 0, 5)));

	let text = variants[0].text;

	eq('render_nft: static elements are validated, deduplicated and normalized', filter(lines_of(text), (l) => match(l, /^add element/)), [
		`add element ${T} local4 { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 240.0.0.0/4 }`,
		`add element ${T} local6 { ::/127, fc00::/7, fe80::/10, ff00::/8 }`,
		`add element ${T} server4 { 203.0.113.10 }`,
		`add element ${T} server6 { 2001:db8::10 }`,
		`add element ${T} user4_net { 10.8.0.0/16, 10.8.1.0/24 }`,
		`add element ${T} user6_net { 2001:db8:8::/48 }`,
		`add element ${T} dev4 { 192.168.1.50 }`,
		`add element ${T} dev6 { fd00::/64 }`,
		`add element ${T} dev_mac { aa:bb:cc:dd:ee:01 }`,
		`add element ${T} lan_if { "br-guest", "br-lan" }`,
		`add element ${T} dns_upstream4 { 192.168.1.2 }`,
		`add element ${T} dns_upstream6 { fd00::2 }`
	]);
	contains('render_nft: an empty lan_ifs falls back to br-lan', routing.render_nft(model('proxy-all'), { lan_ifs: [] }),
		`add element ${T} lan_if { "br-lan" }`);

	// the router's own LAN-side networks (a delegated prefix per segment) stay local in full mode
	let nets = routing.render_nft(model('proxy-all'), { local_nets: [ '2001:db8:1::1/64', '2001:db8:2::/64', '198.51.100.0/24', 'bad' ] });

	eq('render_nft: LAN-side networks join the local sets', filter(lines_of(nets), (l) => match(l, /^add element .* local[46] /)), [
		`add element ${T} local4 { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 198.51.100.0/24, 224.0.0.0/4, 240.0.0.0/4 }`,
		`add element ${T} local6 { 2001:db8:1::/64, 2001:db8:2::/64, ::/127, fc00::/7, fe80::/10, ff00::/8 }`
	]);

	sh(`rm -rf ${TMP}/nft && mkdir -p ${TMP}/nft`);
	sh(`nft delete table ${T}`);

	let files = [], n = 0;

	for (let t in unique)
		push(files, write(`${TMP}/nft/${n++}.nft`, t));

	let failed = filter(files, (f) => sh(`nft -c -f ${f}`).rc != 0);

	report(`render_nft: nft -c -f accepts all ${length(files)} distinct variants on a fresh system`, !length(failed),
		length(failed) ? `${failed[0]}: ${sh(`nft -c -f ${failed[0]}`).out}` : null);

	let recreate = write(`${TMP}/nft/recreate.nft`, routing.render_nft(model('proxy-all', RULES), { ...NFT_CTX, recreate: true }));

	report('render_nft: the recreate variant checks', sh(`nft -c -f ${recreate}`).rc == 0, sh(`nft -c -f ${recreate}`).out);

	// the same renders against a live table (the keep path: flush, refill, redefine)
	let live = sh(`nft -f ${files[length(files) - 1]}`);

	report('render_nft: a variant applies for real', live.rc == 0, live.out);
	failed = filter(files, (f) => sh(`nft -c -f ${f}`).rc != 0);
	report('render_nft: nft -c -f accepts every variant over a live table', !length(failed),
		length(failed) ? `${failed[0]}: ${sh(`nft -c -f ${failed[0]}`).out}` : null);
	sh(`nft delete table ${T}`);
}

// Elements of a set as strings ("a.b.c.d", "net/len"), from nft -j.
function set_elements(name) {
	let r = sh(`nft -j list set ${T} ${name}`);
	let doc = (r.rc == 0) ? parse_json(r.out) : null;
	let out = [];

	for (let item in doc?.nftables ?? []) {
		for (let e in item?.set?.elem ?? []) {
			let v = (type(e) == 'object' && e.elem) ? e.elem.val : e;

			if (type(v) == 'object' && v.prefix)
				v = `${v.prefix.addr}/${v.prefix.len}`;
			else if (type(v) == 'object' && v.range)
				v = `${v.range[0]}-${v.range[1]}`;

			push(out, v);
		}
	}

	return sort(out);
}

function apply(name, m, ctx) {
	let path = write(`${TMP}/nft/${replace(name, / /g, '-')}.nft`, routing.render_nft(m, ctx));
	let r = sh(`nft -f ${path}`);

	report(`apply: ${name} loads with nft -f`, r.rc == 0, r.out);

	return fs.readfile(path);
}

function test_apply() {
	sh(`mkdir -p ${TMP}/nft`);
	sh(`nft delete table ${T}`);

	let a_rules = [ [ 'ip', '10.8.0.0/16' ], [ 'device', '192.168.1.50' ], [ 'device', 'aa:bb:cc:dd:ee:01' ] ];
	let a = apply('first', model('proxy-all', a_rules, { transport: 'ssh' }), { ...NFT_CTX, gate: '' });

	sh(`nft add element ${T} proxy4 '{ 198.51.100.7 }'`);
	sh(`nft add element ${T} user4 '{ 198.51.100.8 }'`);
	sh(`nft add element ${T} server4 '{ 192.0.2.99 }'`);
	eq('apply: dnsmasq and static sets hold their elements',
		[ set_elements('proxy4'), set_elements('user4'), set_elements('dev4'), set_elements('user4_net'), set_elements('server4') ],
		[ [ '198.51.100.7' ], [ '198.51.100.8' ], [ '192.168.1.50' ], [ '10.8.0.0/16' ], [ '192.0.2.99', '203.0.113.10' ] ]);

	let b_rules = [ [ 'ip', '10.9.0.0/16' ], [ 'device', 'aa:bb:cc:dd:ee:01' ] ];
	let b_model = model('selected-rules', b_rules, { dns_redirect: false });
	let b = apply('changed', b_model, { ...NFT_CTX, gate: 'accept' });

	eq('apply: a changed render keeps the dnsmasq sets', [ set_elements('proxy4'), set_elements('user4') ],
		[ [ '198.51.100.7' ], [ '198.51.100.8' ] ]);
	eq('apply: ...while static sets lose removed elements and are refilled',
		[ set_elements('dev4'), set_elements('user4_net'), set_elements('dev_mac'), set_elements('server4'),
		  index(set_elements('local4'), '10.0.0.0/8') >= 0 ],
		[ [], [ '10.9.0.0/16' ], [ 'aa:bb:cc:dd:ee:01' ], [ '203.0.113.10' ], true ]);
	report('apply: the DNS redirect chain is gone', sh(`nft list chain ${T} dns_hijack`).rc != 0, 'dns_hijack still exists');
	contains('apply: the gate verdict is in place', sh(`nft list chain ${T} gate`).out, 'accept');
	report('apply: each chain holds only the new rules once',
		length(filter(lines_of(sh(`nft list chain ${T} prerouting`).out), (l) => match(l, /@server4 accept/))) == 1, 'duplicated rules');

	apply('same again', b_model, { ...NFT_CTX, gate: 'accept' });
	apply('back to the first', model('proxy-all', a_rules, { transport: 'ssh' }), { ...NFT_CTX, gate: '' });
	contains('apply: the DNS redirect chain comes back', sh(`nft list chain ${T} dns_hijack`).out, 'redirect to :53');

	let changed_defs = replace(b, 'set proxy4 { type ipv4_addr; }', 'set proxy4 { type ipv4_addr; flags interval; }');

	eq('nft_needs_recreate: only when a definition changed',
		[ routing.nft_needs_recreate(a, b), routing.nft_needs_recreate(null, b), routing.nft_needs_recreate(changed_defs, b) ],
		[ false, false, true ]);

	apply('recreate', b_model, { ...NFT_CTX, recreate: true });
	eq('apply: recreate starts the table afresh', [ set_elements('proxy4'), set_elements('user4_net') ], [ [], [ '10.9.0.0/16' ] ]);

	sh(`nft delete table ${T}`);
}

// ---- routing.render_dnsmasq ------------------------------------------------------------------------

const PATTERNS = { user: [ 'google.com', 'mail.google.com' ], proxy: [ 'ua', 'youtube.com' ], direct: [ 'ru', 'yandex.ru' ],
	exempt: [ 'vpn.example.org' ] };
const WAN = [ '8.8.8.8', '2001:4860:4860::8888', '192.168.1.2#5353', '127.0.0.1', '127.0.0.1#5300', 'bogus', '8.8.8.8' ];

function dns(mode, opts, ctx) {
	return routing.render_dnsmasq(model(mode, [], opts), { wan_dns: WAN, patterns: PATTERNS, ...(ctx ?? {}) });
}

// The upstreams dnsmasq uses for a name: those of the longest matching server=/domain/, else the
// default server= lines, else the resolv-file ('resolv').
function upstream_for(files, name) {
	let best = [], best_len = -1, defaults = [];

	for (let l in lines_of(files.conf)) {
		let m = match(l, /^server=\/(.*)\/([^\/]+)$/);

		if (!m) {
			let d = match(l, /^server=([^\/]+)$/);

			if (d) push(defaults, d[1]);
			continue;
		}

		for (let d in split(m[1], '/')) {
			if (name != d && substr(name, -length(d) - 1) != `.${d}`)
				continue;

			if (length(d) > best_len) {
				best = [];
				best_len = length(d);
			}

			if (length(d) == best_len)
				push(best, m[2]);
		}
	}

	return join(',', sort(length(best) ? best : length(defaults) ? defaults : [ 'resolv' ]));
}

function uniq_targets(conf) {
	let seen = {};

	for (let l in lines_of(conf)) {
		let m = match(l, /^server=\/.*\/([^\/]+)$/);

		if (m) seen[m[1]] = true;
	}

	return sort(keys(seen));
}

function test_render_dnsmasq() {
	let split_up = dns('selected-rules');

	contains('dnsmasq: exact nftset syntax', split_up.conf, 'nftset=/ua/youtube.com/4#inet#shadow_vpn#proxy4,6#inet#shadow_vpn#proxy6\n');
	contains('dnsmasq: a name under a pattern of the same set gets no line', split_up.conf,
		'nftset=/google.com/4#inet#shadow_vpn#user4,6#inet#shadow_vpn#user6\n');
	contains('dnsmasq: ...nor yandex.ru under ru', split_up.conf, 'nftset=/ru/4#inet#shadow_vpn#direct4,6#inet#shadow_vpn#direct6\n');
	eq('dnsmasq split: conf header lines', slice(lines_of(split_up.conf), 0, 2),
		[ '# Generated by shadow-vpn. Do not edit.', 'max-ttl=300' ]);
	contains('dnsmasq: no servers-file of ours (an instance may get its own later)', split_up.conf, 'servers-file', false);
	eq('dnsmasq: one file only', keys(split_up), [ 'conf' ]);
	contains('dnsmasq split: no no-resolv', split_up.conf, 'no-resolv', false);
	contains('dnsmasq split: no filter-AAAA', split_up.conf, 'filter-AAAA', false);
	contains('dnsmasq split: the server host keeps the normal upstream', split_up.conf, 'server=/vpn.example.org/#\n');
	contains('dnsmasq split: tunnelled names resolve through the tunnel', split_up.conf,
		'\nserver=/google.com/ua/youtube.com/127.0.0.1#5300\n');
	eq('dnsmasq split: upstream per name',
		map([ 'www.google.com', 'x.ua', 'news.ru', 'vpn.example.org', 'example.com' ], (n) => upstream_for(split_up, n)),
		[ '127.0.0.1#5300', '127.0.0.1#5300', 'resolv', '#', 'resolv' ]);

	let full_up = dns('proxy-all');

	contains('dnsmasq full: no-resolv', full_up.conf, 'no-resolv\n');
	contains('dnsmasq full: filter-AAAA with ipv6=0', full_up.conf, 'filter-AAAA\n');
	contains('dnsmasq full: never # once no-resolv is set', full_up.conf, '/#\n', false);
	contains('dnsmasq full: direct names name the WAN servers', full_up.conf, 'server=/ru/8.8.8.8\n');
	contains('dnsmasq full: without a server outside the tunnel, server hosts keep the WAN servers', full_up.conf,
		'server=/vpn.example.org/8.8.8.8\n');
	eq('dnsmasq full: everything else goes through the tunnel', filter(lines_of(full_up.conf), (l) => match(l, /^server=[^\/]/)),
		[ 'server=127.0.0.1#5300' ]);
	eq('dnsmasq full: upstream per name',
		map([ 'www.google.com', 'example.com', 'news.ru', 'vpn.example.org' ], (n) => upstream_for(full_up, n)),
		[ '127.0.0.1#5300', '127.0.0.1#5300', '192.168.1.2#5353,2001:4860:4860::8888,8.8.8.8', '192.168.1.2#5353,2001:4860:4860::8888,8.8.8.8' ]);
	eq('dnsmasq full: WAN servers are validated, our own resolvers dropped',
		uniq_targets(full_up.conf), [ '192.168.1.2#5353', '2001:4860:4860::8888', '8.8.8.8' ]);

	// exempt names (server hosts, NTP names) go to plain DNS outside the tunnel (apply: bootstrap_upstreams)
	let boot = dns('proxy-all', {}, { bootstrap_dns: [ '9.9.9.9', '127.0.0.1' ], host_addrs: { 'vpn.example.org': [ '203.0.113.20' ] } });

	eq('dnsmasq full: exempt names go to the bootstrap servers, direct names to the WAN',
		map([ 'vpn.example.org', 'news.ru', 'example.com' ], (n) => upstream_for(boot, n)),
		[ '9.9.9.9', '192.168.1.2#5353,2001:4860:4860::8888,8.8.8.8', '127.0.0.1#5300' ]);
	contains('dnsmasq full: no host-record while a bootstrap server answers', boot.conf, 'host-record=', false);

	let pinned = dns('proxy-all', {}, { wan_dns: [ '127.0.0.1#5053' ], bootstrap_dns: [],
		host_addrs: { 'vpn.example.org': [ '203.0.113.20', '2001:db8::20', 'bogus' ] } });

	eq('dnsmasq full: no server outside the tunnel: the server name is answered from its last addresses',
		filter(lines_of(pinned.conf), (l) => match(l, /^host-record=/)),
		[ 'host-record=vpn.example.org,2001:db8::20', 'host-record=vpn.example.org,203.0.113.20' ]);
	contains('dnsmasq full: a forwarder on another loopback port is a real upstream', pinned.conf, 'server=/ru/127.0.0.1#5053\n');

	let full_nested = routing.render_dnsmasq(model('proxy-all', []), { wan_dns: [ '8.8.8.8' ],
		patterns: { user: [ 'service.ru' ], proxy: [], direct: [ 'ru' ], exempt: [] } });

	eq('dnsmasq full: a tunnelled name under a direct one gets its own tunnel line',
		map([ 'mail.service.ru', 'news.ru', 'example.com' ], (n) => upstream_for(full_nested, n)),
		[ '127.0.0.1#5300', '8.8.8.8', '127.0.0.1#5300' ]);

	let full_down = dns('proxy-all', {}, { tunnel_dns_up: false });

	let tunnel_lines = (l) => match(l, /^server=([^\/]+|\/.*\/127\.0\.0\.1#5300)$/);
	let split_down = dns('selected-rules', {}, { tunnel_dns_up: false });

	eq('dnsmasq full, tunnel down: the WAN servers become the default', filter(lines_of(full_down.conf), (l) => match(l, /^server=[^\/]/)),
		[ 'server=192.168.1.2#5353', 'server=2001:4860:4860::8888', 'server=8.8.8.8' ]);
	eq('dnsmasq full, tunnel down: only the tunnel lines differ',
		filter(lines_of(full_down.conf), (l) => !tunnel_lines(l)), filter(lines_of(full_up.conf), (l) => !tunnel_lines(l)));
	eq('dnsmasq split, tunnel down: the normal upstream for everything',
		[ length(filter(lines_of(split_down.conf), (l) => index(l, '127.0.0.1#5300') >= 0)), upstream_for(split_down, 'x.ua'),
		  join('\n', filter(lines_of(split_down.conf), (l) => !tunnel_lines(l))) == join('\n', filter(lines_of(split_up.conf), (l) => !tunnel_lines(l))) ],
		[ 0, 'resolv', true ]);

	let no_tunnel_dns = dns('proxy-all', { tunnel_dns: false });

	eq('dnsmasq tunnel_dns=0: no server lines, no no-resolv',
		[ length(filter(lines_of(no_tunnel_dns.conf), (l) => match(l, /^(server=|no-resolv)/))),
		  index(no_tunnel_dns.conf, 'filter-AAAA') >= 0 ],
		[ 0, true ]);
	contains('dnsmasq ipv6=1: no filter-AAAA', dns('proxy-all', { ipv6: true }).conf, 'filter-AAAA', false);

	// servers-file and max-ttl may appear once only: an instance's own servers-file (an ad blocker's UCI
	// serversfile, set before or after Shadow started) always starts along with our conf, and a UCI max_ttl
	// leaves ours out
	sh(`mkdir -p ${TMP}/dns && touch ${TMP}/dns/adblock.servers`);

	let own_servers = `servers-file=${TMP}/dns/adblock.servers\n`;
	let along = sh(`dnsmasq --test -C ${write(`${TMP}/dns/along.conf`, own_servers + full_up.conf)}`);
	let clash = sh(`dnsmasq --test -C ${write(`${TMP}/dns/clash.conf`, 'max-ttl=60\n' + split_up.conf)}`);
	let own_ttl = dns('selected-rules', {}, { uci: { max_ttl: '60' } });
	let along_ttl = sh(`dnsmasq --test -C ${write(`${TMP}/dns/along-ttl.conf`, own_servers + 'max-ttl=60\n' + own_ttl.conf)}`);

	report('dnsmasq: an instance\'s own servers-file starts along with our conf', along.rc == 0, along.out);
	report('dnsmasq: a second max-ttl is refused by dnsmasq', clash.rc != 0 && index(clash.out, 'repeated') >= 0, clash.out);
	eq('dnsmasq: with the instance\'s own max-ttl ours is left out and the tunnel lines stay',
		[ index(own_ttl.conf, 'max-ttl') < 0, index(own_ttl.conf, 'server=/google.com/ua/youtube.com/127.0.0.1#5300\n') >= 0, along_ttl.rc ],
		[ true, true, 0 ]);

	let many = [];

	for (let i = 0; i < 3000; i++)
		push(many, `host-${i}.example`);

	let big = routing.render_dnsmasq(model('selected-rules'), { wan_dns: [],
		patterns: { user: [], proxy: sort(many), direct: [], exempt: [] } });
	let nftset_lines = filter(lines_of(big.conf), (l) => match(l, /^nftset=/));
	let carried = [];

	for (let l in nftset_lines)
		push(carried, ...slice(split(l, '/'), 1, -1));

	report('dnsmasq: long lists are chunked into reasonable lines',
		length(nftset_lines) > 1 && length(filter(nftset_lines, (l) => length(l) > 1100)) == 0, `${length(nftset_lines)} lines`);
	eq('dnsmasq: the chunks carry every name once', sort(carried), sort(many));

	sh(`rm -rf ${TMP}/dns && mkdir -p ${TMP}/dns`);

	let failed = [], n = 0;

	for (let mode in [ 'proxy-all', 'selected-rules' ])
	for (let tunnel_dns in [ true, false ])
	for (let ipv6 in [ false, true ])
	for (let tunnel_dns_up in [ true, false ])
	for (let wan in [ WAN, [] ]) {
		let r = routing.render_dnsmasq(model(mode, [], { tunnel_dns, ipv6 }),
			{ wan_dns: wan, tunnel_dns_up, patterns: PATTERNS });
		let f = write(`${TMP}/dns/${n}.conf`, r.conf);
		let t = sh(`dnsmasq --test -C ${f}`);

		if (t.rc != 0 || index(t.out, 'syntax check OK') < 0)
			push(failed, `${f}: ${t.out}`);

		n++;
	}

	let t = sh(`dnsmasq --test -C ${write(`${TMP}/dns/big.conf`, big.conf)}`);

	if (t.rc != 0)
		push(failed, `big.conf: ${t.out}`);

	report(`dnsmasq --test -C accepts all ${n + 1} rendered files`, !length(failed), failed[0]);
}

// ---- lists CLI -------------------------------------------------------------------------------------

function cli(args) {
	let r = sh(`ucode -L ${FIX}/cli -L ${SRC} -L ${FIX}/stubs ${CLI} ${args}`);
	let last = lines_of(r.out);

	r.json = length(last) ? parse_json(last[length(last) - 1]) : null;

	return r;
}

function set_model(m) {
	write(`${CLI_TMP}/model.json`, sprintf('%J', m));
}

function job_calls() {
	return length(lines_of(fs.readfile(`${CLI_TMP}/job.log`) ?? ''));
}

function test_cli() {
	sh(`rm -rf ${CLI_TMP} && mkdir -p ${CLI_TMP}/libexec ${CLI_TMP}/run`);
	write(`${CLI_TMP}/libexec/job`, `#!/bin/sh\necho "$*" >> ${CLI_TMP}/job.log\n`);
	fs.chmod(`${CLI_TMP}/libexec/job`, 0o755);
	write(`${WWW}/proxy.lst`, 'youtube.com\n.ua\nYouTube.com\n');
	write(`${WWW}/direct.lst`, '# nothing\n');
	set_model(model('selected-rules'));

	report('lists CLI: usage error', cli('refresh other').rc == 2, 'accepted');

	let r = cli('refresh proxy');

	eq('lists CLI: refresh downloads, stores and converges', [ r.rc, r.json, job_calls() ],
		[ 0, { kind: 'proxy', ok: true, via: 'direct', changed: true, count: 2 }, 1 ]);
	eq('lists CLI: the stored copy', fs.readfile(`${CLI_TMP}/etc/lists/proxy.lst`), '.ua\nyoutube.com\n');

	r = cli('refresh proxy');
	eq('lists CLI: an unchanged list does not converge again', [ r.json?.changed, job_calls() ], [ false, 1 ]);

	r = cli('refresh direct');
	eq('lists CLI: an empty download fails and stores nothing',
		[ r.rc, r.json?.error, fs.access(`${CLI_TMP}/etc/lists/direct.lst`) ? true : false ],
		[ 1, 'Routing direct list refresh returned no domains.', false ]);

	fs.unlink(`${WWW}/direct.lst`);
	r = cli('refresh direct');
	report('lists CLI: a failed download without Shadow active is not retried',
		r.rc == 1 && r.json?.via == 'direct' && match(r.json?.error ?? '', /^Routing list download failed/), r.out);
	report('lists CLI: a failed Refresh logs its reason (LuCI says "see the log")',
		match(fs.readfile(`${CLI_TMP}/log.txt`) ?? '', /warning The direct list was not refreshed: Routing list download failed/) != null,
		fs.readfile(`${CLI_TMP}/log.txt`));

	let m = model('selected-rules');

	set_model(m);
	write(`${CLI_TMP}/run/ssh.s_000000000001.log`, rep(rep('x', 1023) + '\n', 300));
	write(`${CLI_TMP}/run/ssh.s_000000000002.log`, 'short\n');
	r = cli('refresh due');
	eq('lists CLI: due refreshes only enabled lists that are stale or missing',
		[ r.rc, map(r.json?.results ?? [], (x) => [ x.kind, x.ok ]) ], [ 1, [ [ 'direct', false ] ] ]);
	eq('lists CLI: due raises a missing list that cannot be fetched',
		map(parse_json(fs.readfile(`${CLI_TMP}/attention.json`) ?? '[]') ?? [], (a) => [ a.code, a.extra?.key ]), [ [ 'list_failed', 'direct' ] ]);
	eq('lists CLI: due caps the ssh logs',
		[ fs.stat(`${CLI_TMP}/run/ssh.s_000000000001.log`)?.size, fs.stat(`${CLI_TMP}/run/ssh.s_000000000002.log`)?.size ], [ 0, 6 ]);

	write(`${WWW}/direct.lst`, 'yandex.ru\n');
	r = cli('refresh due');
	eq('lists CLI: due fetches the missing list once it is served',
		[ r.rc, r.json, job_calls() ],
		[ 0, { ok: true, results: [ { kind: 'direct', ok: true, via: 'direct', changed: true, count: 1 } ] }, 2 ]);
	eq('lists CLI: a refresh that succeeds clears its list_failed attention',
		parse_json(fs.readfile(`${CLI_TMP}/attention.json`) ?? '[]'), []);

	m.main.lists_refresh = 0;
	set_model(m);
	eq('lists CLI: lists_refresh=0 refreshes nothing', cli('refresh due').json, { ok: true, results: [] });
}

function test_dns_leak() {
	let uci = [ '/shadow.lab/203.0.113.10', '9.9.9.9', '127.0.0.1#5300', '2620:fe::fe', '192.168.1.2#5353',
		'9.9.9.9#53', 'not-an-ip', '/#/1.1.1.1' ];

	eq('dns_leak: full mode with tunnel DNS reports the plain UCI upstreams only',
		routing.dns_leak(model('proxy-all'), uci), [ '192.168.1.2#5353', '2620:fe::fe', '9.9.9.9' ]);
	eq('dns_leak: a single UCI value works too', routing.dns_leak(model('proxy-all'), '8.8.8.8'), [ '8.8.8.8' ]);
	eq('dns_leak: nothing in split mode', routing.dns_leak(model('selected-rules'), uci), []);
	eq('dns_leak: nothing without tunnel DNS', routing.dns_leak(model('proxy-all', [], { tunnel_dns: false }), uci), []);
	eq('dns_leak: nothing without UCI servers', routing.dns_leak(model('proxy-all'), null), []);

	// a forwarder on the router (https-dns-proxy, dnscrypt-proxy) sends its lookups through the tunnel in
	// full mode: no leak, but no server name can be resolved through it either
	let fwd = [ '127.0.0.1#5053', '127.0.0.53', '127.0.0.1', '::1', '8.8.8.8', '77.88.8.8#1253', '192.168.1.2', '10.0.0.1#5353' ];

	eq('dns_leak: forwarders on the router are not leaks in full mode', routing.dns_leak(model('proxy-all'), fwd),
		[ '10.0.0.1#5353', '192.168.1.2', '8.8.8.8' ]);
	eq('tunnelled_upstreams: loopback forwarders and remote non-53 ports in full mode',
		routing.tunnelled_upstreams(model('proxy-all'), fwd), [ '127.0.0.1#5053', '127.0.0.53', '77.88.8.8#1253' ]);
	eq('tunnelled_upstreams: none in split mode or without router traffic',
		[ routing.tunnelled_upstreams(model('selected-rules'), fwd), routing.tunnelled_upstreams(model('proxy-all', [], { router_traffic: false }), fwd) ],
		[ [], [] ]);
	eq('bootstrap_upstreams: DNS whose lookups leave directly (port 53 or a local address), not a LAN resolver, never dnsmasq',
		routing.bootstrap_upstreams(model('proxy-all'), fwd, [ '192.168.1.0/24' ]), [ '10.0.0.1#5353', '8.8.8.8' ]);
	eq('bootstrap_upstreams: without router traffic a forwarder on the router can resolve them',
		routing.bootstrap_upstreams(model('proxy-all', [], { router_traffic: false }), fwd, [ '192.168.1.0/24' ]),
		[ '10.0.0.1#5353', '127.0.0.1#5053', '127.0.0.53', '77.88.8.8#1253', '8.8.8.8' ]);
}

// ---- run -------------------------------------------------------------------------------------------

sh(`rm -rf ${TMP} && mkdir -p ${TMP}`);

test_validate();
test_list_parse();
test_list_store();

if (start_httpd()) {
	test_list_fetch();
	test_cli();
}
else {
	report('uhttpd starts for the download tests', false, 'uhttpd did not answer');
}

stop_httpd();
test_patterns();
test_changed_sets();
test_render_nft();
test_apply();
test_render_dnsmasq();
test_dns_leak();

sh(`rm -rf ${TMP} ${CLI_TMP}`);
exit(failures ? 1 : 0);
