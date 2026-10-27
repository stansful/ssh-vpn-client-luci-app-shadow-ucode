'use strict';

// Module tests of shadow-vpn.ssh and shadow-vpn.keys. Run by ssh_test.uc as
//   SHADOW_TEST_ROOT=<scratch dir> ucode -S -L <scratch dir>/lib -L shadow-vpn/files/usr/share/ucode cases.uc
// where <scratch dir>/lib/shadow-vpn/const.uc is the real one with ETC/RUN/LOCK moved under the scratch dir.

import { readfile, writefile, unlink, mkdir, stat, popen, dirname } from 'fs';
import * as ssh from 'shadow-vpn.ssh';
import * as keys from 'shadow-vpn.keys';
import { ETC, RUN } from 'shadow-vpn.const';

const HERE = dirname(sourcepath());
const ROOT = getenv('SHADOW_TEST_ROOT');
const MODPATH = `-L '${ROOT}/lib' -L '${HERE}/../../../shadow-vpn/files/usr/share/ucode'`;
let failed = 0;

function ok(name) {
	print(`ok ${name}\n`);
}

function fail(name, why) {
	failed++;
	print(`not ok ${name}: ${why}\n`);
}

function check(name, cond, why) {
	cond ? ok(name) : fail(name, why ?? 'condition is false');
}

function eq(name, got, want) {
	let g = sprintf('%J', got), w = sprintf('%J', want);

	(g == w) ? ok(name) : fail(name, `got ${g}, want ${w}`);
}

function load_json(path) {
	return json(readfile(path));
}

function sh(cmd) {
	let p = popen(cmd, 'r');
	let out = p.read('all');

	p.close();

	return out;
}

const SID = 's_0123456789ab', KEY_SID = 'k_0123456789ab';
const SERVER = { sid: SID, name: 'Home', host: 'vpn.example.com', port: 2222, username: 'tunnel', auth: 'password', key: null, fingerprint: '', keepalive: 15 };

function server(patch) {
	let s = { ...SERVER };

	for (let k, v in patch)
		s[k] = v;

	return s;
}

function arg_after(args, flag_value) {
	for (let i = 0; i < length(args) - 1; i++)
		if (args[i] == '-o' && substr(args[i + 1], 0, length(flag_value)) == flag_value)
			return substr(args[i + 1], length(flag_value));

	return null;
}


// --- keys.normalize ---------------------------------------------------------------------------------

let fixtures = load_json(`${HERE}/keys.json`);

for (let name, k in fixtures.keys) {
	let r = keys.normalize(k.text);

	if (k.expect.error) {
		eq(`keys: ${name} is refused`, r, { error: k.expect.error });
		continue;
	}

	eq(`keys: ${name} is ${k.expect.type}/${k.expect.format}${k.expect.encrypted ? '/encrypted' : ''}`,
		[ r.type, r.format, r.encrypted, r.security_key, r.error ], [ k.expect.type, k.expect.format, k.expect.encrypted, false, null ]);

	check(`keys: ${name} keeps the text from BEGIN to END`, r.text == trim(k.text) + '\n', 'stored text differs');
}

let ed = fixtures.keys.desktop_ed25519.text;

eq('keys: empty text', keys.normalize('  \r\n '), { error: 'SSH private key is empty.' });
eq('keys: no text at all', keys.normalize(null), { error: 'SSH private key is empty.' });
eq('keys: a public key', keys.normalize(fixtures.keys.desktop_ed25519.public), { error: 'SSH private key field contains a public key. Paste the private key contents instead.' });
eq('keys: an ECDSA public key, any case', keys.normalize('ECDSA-SHA2-nistp256 AAAA'), { error: 'SSH private key field contains a public key. Paste the private key contents instead.' });
eq('keys: a file path', keys.normalize('~/.ssh/id_ed25519'), { error: 'SSH private key must start with a PRIVATE KEY PEM/OpenSSH header. Paste the key contents, not a file path.' });
eq('keys: a PuTTY key', keys.normalize('PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n'), { error: 'SSH private key must start with a PRIVATE KEY PEM/OpenSSH header. Paste the key contents, not a file path.' });
eq('keys: a key cut off before END', keys.normalize(substr(ed, 0, length(ed) - 40)), { error: 'The key looks cut off — its -----END … PRIVATE KEY----- line is missing. Copy the whole file again.' });
eq('keys: OpenSSH header over garbage', keys.normalize('-----BEGIN OPENSSH PRIVATE KEY-----\nbm90IGEga2V5\n-----END OPENSSH PRIVATE KEY-----'), { error: 'Unable to load SSH private key. Check the key format and passphrase.' });
eq('keys: PKCS#8 of an unknown algorithm', keys.normalize('-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VuBCIEIA==\n-----END PRIVATE KEY-----'), { error: 'Unable to load SSH private key. Check the key format and passphrase.' });

