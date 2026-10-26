'use strict';

// SSH area tests (CONTRACTS §7), run by tests/unit/run.sh inside a throwaway router container.
//  1. tests/unit/ssh/cases.uc: keys.normalize vectors, argv shape, classify on the lab logs, the
//     plan/launch/session_up decisions. It runs as a child with the real modules, except that a
//     copy of const.uc with ETC/RUN/LOCK moved into a scratch dir comes first on the module path.
//  2. Here: the shell helpers (ssh-hostkey, ssh-askpass) and the ssh-classify CLI, on the real
//     /etc/shadow-vpn and /var/run/shadow-vpn paths of the throwaway container.
// The end-to-end test against a real sshd is tests/unit/ssh/e2e.sh (run on the host).

import { readfile, writefile, unlink, mkdir, stat, popen, dirname, mkdtemp } from 'fs';

const UNIT = dirname(sourcepath());
const SRC = dirname(dirname(UNIT));
const LIBEXEC = `${SRC}/shadow-vpn/files/usr/libexec/shadow-vpn`;
const ETC = '/etc/shadow-vpn', RUN = '/var/run/shadow-vpn';
const SID = 's_00000000c0de', KEY_SID = 'k_00000000c0de', ALIAS = `shadow-${SID}`;

let failed = 0;

function ok(name) {
	print(`ok ${name}\n`);
}

function fail(name, why) {
	failed++;
	print(`not ok ${name}: ${why}\n`);
}

function eq(name, got, want) {
	let g = sprintf('%J', got), w = sprintf('%J', want);

	(g == w) ? ok(name) : fail(name, `got ${g}, want ${w}`);
}

