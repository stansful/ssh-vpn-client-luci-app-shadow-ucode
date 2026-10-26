'use strict';

import { access, writefile, mkdir, unlink, rmdir, glob } from 'fs';
import { ok, eq, run, done, hold_lock, release_lock, LIBEXEC } from 'rt';

const RUN = '/var/run/shadow-vpn', HOOK = `sh ${LIBEXEC}/fw4-hook`;
const SID = 's_0000000000c1';

if (access(RUN) || run('nft list table inet shadow_vpn').rc == 0 || index(run('ip -4 rule show').out, 'lookup 106') >= 0) {
	print('ok heal # skipped: shadow-vpn state already present\n');
	done();
}

function rule_count() {
	return length(filter(split(run('ip -4 rule show').out, '\n'), (l) => index(l, 'fwmark 0x400000/0x400000 lookup 106') >= 0));
}

function table_exists() {
	return run('nft list table inet shadow_vpn').rc == 0;
}

function local_route() {
	return match(run('ip -4 route show table 106').out, /^local default dev lo/) != null;
}

mkdir('/var/run', 0o755);
mkdir(RUN, 0o700);
writefile(`${RUN}/table.nft`, "table inet shadow_vpn {\n\tset server4 { type ipv4_addr; flags interval; }\n\tchain gate {\n\t}\n}\n");

run(HOOK);
ok('heal/inactive: nothing is restored', !table_exists() && rule_count() == 0);

writefile(`${RUN}/active`, '');

// the fw4 reload of our own apply: the hook leaves everything to it
run(`SHADOW_APPLYING=1 ${HOOK}`);
ok('heal/inside apply: nothing is done', !table_exists() && rule_count() == 0);

// ssh's current address goes back into @server4 with the table
writefile(`${RUN}/ssh.sid`, `${SID}\n`);
writefile(`${RUN}/ssh.${SID}.addr`, '198.51.100.7\n');
run(HOOK);
ok('heal/active: table restored from RUN/table.nft', table_exists());
ok('heal/active: ssh server address restored', index(run('nft list set inet shadow_vpn server4').out, '198.51.100.7') >= 0,
	run('nft list set inet shadow_vpn server4').out);
eq('heal/active: fwmark rule restored', rule_count(), 1);
ok('heal/active: local route restored', local_route());

run(HOOK);
eq('heal/again: no duplicate rule', rule_count(), 1);

// an lo flap drops the route but keeps the rule
run('ip -4 route flush table 106');
run(`${HOOK} --iface`);
ok('heal/iface: route restored', local_route());

// never wait for our lock; leave "pending" for the holder, but only when something is broken
if (ok('heal/busy: the test holds the lock', hold_lock())) {
	run(HOOK);
	ok('heal/busy, all in place: nothing for the holder to redo', !access(`${RUN}/pending`));

	run('nft delete table inet shadow_vpn');

	let r = run(HOOK);

	ok('heal/busy: returns without waiting and leaves pending', r.rc == 0 && access(`${RUN}/pending`) && !table_exists(), r.out);
}

release_lock();

run('ip -4 rule del fwmark 0x400000/0x400000 table 106 priority 106');
run('ip -4 route flush table 106');
run('ip -6 rule del fwmark 0x400000/0x400000 table 106 priority 106');
run('ip -6 route flush table 106');
run('nft delete table inet shadow_vpn');

for (let f in glob(`${RUN}/*`) ?? [])
	unlink(f);

rmdir(RUN);
done();