let want = ed + '\n';

eq('keys: BOM, CRLF and surrounding blanks', keys.normalize('\xef\xbb\xbf  ' + replace(ed, '\n', '\r\n') + '\r\n\r\n').text, want);
eq('keys: CR line ends', keys.normalize(replace(ed, '\n', '\r')).text, want);
eq('keys: pasted on one line from JSON (literal \\n)', keys.normalize(replace(ed, '\n', '\\n')).text, want);
eq('keys: literal \\r\\n', keys.normalize(replace(ed, '\n', '\\r\\n')).text, want);
eq('keys: text before the header is dropped', keys.normalize('id_ed25519:\n' + ed + '\ntrailing note').text, want);


// --- argv, params ------------------------------------------------------------------------------------

let args = ssh.argv(SERVER, { server_ip: '203.0.113.20' });
let joined = join('\n', args ?? []);

check('argv: built for a password server', type(args) == 'array' && args[0] == '/usr/libexec/ssh-openssh', sprintf('%J', args));
eq('argv: no config file, no tty, SOCKS on loopback', slice(args, 1, 8), [ '-F', 'none', '-n', '-N', '-T', '-D', '127.0.0.1:12346' ]);
eq('argv: port and user', slice(args, 8, 12), [ '-p', '2222', '-l', 'tunnel' ]);
eq('argv: HostName is the resolved address', arg_after(args, 'HostName='), '203.0.113.20');
eq('argv: HostKeyAlias keeps the host-key identity', arg_after(args, 'HostKeyAlias='), 'shadow-' + SID);
eq('argv: destination is the alias after --', slice(args, -2), [ '--', 'shadow-' + SID ]);
eq('argv: KnownHostsCommand', arg_after(args, 'KnownHostsCommand='), '/usr/libexec/shadow-vpn/ssh-hostkey %I %H %t %f %K');
eq('argv: LocalCommand', arg_after(args, 'LocalCommand='), '/usr/libexec/shadow-vpn/ssh-up ' + SID);
eq('argv: AES-GCM first', arg_after(args, 'Ciphers='), 'aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr');
eq('argv: strict host keys from the helper only', [ arg_after(args, 'StrictHostKeyChecking='), arg_after(args, 'UserKnownHostsFile='), arg_after(args, 'GlobalKnownHostsFile='), arg_after(args, 'CheckHostIP='), arg_after(args, 'UpdateHostKeys=') ], [ 'yes', '/dev/null', '/dev/null', 'no', 'no' ]);
eq('argv: password auth through askpass', [ arg_after(args, 'PubkeyAuthentication='), arg_after(args, 'PreferredAuthentications='), arg_after(args, 'BatchMode='), arg_after(args, 'NumberOfPasswordPrompts=') ], [ 'no', 'password,keyboard-interactive', 'no', '1' ]);
eq('argv: keepalive and timeouts', [ arg_after(args, 'ServerAliveInterval='), arg_after(args, 'ServerAliveCountMax='), arg_after(args, 'ConnectTimeout='), arg_after(args, 'ConnectionAttempts='), arg_after(args, 'ExitOnForwardFailure=') ], [ '15', '3', '10', '1', 'yes' ]);
eq('argv: log to the run file', slice(args, -4, -2), [ '-E', `${RUN}/ssh.${SID}.log` ]);
check('argv: every -o value is a single word or a known command', !length(filter(args, a => index(a, ' ') >= 0 && !match(a, /^(KnownHostsCommand|LocalCommand)=/))), joined);