function q(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

// Runs a shell command line; returns { out, rc }.
function run(cmd) {
	let p = popen(`${cmd}; echo "rc=$?"`, 'r');
	let out = p.read('all') ?? '';

	p.close();

	let m = match(out, /^(.*)rc=([0-9]+)\n$/);

	return m ? { out: m[1], rc: int(m[2]) } : { out, rc: -1 };
}

function clean() {
	run(`rm -f ${ETC}/trusted.${SID} ${RUN}/pin.${SID} ${RUN}/hostkey.${SID}.* ${RUN}/ssh.${SID}.* ${ETC}/secrets/${SID}.* ${ETC}/secrets/${KEY_SID}.*`);

	let kh = readfile(`${ETC}/known_hosts`);

	if (kh != null)
		writefile(`${ETC}/known_hosts`, join('', map(filter(split(kh, '\n'), l => length(l) && substr(l, 0, length(ALIAS) + 1) != ALIAS + ' '), l => l + '\n')));
}


// --- module tests ------------------------------------------------------------------------------------

const MODULES = `${SRC}/shadow-vpn/files/usr/share/ucode`;

// const.uc as installed, with its three path literals moved under `root`.
function rooted_const(root) {
	let text = readfile(`${MODULES}/shadow-vpn/const.uc`) ?? '';
	let moved = 0;

	for (let p in [ '/etc/shadow-vpn', '/var/run/shadow-vpn', '/var/lock/shadow-vpn.lock' ]) {
		let lit = `'${p}'`;

		if (index(text, lit) >= 0) {
			text = replace(text, lit, `'${root}${p}'`);
			moved++;
		}
	}

	return (moved == 3) ? text : null;
}

let scratch = mkdtemp('/tmp/ssh-test-XXXXXX');
let consts = rooted_const(scratch);

mkdir(`${scratch}/lib`);
mkdir(`${scratch}/lib/shadow-vpn`);

if (consts == null || !writefile(`${scratch}/lib/shadow-vpn/const.uc`, consts)) {
	fail('ssh module tests', 'const.uc no longer has the ETC, RUN and LOCK literals');
}
else {
	let rc = system(`SHADOW_TEST_ROOT=${q(scratch)} ucode -S -L ${q(scratch + '/lib')} -L ${q(MODULES)} ${q(UNIT + '/ssh/cases.uc')}`);

	if (rc != 0)
		fail('ssh module tests', `cases.uc exited with ${rc}`);
}

run(`rm -rf ${q(scratch)}`);


// --- ssh-hostkey ------------------------------------------------------------------------------------

const ED1 = [ 'ssh-ed25519', 'SHA256:1Vm68wGq7uh5BymK4W7Mb5sdNSg1lHJAyjoYrPDLGWw', 'AAAAC3NzaC1lZDI1NTE5AAAAIICnEGHs7nq2sw+80Q1Z9lrbyRIbnWSRVZR7PqxbERaH' ];
const ED2 = [ 'ssh-ed25519', 'SHA256:pcl39CuIpRa79PZ3qdUMCirkXclIr+wxXIze7RGkrOs', 'AAAAC3NzaC1lZDI1NTE5AAAAIPjS9RAConW5JCWINa9YOi4yh5co3K4ahFCG7QGZ3b37' ];
const RSA = [ 'ssh-rsa', 'SHA256:zQPPYm7PcpE+s3b+gG2tPpELCQBon7uHxWXls4bYoUw', 'AAAAB3NzaC1yc2EAAAADAQABAAABAQDXiZsML6Ega15UGK5lmvd2qWP' ];

function hostkey(inv, key, extra) {
	let k = key ?? [ 'NONE', 'NONE', 'NONE' ];

	return run(`sh ${q(LIBEXEC + '/ssh-hostkey')} ${inv} ${q(ALIAS)} ${q(k[0])} ${q(k[1])} ${q(k[2])} ${extra ?? ''} 2>&1`);
}

function line(k) {
	return `${ALIAS} ${k[0]} ${k[2]}\n`;
}

function status() {
	return readfile(`${RUN}/hostkey.${SID}.status`);
}

mkdir(ETC, 0o700);
mkdir(RUN, 0o700);
clean();

eq('ssh-hostkey: ORDER with nothing trusted prints nothing', hostkey('ORDER'), { out: '', rc: 0 });
eq('ssh-hostkey: first use is trusted', hostkey('HOSTNAME', ED1), { out: line(ED1), rc: 0 });
eq('ssh-hostkey: TOFU stores the known_hosts line', filter(split(readfile(`${ETC}/known_hosts`) ?? '', '\n'), l => substr(l, 0, length(ALIAS)) == ALIAS), [ trim(line(ED1)) ]);
eq('ssh-hostkey: TOFU stores type and fingerprint', slice(split(trim(readfile(`${ETC}/trusted.${SID}`) ?? ''), ' '), 0, 2), [ ED1[0], ED1[1] ]);
eq('ssh-hostkey: the key seen is kept for "Pin this key"', readfile(`${RUN}/hostkey.${SID}.seen`), `${ED1[0]} ${ED1[1]} ${ED1[2]}\n`);
eq('ssh-hostkey: ORDER puts the trusted key first', hostkey('ORDER'), { out: line(ED1), rc: 0 });
eq('ssh-hostkey: the same key again', hostkey('HOSTNAME', ED1), { out: line(ED1), rc: 0 });
eq('ssh-hostkey: a changed key is refused, exit 0', hostkey('HOSTNAME', ED2), { out: '', rc: 0 });
eq('ssh-hostkey: ...and reported', status(), `changed expected=${ED1[1]} got=${ED2[1]} type=ssh-ed25519\n`);
eq('ssh-hostkey: ...and not trusted', slice(split(trim(readfile(`${ETC}/trusted.${SID}`) ?? ''), ' '), 0, 2), [ ED1[0], ED1[1] ]);

unlink(`${RUN}/hostkey.${SID}.status`);
writefile(`${RUN}/pin.${SID}`, RSA[1] + '\n');
eq('ssh-hostkey: with a pin, only the pinned key', hostkey('HOSTNAME', ED1), { out: '', rc: 0 });
eq('ssh-hostkey: ...pin mismatch reported', status(), `pin_mismatch expected=${RSA[1]} got=${ED1[1]} type=ssh-ed25519\n`);
eq('ssh-hostkey: probe mode never prints', hostkey('HOSTNAME', RSA, 'probe'), { out: '', rc: 0 });
eq('ssh-hostkey: probe mode trusts the pinned key', slice(split(trim(readfile(`${ETC}/trusted.${SID}`) ?? ''), ' '), 0, 2), [ RSA[0], RSA[1] ]);
eq('ssh-hostkey: ...so ORDER now asks for its type', hostkey('ORDER'), { out: line(RSA), rc: 0 });
eq('ssh-hostkey: pinned key accepted', hostkey('HOSTNAME', RSA), { out: line(RSA), rc: 0 });

clean();
writefile(`${RUN}/pin.${SID}`, RSA[1] + '\n');
eq('ssh-hostkey: probe of another key stores nothing', [ hostkey('HOSTNAME', ED1, 'probe'), stat(`${ETC}/trusted.${SID}`) ], [ { out: '', rc: 0 }, null ]);

clean();
eq('ssh-hostkey: a key with a newline is ignored', hostkey('HOSTNAME', [ 'ssh-ed25519', ED1[1], 'AAAA\nshadow-x ssh-ed25519 BBBB' ]), { out: '', rc: 0 });
eq('ssh-hostkey: a type with a space is ignored', hostkey('HOSTNAME', [ 'ssh-ed25519 x', ED1[1], ED1[2] ]), { out: '', rc: 0 });
eq('ssh-hostkey: nothing stored for bad input', stat(`${ETC}/trusted.${SID}`), null);
eq('ssh-hostkey: an alias that is not ours', run(`sh ${q(LIBEXEC + '/ssh-hostkey')} HOSTNAME shadow-../../x ${ED1[0]} ${ED1[1]} ${ED1[2]}`), { out: '', rc: 0 });
eq('ssh-hostkey: ADDRESS lookups get nothing', hostkey('ADDRESS', ED1), { out: '', rc: 0 });
clean();


// --- ssh-askpass -----------------------------------------------------------------------------------

function askpass(prompt, sid) {
	return run(`SHADOW_ID=${q(sid ?? SID)} sh ${q(LIBEXEC + '/ssh-askpass')} ${q(prompt)} 2>&1`);
}

function hint() {
	return readfile(`${RUN}/ssh.${SID}.askpass`);
}

mkdir(`${ETC}/secrets`, 0o700);
writefile(`${ETC}/secrets/${SID}.password`, 'pw-for-tests\n');
writefile(`${ETC}/secrets/${KEY_SID}.passphrase`, 'correct horse');

eq('ssh-askpass: password prompt', askpass(`tunnel@${ALIAS}'s password: `), { out: 'pw-for-tests\n', rc: 0 });
eq('ssh-askpass: ...hint for the classifier', hint(), 'password\n');
eq('ssh-askpass: keyboard-interactive password', askpass(`(tunnel@${ALIAS}) Password: `), { out: 'pw-for-tests\n', rc: 0 });
eq('ssh-askpass: key passphrase', askpass(`Enter passphrase for key '${ETC}/keys/${KEY_SID}': `), { out: 'correct horse', rc: 0 });
eq('ssh-askpass: ...hint', hint(), 'passphrase\n');
eq('ssh-askpass: one-time codes are refused', askpass(`(tunnel@${ALIAS}) Verification code: `), { out: '', rc: 1 });
eq('ssh-askpass: host confirmations are refused', askpass('Are you sure you want to continue connecting (yes/no/[fingerprint])? '), { out: '', rc: 1 });
eq('ssh-askpass: another server\'s prompt is refused', askpass(`tunnel@shadow-s_ffffffffffff's password: `), { out: '', rc: 1 });
eq('ssh-askpass: a key outside the key store is refused', askpass(`Enter passphrase for key '/tmp/${KEY_SID}': `), { out: '', rc: 1 });
eq('ssh-askpass: a path in the key name is refused', askpass(`Enter passphrase for key '${ETC}/keys/../secrets/${SID}': `), { out: '', rc: 1 });
eq('ssh-askpass: no valid SHADOW_ID', askpass(`tunnel@${ALIAS}'s password: `, '../x'), { out: '', rc: 1 });

unlink(`${ETC}/secrets/${KEY_SID}.passphrase`);
eq('ssh-askpass: missing passphrase', [ askpass(`Enter passphrase for key '${ETC}/keys/${KEY_SID}': `), hint() ], [ { out: '', rc: 1 }, 'passphrase missing\n' ]);
unlink(`${ETC}/secrets/${SID}.password`);
eq('ssh-askpass: missing password', [ askpass(`tunnel@${ALIAS}'s password: `), hint() ], [ { out: '', rc: 1 }, 'password missing\n' ]);
clean();


// --- ssh-classify CLI ---------------------------------------------------------------------------

let cli = run(`ucode -S -L ${q(MODULES)} ${q(LIBEXEC + '/ssh-classify')} ${q(UNIT + '/ssh/logs/lab-t10c.log')}`);

eq('ssh-classify: prints the result as JSON', [ cli.rc, json(cli.out ?? 'null')?.code, json(cli.out ?? 'null')?.fatal ], [ 0, 'dead_link', false ]);
eq('ssh-classify: usage', run(`ucode -S -L ${q(MODULES)} ${q(LIBEXEC + '/ssh-classify')} 2>/dev/null`).rc, 2);


// --- helper files -----------------------------------------------------------------------------------

for (let h in [ 'ssh-run', 'ssh-askpass', 'ssh-hostkey' ]) {
	let first = split(readfile(`${LIBEXEC}/${h}`) ?? '', '\n')[0];

	eq(`${h}: plain #!/bin/sh first line`, first, '#!/bin/sh');
	eq(`${h}: parses under busybox ash`, run(`sh -n ${q(LIBEXEC + '/' + h)} 2>&1`), { out: '', rc: 0 });
}

for (let h in [ 'ssh-up', 'ssh-classify' ])
	eq(`${h}: plain ucode interpreter line`, split(readfile(`${LIBEXEC}/${h}`) ?? '', '\n')[0], '#!/usr/bin/ucode');

exit(failed ? 1 : 0);
