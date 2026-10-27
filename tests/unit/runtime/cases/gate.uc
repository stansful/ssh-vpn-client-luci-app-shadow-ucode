'use strict';

import { access, writefile, readfile, unlink, rmdir, glob, mkdir } from 'fs';
import { ok, eq, run, done, hold_lock, release_lock, LIBEXEC } from 'rt';

const GATE = `sh ${LIBEXEC}/gate-set`;

// DESIGN.md 6.7: only fallback mode with xray down >= 10 s (or a fatal config error) opens the gate.
const TABLE = [
	// fallback  listening  down_s  fatal  verdict
	[ 'block',   0,         600,    1,     '' ],
	[ 'block',   0,         600,    0,     '' ],
	[ 'block',   1,         0,      0,     '' ],
	[ 'direct',  1,         600,    0,     '' ],
	[ 'direct',  1,         0,      1,     '' ],
	[ 'direct',  0,         0,      0,     '' ],
	[ 'direct',  0,         9,      0,     '' ],
	[ 'direct',  0,         10,     0,     'accept' ],
	[ 'direct',  0,         3600,   0,     'accept' ],
	[ 'direct',  0,         0,      1,     'accept' ],
	[ '',        0,         600,    1,     '' ]
];

for (let row in TABLE) {
	let r = run(`${GATE} --verdict '${row[0]}' ${row[1]} ${row[2]} ${row[3]}`);

	eq(sprintf('gate/verdict fallback=%s listening=%d down=%ds fatal=%d', row[0] || '-', row[1], row[2], row[3]),
		trim(r.out), row[4]);
}

const RUN = '/var/run/shadow-vpn', CONFDIR = '/tmp/rt-gate.d';

// Live: the real gate chain in the container's own netns, only where nothing of ours exists yet.
if (access(RUN) || run('nft list table inet shadow_vpn').rc == 0) {
	print('ok gate/live # skipped: shadow-vpn state already present\n');
	done();
}

let r = run(`${GATE}`);

ok('gate/inactive: does nothing', r.rc == 0 && r.out == '', r.out);

mkdir('/var/run', 0o755);
mkdir(RUN, 0o700);

let base = "table inet shadow_vpn {\n\tchain gate {\n\t}\n}\nflush chain inet shadow_vpn gate\n";

writefile(`${RUN}/table.open.nft`, base);
writefile(`${RUN}/table.accept.nft`, base + "add rule inet shadow_vpn gate accept\n");
writefile(`${RUN}/table.nft`, base);
writefile(`${RUN}/gate`, '\n');
writefile(`${RUN}/active`, '');
run(`nft -f ${RUN}/table.nft`);

let up = +split(readfile('/proc/uptime'), '.')[0];
let listening = run("grep -qE '^ *[0-9]+: (0100007F|7F000001):3039 [0-9A-F]{8}:0000 0A ' /proc/net/tcp").rc == 0;