let kargs = ssh.argv(server({ auth: 'key', key: KEY_SID, keepalive: 30 }), { server_ip: '2001:db8::20', key_path: `/etc/shadow-vpn/keys/${KEY_SID}` });

eq('argv: key auth', [ arg_after(kargs, 'IdentityFile='), arg_after(kargs, 'PubkeyAuthentication='), arg_after(kargs, 'PasswordAuthentication='), arg_after(kargs, 'KbdInteractiveAuthentication='), arg_after(kargs, 'PreferredAuthentications=') ],
	[ `/etc/shadow-vpn/keys/${KEY_SID}`, 'yes', 'no', 'no', 'publickey' ]);
eq('argv: IPv6 server address and own keepalive', [ arg_after(kargs, 'HostName='), arg_after(kargs, 'ServerAliveInterval=') ], [ '2001:db8::20', '30' ]);

eq('argv: user name with a space is refused', ssh.argv(server({ username: 'a b' }), { server_ip: '203.0.113.20' }), null);
eq('argv: user name that looks like an option is refused', ssh.argv(server({ username: '-oProxyCommand=x' }), { server_ip: '203.0.113.20' }), null);
eq('argv: host that looks like an option is refused', ssh.argv(server({ host: '-oProxyCommand=x' }), { server_ip: '203.0.113.20' }), null);
eq('argv: a name instead of an address is refused', ssh.argv(SERVER, { server_ip: 'vpn.example.com' }), null);
eq('argv: key auth needs a key path', ssh.argv(server({ auth: 'key', key: KEY_SID }), { server_ip: '203.0.113.20' }), null);
eq('argv: port out of range is refused', ssh.argv(server({ port: 70000 }), { server_ip: '203.0.113.20' }), null);
eq('argv: a rule id is not a server id', ssh.argv(server({ sid: 'r_0123456789ab' }), { server_ip: '203.0.113.20' }), null);

let p = json(ssh.params(server({ fingerprint: 'SHA256:1Vm68wGq7uh5BymK4W7Mb5sdNSg1lHJAyjoYrPDLGWw', note: 'private note' })));

eq('params: the non-secret server fields', p, { sid: SID, name: 'Home', host: 'vpn.example.com', port: 2222, username: 'tunnel', auth: 'password', key: null,
	fingerprint: 'SHA256:1Vm68wGq7uh5BymK4W7Mb5sdNSg1lHJAyjoYrPDLGWw', keepalive: 15 });
eq('params: invalid server', ssh.params(server({ port: 0 })), null);


// --- classify ------------------------------------------------------------------------------------

for (let c in load_json(`${HERE}/logs.json`).cases) {
	let text = c.file ? readfile(`${HERE}/logs/${c.file}`) : c.text;
	let r = ssh.classify(text, c.ctx);
	let got = { code: r.code, fatal: r.fatal };
	let want = { code: c.expect.code, fatal: c.expect.fatal };

	if (c.expect.message) {
		got.message = r.message;
		want.message = c.expect.message;
	}

	eq(`classify: ${c.name}`, got, want);
}

eq('classify: no context at all', ssh.classify(null, null).code, 'unknown');


// --- plan / launch / session_up (run files under the scratch root) -------------------------------

const LOG = `${RUN}/ssh.${SID}.log`, STATE = `${RUN}/ssh.${SID}.state`;
const PW_LOG = 'tunnel@203.0.113.20: Permission denied (publickey,password).\n';
const TIMEOUT_LOG = 'ssh: connect to host 203.0.113.20 port 2222: Operation timed out\n';
const UP_LOG = 'Authenticated to 203.0.113.20 ([203.0.113.20]:2222) using "password".\nConnection to 203.0.113.20 closed by remote host.\n';

function uptime() {
	return int(split(readfile('/proc/uptime'), ' ')[0]);
}

function reset(params) {
	sh(`rm -rf '${RUN}' '${ETC}'; mkdir -p -m 0700 '${RUN}' '${ETC}/secrets'`);
	writefile(`${ETC}/secrets/${SID}.password`, 'not-a-real-password\n');
	writefile(`${RUN}/ssh.${SID}.params`, ssh.params(params ?? server({ host: '203.0.113.20' })));
}

