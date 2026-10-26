'use strict';
// Assertions for the runtime test cases: "ok <name>" / "not ok <name>: <why>".

import { popen, writefile, mkdir, unlink } from 'fs';

let failures = 0;

function ok(name, cond, why) {
	if (cond) {
		print(`ok ${name}\n`);
	}
	else {
		failures++;
		print(`not ok ${name}: ${why ?? 'assertion failed'}\n`);
	}

	return !!cond;
}

// key order does not matter, array order does
function canon(v) {
	if (type(v) == 'array')
		return map(v, canon);

	if (type(v) != 'object')
		return v;

	let out = {};

	for (let k in sort(keys(v)))
		out[k] = canon(v[k]);

	return out;
}

function eq(name, got, want) {
	let g = sprintf('%J', canon(got)), w = sprintf('%J', canon(want));

	return ok(name, g == w, `got ${g}, want ${w}`);
}

function run(cmd) {
	let p = popen(`${cmd} </dev/null 2>&1`, 'r');
	let out = p ? (p.read('all') ?? '') : '';

	return { rc: p ? p.close() : -1, out };
}

function done() {
	exit(failures ? 1 : 0);
}

const LOCK = '/var/lock/shadow-vpn.lock', HOLD = '/tmp/rt-lock.hold';

function lock_busy() {
	return run(`flock -n ${LOCK} true`).rc != 0;
}

// Another process holds the shadow-vpn lock until release_lock(), however long the test takes.
// Returns whether it is held.
function hold_lock() {
	mkdir('/var/lock', 0o755);
	writefile(HOLD, '');
	run(`sh -c "flock ${LOCK} sh -c 'while [ -e ${HOLD} ]; do sleep 1; done' >/dev/null 2>&1 &"`);

	for (let i = 0; i < 100 && !lock_busy(); i++)
		sleep(100);

	return lock_busy();
}

function release_lock() {
	unlink(HOLD);
	run(`flock ${LOCK} true`);
}

const MODS = '/src/shadow-vpn/files/usr/share/ucode';
const LIBEXEC = '/src/shadow-vpn/files/usr/libexec/shadow-vpn';
const HERE = '/src/tests/unit/runtime';
const UCODE = `ucode -L ${MODS} -L ${HERE}/lib`;

export { ok, eq, run, done, hold_lock, release_lock, MODS, LIBEXEC, HERE, UCODE };