if (listening) {
	print('ok gate/live # skipped: something listens on 12345\n');
}
else {
	// DNS follows the gate through a converge: when the installed dnsmasq conf is not the verdict's
	// variant, gate-set leaves "pending" for the lock holder (the converge installs it, post-start restarts)
	const CONF = `${CONFDIR}/shadow-vpn.conf`;
	const UP = "# up\nserver=/example.org/127.0.0.1#5300\n", DOWN = "# down\n";

	mkdir(CONFDIR, 0o755);
	writefile(`${RUN}/dnsmasq`, `cfgtest ${CONFDIR}\n`);
	writefile(`${RUN}/dnsmasq.conf`, UP);
	writefile(`${RUN}/dnsmasq.down.conf`, DOWN);
	writefile(CONF, UP);

	writefile(`${RUN}/fallback`, 'direct\n');
	writefile(`${RUN}/xray.down`, `${up - 3}\n`);
	run(`${GATE} --locked`);
	ok('gate/live: xray down 3 s keeps the gate closed', index(run('nft list chain inet shadow_vpn gate').out, 'accept') < 0);
	ok('gate/live: the tunnel DNS conf is the right one, nothing pending', !access(`${RUN}/pending`));

	writefile(`${RUN}/xray.down`, `${up - 60}\n`);
	run(`${GATE} --locked`);
	ok('gate/live: xray down 60 s in fallback mode opens it', index(run('nft list chain inet shadow_vpn gate').out, 'accept') >= 0);
	eq('gate/live: verdict recorded', trim(readfile(`${RUN}/gate`)), 'accept');
	eq('gate/live: heals reload the accept variant', readfile(`${RUN}/table.nft`), readfile(`${RUN}/table.accept.nft`));
	ok('gate/live: DNS must follow: a converge is left pending', access(`${RUN}/pending`) == true);
	eq('gate/live: gate-set itself never rewrites the dnsmasq conf', readfile(CONF), UP);
	unlink(`${RUN}/pending`);

	// what the converge then installs
	writefile(CONF, DOWN);
	run(`${GATE} --locked`);
	ok('gate/live: normal-upstream conf in place, nothing pending', !access(`${RUN}/pending`));

	writefile(`${RUN}/fallback`, 'block\n');
	run(`${GATE} --locked`);
	ok('gate/live: the kill switch closes it again', index(run('nft list chain inet shadow_vpn gate').out, 'accept') < 0);
	eq('gate/live: closed verdict recorded', trim(readfile(`${RUN}/gate`)), '');
	eq('gate/live: heals reload the closed variant', readfile(`${RUN}/table.nft`), readfile(`${RUN}/table.open.nft`));
	ok('gate/live: tunnel DNS back needs a converge too', access(`${RUN}/pending`) == true);
	unlink(`${RUN}/pending`);
	writefile(CONF, UP);

	// Settings → Logs (DESIGN.md 6.8): the level the last converge left in RUN, by the rules of state.log
	mkdir('/tmp/rt-gate-stub', 0o755);
	writefile('/tmp/rt-gate-stub/logger', '#!/bin/sh\necho "$*" >> /tmp/rt-gate-logger.txt\n');
	run('chmod 755 /tmp/rt-gate-stub/logger');

	let seen = {};

	for (let lv in [ '', 'error', 'warning', 'info', 'debug', 'verbose' ]) {
		unlink('/tmp/rt-gate-logger.txt');
		writefile(`${RUN}/log_level`, lv ? `${lv}\n` : '');
		// a verdict change each time: open, then closed again
		writefile(`${RUN}/fallback`, 'direct\n');
		writefile(`${RUN}/xray.down`, `${up - 60}\n`);
		run(`PATH=/tmp/rt-gate-stub:$PATH ${GATE} --locked`);
		writefile(`${RUN}/fallback`, 'block\n');
		run(`PATH=/tmp/rt-gate-stub:$PATH ${GATE} --locked`);

		let out = readfile('/tmp/rt-gate-logger.txt') ?? '';

		seen[lv || 'none'] = [ index(out, '-p daemon.warn tunnel gate: accept') >= 0, index(out, '-p daemon.debug tunnel gate: fallback ') >= 0 ];
	}

	unlink(`${RUN}/log_level`);
	unlink(`${RUN}/pending`);
	writefile(CONF, UP);
	eq('gate/log: the level in RUN decides [the warn line, the debug line]', seen, {
		none: [ true, false ], error: [ false, false ], warning: [ true, false ], info: [ true, false ],
		debug: [ true, true ], verbose: [ true, false ]
	});

	// never wait for the lock (ssh-up runs gate-set synchronously)
	if (ok('gate/busy: the test holds the lock', hold_lock())) {
		run(GATE);
		ok('gate/busy, same verdict: nothing for the holder to redo', !access(`${RUN}/pending`));

		writefile(`${RUN}/fallback`, 'direct\n');
		writefile(`${RUN}/xray.down`, `${up - 60}\n`);
		run(GATE);
		ok('gate/busy, new verdict: left to the holder', access(`${RUN}/pending`) &&
			index(run('nft list chain inet shadow_vpn gate').out, 'accept') < 0);
		unlink(`${RUN}/pending`);
	}

	release_lock();

	writefile(`${RUN}/fallback`, 'direct\n');
	writefile(`${RUN}/xray.down`, `${up}\n`);
	writefile(`${RUN}/xray.fatal`, '');
	run(GATE);
	ok('gate/live: a fatal config error opens it at once', index(run('nft list chain inet shadow_vpn gate').out, 'accept') >= 0);
}

run('nft delete table inet shadow_vpn');
run(`rm -rf ${CONFDIR}`);

for (let f in glob(`${RUN}/*`) ?? [])
	unlink(f);

rmdir(RUN);

done();