function state_json() {
	return json(readfile(`${RUN}/state.json`) ?? 'null');
}

function run_state() {
	return json(readfile(STATE) ?? 'null');
}

function fail_with(log) {
	writefile(LOG, log);

	return ssh.plan(SID);
}

reset();
eq('plan: first run starts at once', ssh.plan(SID), '0');

writefile(`${RUN}/fatal`, sprintf('%J', { transport: 'ssh', sid: SID, code: 'auth', message: 'SSH authentication failed: password auth rejected' }));
eq('plan: the fatal flag stops every retry', ssh.plan(SID), 'fatal');
eq('plan: ...and shows the error', [ state_json().phase, state_json().message ], [ 'error', 'SSH authentication failed: password auth rejected' ]);

reset();
eq('plan: auth rejected on the first connect is fatal', fail_with(PW_LOG), 'fatal');
let f = json(readfile(`${RUN}/fatal`) ?? 'null');
eq('plan: fatal flag written', [ f?.sid, f?.code, f?.message ], [ SID, 'auth', 'SSH authentication failed: password auth rejected' ]);
eq('plan: attention raised', map(json(readfile(`${RUN}/attention.json`)), a => [ a.code, a.extra?.sid ]), [ [ 'ssh_fatal', SID ] ]);
eq('plan: state is error', [ state_json().phase, state_json().code, state_json().transport ], [ 'error', 'auth', 'ssh' ]);
check('plan: the classified log is cleared, so Connect starts afresh', readfile(LOG) == '' && !stat(STATE), 'log or state left behind');
eq('plan: last result for LuCI', [ json(readfile(`${RUN}/ssh.${SID}.last`)).code, json(readfile(`${RUN}/ssh.${SID}.last`)).fatal ], [ 'auth', true ]);

reset();
let delays = [];

for (let i = 0; i < 8; i++)
	push(delays, fail_with(TIMEOUT_LOG));

eq('plan: backoff 1, 2, 4 ... 60 s', delays, [ '1', '2', '4', '8', '16', '32', '60', '60' ]);
eq('plan: reconnecting state', [ state_json().phase, state_json().code, state_json().message ], [ 'reconnecting', 'timeout', 'SSH TCP connect timeout for 203.0.113.20:2222.' ]);

check('reset_backoff: next attempt at once', ssh.reset_backoff(SID) && run_state().fails == 0, sprintf('%J', run_state()));
eq('plan: after reset_backoff', fail_with(TIMEOUT_LOG), '0');
eq('plan: ...then the backoff starts over', fail_with(TIMEOUT_LOG), '1');

reset();
ssh.plan(SID);
let line = ssh.launch(SID);
eq('launch: first attempt is "connecting"', [ state_json().phase, state_json().attempt, state_json().message ], [ 'connecting', 0, 'Connecting to 203.0.113.20:2222.' ]);
check('launch: returns the exec line', match(line ?? '', /^export SSH_ASKPASS='\/usr\/libexec\/shadow-vpn\/ssh-askpass' SSH_ASKPASS_REQUIRE=force SHADOW_ID=s_0123456789ab; unset DISPLAY; exec '\/usr\/libexec\/ssh-openssh' /), line);
eq('launch: the exec line holds exactly argv()', split(trim(sh(`set -- ${substr(line, index(line, 'exec ') + 5)}; for a in "$@"; do printf '%s\\n' "$a"; done`)), '\n'),
	ssh.argv(server({ host: '203.0.113.20' }), { server_ip: '203.0.113.20' }));
check('launch: no secret in the exec line', index(line, 'not-a-real-password') < 0, line);
eq('launch: server address recorded for the nft renderer', readfile(`${RUN}/ssh.${SID}.addr`), '203.0.113.20\n');

ssh.session_up(SID);
eq('session_up: connected', [ state_json().phase, state_json().message, state_json().attempt ], [ 'connected', 'Connected to Home.', 0 ]);
eq('session_up: session recorded', [ run_state().session, run_state().prev, type(run_state().up_at) ], [ true, null, 'int' ]);

