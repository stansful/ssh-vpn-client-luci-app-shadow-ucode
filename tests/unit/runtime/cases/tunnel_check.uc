'use strict';

import { access, writefile, readfile, mkdir } from 'fs';
import { ok, eq, run, done, UCODE, LIBEXEC } from 'rt';

const RUN = '/var/run/shadow-vpn';
const CHECK = `${UCODE} ${LIBEXEC}/tunnel-check`;

if (!access('/usr/lib/ucode/socket.so')) {
	print('ok tunnel_check # skipped: ucode-mod-socket is not installed\n');
	done();
}

if (access(RUN)) {
	print('ok tunnel_check # skipped: /var/run/shadow-vpn already exists\n');
	done();
}

function check(endpoint) {
	let r = run(`${CHECK} ${endpoint ?? ''}`);
	let res = null;

	try {
		res = json(r.out);
	}
	catch (e) { }

	return { rc: r.rc, res: res ?? {}, out: r.out };
}

function listening(port) {
	return run(sprintf("grep -qE '^ *[0-9]+: [0-9A-F]{8}:%04X [0-9A-F]{8}:0000 0A ' /proc/net/tcp", port)).rc == 0;
}

function wait_listen(port) {
	for (let i = 0; i < 50 && !listening(port); i++)
		sleep(100);

	return listening(port);
}

// not active: nothing to test
let c = check('example.com:443');

eq('tunnel_check/inactive', [ c.rc, c.res.ok, c.res.outcome, c.res.detail ], [ 1, false, 'local', 'SSH session is not connected.' ]);

mkdir('/var/run', 0o755);
mkdir(RUN, 0o700);
writefile(`${RUN}/active`, '');
writefile(`${RUN}/state.json`, sprintf('%J\n', { phase: 'connected', transport: 'xray', target: { kind: 'xray', protocol: 'vless' } }));

c = check('example.com:443');
eq('tunnel_check/xray not listening', [ c.res.ok, c.res.outcome, c.res.detail ], [ false, 'local', 'Xray transport is not connected.' ]);

// what the settings accept (validate.endpoint) is what the check takes: a Unicode name goes out in punycode
c = check('яндекс.рф:443');
eq('tunnel_check/an IDN endpoint is not refused as malformed', [ c.res.outcome, c.res.detail, c.res.endpoint ],
	[ 'local', 'Xray transport is not connected.', 'яндекс.рф:443' ]);

c = check('https://example.com/');
eq('tunnel_check/endpoint must be host:port', [ c.res.ok, c.res.detail ], [ false, 'Tunnel check endpoint must be host:port.' ]);

// a stand-in for check-in -> proxy: xray's socks inbound straight to freedom, and a local web server
writefile('/tmp/rt-check.json', sprintf('%J\n', {
	log: { loglevel: 'none' },
	inbounds: [ { tag: 'check-in', listen: '127.0.0.1', port: 12347, protocol: 'socks', settings: { auth: 'noauth', udp: false } } ],
	outbounds: [ { tag: 'direct', protocol: 'freedom' } ]
}));
run('mkdir -p /tmp/rt-www && echo hello > /tmp/rt-www/index.html');

let xray_pid = trim(run('sh -c "xray run -c /tmp/rt-check.json >/dev/null 2>&1 & echo \\$!"').out);
let web_pid = trim(run('sh -c "uhttpd -f -p 127.0.0.1:8080 -h /tmp/rt-www >/dev/null 2>&1 & echo \\$!"').out);

if (wait_listen(12347) && wait_listen(8080)) {
	c = check('127.0.0.1:8080');
	ok('tunnel_check/http: passes on the first response byte', c.rc == 0 && c.res.ok && c.res.outcome == 'http' &&
		match(c.res.detail, /^HTTP\/1\.[01] [0-9]{3}/) != null &&
		match(c.res.message, /127\.0\.0\.1:8080 answered HTTP\/1\.[01] [0-9]{3}/) != null, c.out);
	ok('tunnel_check/http: message', match(c.res.message ?? '', /^Tunnel check succeeded for 127\.0\.0\.1:8080 in [0-9]+ ms: /) != null, c.out);
	ok('tunnel_check/http: latency measured', type(c.res.ms) == 'int' && c.res.ms >= 0, c.out);
	eq('tunnel_check/http: written to check.json', json(readfile(`${RUN}/check.json`) ?? 'null')?.outcome, 'http');

	// the SOCKS reply comes at once; only the missing answer shows the dead upstream
	c = check('127.0.0.1:8000');
	eq('tunnel_check/dead target: fails', [ c.rc, c.res.ok, c.res.outcome ], [ 1, false, 'timeout' ]);
	eq('tunnel_check/dead target: desktop text', c.res.detail,
		'The tunnel opened a connection to 127.0.0.1:8000 but nothing came back within 12 s. Traffic is entering the tunnel and not reaching the server.');

	writefile(`${RUN}/state.json`, sprintf('%J\n', { phase: 'connected', transport: 'xray', target: { kind: 'xray', protocol: 'hysteria2' } }));
	c = check('127.0.0.1:8000');
	ok('tunnel_check/hysteria 2: the UDP hint is added', index(c.res.message ?? '', 'Hysteria 2 runs over UDP (QUIC)') > 0, c.out);
}
else {
	ok('tunnel_check/live: xray and uhttpd listen', false, 'could not start the local stand-ins');
}

run(`kill ${xray_pid} ${web_pid}`);
run(`rm -rf ${RUN} /tmp/rt-check.json /tmp/rt-www`);

done();