// A short session that ends counts as a failure; a long one resets the backoff.
eq('plan: a short session that drops backs off', fail_with(UP_LOG), '1');
eq('plan: ...with the desktop text', state_json().message, 'SSH session lost (SSH transport closed.); reconnecting.');
ssh.launch(SID);
eq('launch: then "reconnecting" with the attempt', [ state_json().phase, state_json().attempt, state_json().message ], [ 'reconnecting', 1, 'Reconnecting to 203.0.113.20:2222 (attempt 1).' ]);

ssh.session_up(SID);
let st = run_state();
st.up_at = uptime() - 200;
writefile(STATE, sprintf('%J', st));
eq('plan: a session of 120 s or more resets the backoff', fail_with(UP_LOG), '0');

// Auth during auto-reconnect: one rejection retries, two in a row stop.
eq('plan: first auth rejection while reconnecting retries', fail_with(PW_LOG), '1');
eq('plan: ...and says so', state_json().message, 'SSH authentication failed: password auth rejected');
eq('plan: a timeout in between', fail_with(TIMEOUT_LOG), '2');
eq('plan: auth again after a timeout still retries', fail_with(PW_LOG), '4');
eq('plan: the second auth rejection in a row is fatal', fail_with(PW_LOG), 'fatal');

// job wan-up may remove the state file of a running session: reconnect at once, as a reconnect.
reset();
eq('plan: lost state file after a session reconnects at once', fail_with(UP_LOG), '0');
eq('plan: ...as a reconnect', [ run_state().session, state_json().phase ], [ true, 'reconnecting' ]);

// A Connect gives the instance a new SHADOW_GEN: the old series' log is not classified.
function plan_in_gen(gen) {
	return trim(sh(`SHADOW_GEN='${gen}' ucode -S ${MODPATH} -e 'import { plan } from "shadow-vpn.ssh"; print(plan("${SID}"));'`));
}

reset();
ssh.launch(SID);
ssh.session_up(SID);
writefile(LOG, PW_LOG);
eq('plan: a new generation starts at once', plan_in_gen('g2'), '0');
check('plan: ...forgetting the old series', !stat(STATE) && readfile(LOG) == '' && !stat(`${RUN}/fatal`), sprintf('%J', run_state()));

// The old series' log goes to logd when the next run starts, stamped with that time: each line says so
// (DESIGN.md 6.8), at most the last 40, without the transfer statistics.
{
	let lines = [];

	for (let i = 0; i < 50; i++)
		push(lines, `debug1: line ${i}`);

	sh(`mkdir -p /tmp/ssh-fw-stub && printf '#!/bin/sh\\ncat >> /tmp/ssh-fw.txt\\n' > /tmp/ssh-fw-stub/logger && chmod 755 /tmp/ssh-fw-stub/logger && rm -f /tmp/ssh-fw.txt`);
	reset();
	ssh.launch(SID);
	writefile(LOG, join('\n', lines) + '\nTransferred: sent 1, received 2 bytes\n');
	sh(`PATH=/tmp/ssh-fw-stub:$PATH SHADOW_GEN='g4' ucode -S ${MODPATH} -e 'import { plan } from "shadow-vpn.ssh"; plan("${SID}");'`);

	let fw = filter(split(readfile('/tmp/ssh-fw.txt') ?? '', '\n'), (l) => l != '');

	check('plan: forwarded ssh lines are marked as the previous run\'s, the last 40, no statistics',
		length(fw) == 40 && fw[0] == '[previous run] debug1: line 10' && fw[39] == '[previous run] debug1: line 49' &&
		!length(filter(fw, (l) => index(l, 'Transferred') >= 0)), join('\n', fw));
}
reset();
writefile(LOG, PW_LOG);
eq('plan: a first run without a state file classifies its log', plan_in_gen('g3'), 'fatal');

reset(server({ host: '203.0.113.20', auth: 'key', key: KEY_SID }));
eq('launch: a missing key file is fatal at once', ssh.launch(SID), 'exec sleep 2147483647');
eq('launch: ...with the desktop text', [ state_json().phase, state_json().message ], [ 'error', 'SSH private key is unavailable.' ]);

reset();
unlink(`${ETC}/secrets/${SID}.password`);
eq('launch: a missing password is fatal at once', ssh.launch(SID), 'exec sleep 2147483647');
eq('launch: ...with the desktop text', state_json().message, 'SSH password is unavailable.');

reset();
unlink(`${RUN}/ssh.${SID}.params`);
writefile(`${RUN}/ssh.sid`, `${SID}\n`);
eq('launch: no params file', ssh.launch(SID), 'exec sleep 2147483647');
check('launch: ...of the selected server is fatal', stat(`${RUN}/fatal`) != null, 'no fatal flag');

// a converge that switched servers removed the old params after naming the new server: procd may still
// start the old instance once (a declaration that raced the converge); it must not park the new one
reset();
unlink(`${RUN}/ssh.${SID}.params`);
writefile(`${RUN}/ssh.sid`, 's_0000000000ff\n');
eq('launch: params gone while another server is selected', ssh.launch(SID), 'exec sleep 2147483647');
check('launch: ...waits for its replacement without a fatal flag', !stat(`${RUN}/fatal`) && !stat(`${RUN}/attention.json`),
	readfile(`${RUN}/fatal`));

// ssh that dies before -E applies (a user name it refuses) leaves an empty log: still a failed run
reset();
ssh.plan(SID);
line = ssh.launch(SID);
check('launch: stderr goes to the log too', substr(line ?? '', -length(`2>>'${LOG}'`)) == `2>>'${LOG}'`, line);
check('launch: the run is marked launched', run_state()?.launched === true, sprintf('%J', run_state()));
eq('plan: an empty log after a launch backs off instead of retrying every 2 s', fail_with(''), '1');
eq('plan: ...and says ssh exited', [ state_json().phase, state_json().message ], [ 'reconnecting', 'SSH exited without an error message.' ]);
reset();
let p1 = ssh.plan(SID), p2 = ssh.plan(SID);
eq('plan: an empty log before any launch still starts at once', [ p1, p2 ], [ '0', '0' ]);

check('params: a user name OpenSSH refuses is not connected with',
	ssh.params(server({ host: '203.0.113.20', username: 'CORP\\ivan' })) == null &&
	ssh.params(server({ host: '203.0.113.20', username: 'user$' })) == null &&
	ssh.params(server({ host: '203.0.113.20', username: 'ivan.petrov' })) != null, 'accepted');

// job wan-up restarts only a session older than the link it runs over (wan6 coming up after wan)
reset();
eq('session_stale: no session yet', ssh.session_stale(SID, 100), true);
ssh.session_up(SID);
st = run_state();
st.up_at = uptime() - 100;
writefile(STATE, sprintf('%J', st));
eq('session_stale: a session newer than its link is kept', ssh.session_stale(SID, 300), false);
eq('session_stale: a session older than its link is restarted', ssh.session_stale(SID, 50), true);
eq('session_stale: an unknown link restarts as before', ssh.session_stale(SID, null), true);
eq('plan: an invalid id never runs ssh', ssh.plan('../../etc'), 'fatal');

reset(server({ host: '203.0.113.20', fingerprint: '' }));
writefile(`${RUN}/pin.${SID}`, 'SHA256:stale\n');
ssh.launch(SID);
check('launch: clears a pin that is no longer set', !stat(`${RUN}/pin.${SID}`), 'pin file left');

reset();
eq('step: answers on fd 3 only', sh(`ucode -S ${MODPATH} -e 'import { step } from "shadow-vpn.ssh"; exit(step("plan", "${SID}"));' 3>&1 >/dev/null`), '0\n');
eq('step: unknown step', ssh.step('nope', SID), 1);

reset();
let big = '';
for (let i = 0; i < 5000; i++)
	big += sprintf('line %05d: channel 3: open failed: connect failed: Connection refused\n', i);
writefile(LOG, big);
check('cap_log: cuts a log over 256 KiB', ssh.cap_log(SID) && stat(LOG).size <= 65536 && match(readfile(LOG), /^line [0-9]{5}: /), `size ${stat(LOG)?.size}`);
check('cap_log: leaves a small log alone', !ssh.cap_log(SID), 'cut twice');

sh(`rm -rf '${RUN}' '${ETC}'`);

exit(failed ? 1 : 0);
