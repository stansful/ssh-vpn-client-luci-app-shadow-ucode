'use strict';

// SSH transport (DESIGN §8): the ssh command line, what its log means, and the steps behind the
// helpers. ssh-run runs step('plan') and step('launch') and then execs ssh; ssh-up runs
// session_up() as ssh's LocalCommand and after_up() detached.

import { readfile, writefile, rename, unlink, stat, mkdir, open, popen, fdopen } from 'fs';
import { UCI, ETC, RUN, LIBEXEC, NFT_TABLE, PORT_SSH } from 'shadow-vpn.const';
import * as secrets from 'shadow-vpn.secrets';
import * as state from 'shadow-vpn.state';

const SSH = '/usr/libexec/ssh-openssh';
const SERVER_SID = /^s_[0-9a-f]{12}$/;
const KEY_SID = /^k_[0-9a-f]{12}$/;
const HOST_RE = /^[A-Za-z0-9_.:][A-Za-z0-9_.:-]*$/;
const USER_RE = /^[^-[:space:][:cntrl:]%][^[:space:][:cntrl:]%]*$/;
// OpenSSH refuses a remote user name with any of these (readconf.c ssh_valid_ruser) before -E applies
const USER_REFUSED = "'`\";&<>|(){}$\\";
const FINGERPRINT_RE = /^SHA256:[A-Za-z0-9+\/]{43}$/;

// AES-GCM first: the MT7981B has the ARMv8 crypto extension and the feed's libcrypto uses it.
const CIPHERS = 'aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes128-ctr';

// Tried in turn before the first connect with a pinned key whose type is not known yet, like the
// desktop does (§8.8): a pinned RSA fingerprint keeps working although ssh prefers Ed25519.
const HOSTKEY_FAMILIES = [
	'ssh-ed25519',
	'ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,ecdsa-sha2-nistp521',
	'rsa-sha2-512,rsa-sha2-256'
];

const SESSION_RESETS_BACKOFF = 120;     // seconds a session must last before the backoff starts over
const BACKOFF_MAX = 60;
const LOG_MAX = 262144, LOG_KEEP = 65536;
const FORWARD_LINES = 40;
const PROBE_TIMEOUT_MS = 20000;
const SLEEP_FOREVER = 'exec sleep 2147483647';

function file(sid, what) {
	return `${RUN}/ssh.${sid}.${what}`;
}

function uptime() {
	return int(split(readfile('/proc/uptime') ?? '0', ' ')[0]);
}

function read_json(path) {
	let text = readfile(path);

	if (!text)
		return null;

	try {
		return json(text);
	}
	catch (e) {
		return null;
	}
}

function put(path, text) {
	let tmp = path + '.tmp';

	return writefile(tmp, text) != null && rename(tmp, path);
}

function shq(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

// At the Settings → Logs level (DESIGN.md 6.8): ssh-run and ssh-up run under procd and ssh, not after a
// converge, so step() and session_up() load the level the last converge left in RUN.
function syslog(prio, msg) {
	state.log((prio == 'err') ? 'error' : prio, msg);
}

function is_int(v, min, max) {
	return type(v) == 'int' && v >= min && v <= max;
}

function user_ok(u) {
	if (type(u) != 'string' || length(u) > 255 || !match(u, USER_RE))
		return false;

	for (let i = 0; i < length(USER_REFUSED); i++)
		if (index(u, substr(USER_REFUSED, i, 1)) >= 0)
			return false;

	return true;
}

function valid_server(s) {
	return type(s) == 'object' &&
		type(s.sid) == 'string' && match(s.sid, SERVER_SID) &&
		type(s.host) == 'string' && length(s.host) <= 253 && match(s.host, HOST_RE) &&
		user_ok(s.username) &&
		is_int(s.port, 1, 65535) && is_int(s.keepalive ?? 15, 5, 3600) &&
		(s.auth == 'password' || (s.auth == 'key' && type(s.key) == 'string' && match(s.key, KEY_SID))) &&
		(s.fingerprint == null || s.fingerprint == '' || match(s.fingerprint, FINGERPRINT_RE));
}

// argv(server, { server_ip, key_path }) -> the ssh command line of DESIGN §8.1, or null when a value
// would not be safe on it. Secrets never appear here: ssh-askpass reads them.
export function argv(server, ctx) {
	if (!valid_server(server) || type(ctx?.server_ip) != 'string' || !iptoarr(ctx.server_ip))
		return null;

	if (server.auth == 'key' && !match(ctx.key_path ?? '', /^\/[^[:space:]%]+$/))
		return null;

	let sid = server.sid, alias = 'shadow-' + sid;
	let args = [
		SSH, '-F', 'none', '-n', '-N', '-T', '-D', `127.0.0.1:${PORT_SSH}`,
		'-p', `${server.port}`, '-l', server.username,
		'-o', `HostName=${ctx.server_ip}`, '-o', `HostKeyAlias=${alias}`, '-o', 'StrictHostKeyChecking=yes',
		'-o', 'UserKnownHostsFile=/dev/null', '-o', 'GlobalKnownHostsFile=/dev/null',
		'-o', `KnownHostsCommand=${LIBEXEC}/ssh-hostkey %I %H %t %f %K`,
		'-o', 'CheckHostIP=no', '-o', 'UpdateHostKeys=no', '-o', 'BatchMode=no', '-o', 'NumberOfPasswordPrompts=1',
		'-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none'
	];

	if (server.auth == 'key')
		push(args, '-o', `IdentityFile=${ctx.key_path}`, '-o', 'PubkeyAuthentication=yes',
			'-o', 'PasswordAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
			'-o', 'PreferredAuthentications=publickey');
	else
		push(args, '-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password,keyboard-interactive');

	push(args,
		'-o', 'ExitOnForwardFailure=yes', '-o', `ServerAliveInterval=${server.keepalive ?? 15}`, '-o', 'ServerAliveCountMax=3',
		'-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1', '-o', `Ciphers=${CIPHERS}`,
		'-o', 'PermitLocalCommand=yes', '-o', `LocalCommand=${LIBEXEC}/ssh-up ${sid}`,
		'-o', 'ControlMaster=no', '-o', 'ControlPath=none', '-o', 'ForwardAgent=no', '-o', 'ForwardX11=no',
		'-o', 'WarnWeakCrypto=no-pq-kex', '-o', 'LogLevel=VERBOSE', '-E', file(sid, 'log'), '--', alias);

	return args;
};

// params(server) -> the non-secret content of RUN/ssh.<sid>.params (JSON), or null for a server
// that cannot be connected to. ssh-run reads only this file, so procd restarts the instance when
// it changes.
export function params(server) {
	if (!valid_server(server))
		return null;

	return sprintf('%J\n', {
		sid: server.sid, name: server.name ?? '', host: server.host, port: server.port,
		username: server.username, auth: server.auth, key: (server.auth == 'key') ? server.key : null,
		fingerprint: server.fingerprint ?? '', keepalive: server.keepalive ?? 15
	});
};

function load_params(sid) {
	let p = read_json(file(sid, 'params'));

	return (valid_server(p) && p.sid == sid) ? p : null;
}


// --- what an ssh -E log means ---------------------------------------------------------------------

function result(code, fatal, message) {
	return { code, fatal, message };
}

// host:port as the desktop prints a server (formatServiceTarget).
function service_target(server) {
	if (server?.host == null)
		return 'the server';

	let host = (index(server.host, ':') >= 0 && substr(server.host, 0, 1) != '[') ? `[${server.host}]` : server.host;

	return `${host}:${server.port ?? 22}`;
}

function hostkey_message(log, c) {
	let st = c.hostkey;

	if (index(log, 'KnownHostsCommand failed') >= 0)
		return 'SSH host key could not be checked because the host-key helper failed.';

	if (st?.kind == 'pin_mismatch')
		return `SSH server fingerprint mismatch: expected ${st.expected}, got ${st.got} (${st.type}).`;

	if (st?.kind == 'changed')
		return `SSH server host key does not match the key Shadow trusted on its first connection to ${service_target(c.server)}: ` +
			`expected ${st.expected}, got ${st.got} (${st.type}). Shadow stopped so nothing is sent to a server that may be an impostor. ` +
			"If the server's key was changed on purpose, paste the new fingerprint into the server's Fingerprint field.";

	return 'SSH host key verification failed.';
}

function key_message(reason) {
	if (match(reason, /incorrect passphrase/))
		return 'SSH authentication failed: Unable to load SSH private key because the passphrase is wrong.';

	if (match(reason, /bad permissions|UNPROTECTED/))
		return 'SSH authentication failed: Unable to load SSH private key because its file is readable by other users.';

	return 'SSH authentication failed: Unable to load SSH private key. Check the key format and passphrase.';
}

function offers(methods, auth) {
	let list = split(methods, ',');

	return (auth == 'key') ? ('publickey' in list) : ('password' in list || 'keyboard-interactive' in list);
}

// The server rejected the login. A rejection is fatal on the first connect and when it repeats
// during auto-reconnect (desktop 5.7.3); missing secrets and a wrong key passphrase always are.
function auth_result(c, methods) {
	let asked = c.asked, auth = c.server?.auth;

	if (asked?.missing && asked.kind == 'password')
		return result('auth', true, 'SSH password is unavailable.');

	if (asked?.missing && asked.kind == 'passphrase')
		return result('key', true, 'SSH authentication failed: Unable to load SSH private key because it is protected with a passphrase, and none was provided.');

	// ssh asks for an OpenSSH key's passphrase only after the server accepted its public part.
	if (asked?.kind == 'passphrase' && c.key_format == 'openssh')
		return result('key', true, 'SSH authentication failed: Unable to load SSH private key because the passphrase is wrong.');

	let fatal = !c.reconnecting || c.prev_code == 'auth';

	if (methods != null && auth && !offers(methods, auth))
		return result('auth', fatal, 'SSH authentication failed: no auth method available.');

	if (auth == 'key')
		return result('auth', fatal, (asked?.kind == 'passphrase')
			? 'SSH authentication failed: private-key auth rejected, or the key passphrase is wrong.'
			: 'SSH authentication failed: private-key auth rejected');

	if (auth == 'password')
		return result('auth', fatal, 'SSH authentication failed: password auth rejected');

	return result('auth', fatal, `SSH authentication failed: Permission denied (${methods ?? 'unknown'}).`);
}

function dns_message(host, reason) {
	if (reason == 'Try again' || match(reason, /^Temporary failure/))
		return `getaddrinfo EAI_AGAIN ${host}`;

	if (reason == 'Non-recoverable error')
		return `getaddrinfo EAI_FAIL ${host}`;

	return `getaddrinfo ENOTFOUND ${host}`;
}

function negotiate_result(what) {
	switch (what) {
	case 'host key type':
		return result('negotiate', true, 'No compatible SSH server host key algorithm.');
	case 'key exchange method':
		return result('negotiate', false, 'No compatible SSH kex algorithm.');
	case 'cipher':
		return result('negotiate', false, 'No compatible SSH client-to-server encryption algorithm.');
	case 'MAC':
		return result('negotiate', false, 'No compatible SSH client-to-server mac algorithm.');
	default:
		return result('negotiate', false, 'No compatible SSH client-to-server compression algorithm.');
	}
}

function last_line(log) {
	let lines = filter(split(log, '\n'), l => length(trim(l)) && !match(l, /^(Transferred|Bytes per second):/));
	let line = trim(lines[-1] ?? '');

	return (length(line) > 200) ? substr(line, 0, 200) + '…' : line;
}

// classify(log_text, ctx) -> { code, fatal, message } with the desktop's messages (spec §15.3).
// ctx: { reconnecting, prev_code, session, server, asked: { kind, missing }, hostkey, key_format };
// every field is optional.
export function classify(log_text, ctx) {
	let log = log_text ?? '', c = ctx ?? {}, m;
	let server = c.server;
	let authed = !!c.session || index(log, 'Authenticated to ') >= 0;

	if (match(log, /KnownHostsCommand failed|Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|host key is known for|Host key for .* has changed/s))
		return result('hostkey', true, hostkey_message(log, c));

	if (!authed) {
		if ((m = match(log, /Load key "[^"]*": (.*)$/s)))
			return result('key', true, key_message(m[1]));

		if (match(log, /UNPROTECTED PRIVATE KEY FILE/s))
			return result('key', true, key_message('UNPROTECTED'));

		if ((m = match(log, /Permission denied \(([^)]*)\)/s)))
			return auth_result(c, m[1]);

		if (match(log, /Too many authentication failures|^Authentication failed\./s))
			return auth_result(c, null);
	}

	if (match(log, /Could not request local forwarding|cannot listen to port|Address (already )?in use/s))
		return result('port_busy', false, `Local SOCKS port 127.0.0.1:${PORT_SSH} is already in use.`);

	if ((m = match(log, /Could not resolve hostname ([^:]*): (.*)$/s)))
		return result('dns', false, dns_message(server?.host ?? m[1], trim(m[2])));

	if (match(log, /Timeout, server .* not responding/s))
		return result('dead_link', false, `SSH keepalive timed out: nothing received from the server for ${(server?.keepalive ?? 15) * 3} s.`);

	if ((m = match(log, /connect to host ([^ ]*) port ([0-9]+): (.*)$/s))) {
		let addr = `${m[1]}:${m[2]}`, err = trim(m[3]);

		if (err == 'Connection refused')
			return result('refused', false, `connect ECONNREFUSED ${addr}`);

		if (match(err, /timed out/))
			return result('timeout', false, `SSH TCP connect timeout for ${server?.host ?? m[1]}:${server?.port ?? m[2]}.`);

		if (match(err, /^Network (is )?unreachable/))
			return result('unreachable', false, `connect ENETUNREACH ${addr}`);

		if (match(err, /^(Host is unreachable|No route to host)/))
			return result('unreachable', false, `connect EHOSTUNREACH ${addr}`);

		return result('unreachable', false, `connect to ${addr} failed: ${err}`);
	}

	if (match(log, /timed out during banner exchange/s))
		return result('timeout', false, 'Timed out waiting for SSH identification.');

	if (match(log, /Connection to [^ ]* port [0-9]+ timed out/s))
		return result('timeout', false, 'Timed out waiting for SSH packet.');

	if ((m = match(log, /Unable to negotiate with [^:]*: no matching (host key type|key exchange method|cipher|MAC|compression method) found/s)))
		return negotiate_result(m[1]);

	if (!authed && match(log, /kex_exchange_identification/s))
		return result('closed', false, 'Socket closed before SSH identification.');

	if (!authed && match(log, /Connection reset by/s))
		return result('closed', false, 'read ECONNRESET');

	if (authed)
		return result('dropped', false, 'SSH transport closed.');

	if (match(log, /Killed by signal/s))
		return result('closed', false, 'SSH transport closed.');

	if (match(log, /Connection closed by|Disconnected from|Received disconnect from|closed by remote host/s))
		return result('closed', false, 'SSH server disconnected.');

	let line = last_line(log);

	return result('unknown', false, length(line) ? `SSH exited: ${line}` : 'SSH exited without an error message.');
};


// --- run files --------------------------------------------------------------------------------------

// RUN/ssh.<sid>.state: { fails, attempt, session, prev, up_at, reset, gen }
//   fails    failed runs in a row, for the backoff
//   attempt  reconnect attempt being made (0 = the first connect)
//   session  a session was established since Connect (auth rejections then need two in a row)
//   prev     code of the previous failure
//   up_at    uptime when ssh-up saw the current session start
//   reset    job wan-up asked for the next attempt to start at once
//   gen      SHADOW_GEN of the instance; apply changes it on every Connect
//   launched ssh was exec'd and its run has not been classified yet
function read_state(sid) {
	let st = read_json(file(sid, 'state'));

	return {
		fresh: (st == null),
		fails: is_int(st?.fails, 0, 1000000) ? st.fails : 0,
		attempt: is_int(st?.attempt, 0, 1000000) ? st.attempt : 0,
		session: st?.session == true,
		prev: (type(st?.prev) == 'string') ? st.prev : null,
		up_at: (type(st?.up_at) == 'int') ? st.up_at : null,
		reset: st?.reset == true,
		gen: (type(st?.gen) == 'string') ? st.gen : '',
		launched: st?.launched == true
	};
}

function save_state(sid, st) {
	put(file(sid, 'state'), sprintf('%J\n', {
		fails: st.fails, attempt: st.attempt, session: st.session, prev: st.prev, up_at: st.up_at,
		reset: st.reset, gen: st.gen, launched: st.launched
	}));
}

function instance_gen() {
	return getenv('SHADOW_GEN') ?? '';
}

function read_asked(sid) {
	let m = match(trim(readfile(file(sid, 'askpass')) ?? ''), /^(password|passphrase)( missing)?$/);

	return m ? { kind: m[1], missing: m[2] != null } : null;
}

function read_hostkey_status(sid) {
	let m = match(trim(readfile(`${RUN}/hostkey.${sid}.status`) ?? ''), /^(changed|pin_mismatch) expected=([^ ]*) got=([^ ]*) type=([^ ]*)/);

	return m ? { kind: m[1], expected: m[2], got: m[3], type: m[4] } : null;
}

function key_format(server) {
	if (server?.auth != 'key')
		return null;

	let head = substr(readfile(secrets.path(server.key, 'key') ?? '/nonexistent') ?? '', 0, 40);

	if (substr(head, 0, 35) == '-----BEGIN OPENSSH PRIVATE KEY-----')
		return 'openssh';

	return match(head, /^-----BEGIN (RSA|EC) PRIVATE KEY-----/) ? 'pem' : 'pkcs8';
}

// context(sid) -> the classify() context of the server's current run, read from RUN.
export function context(sid) {
	let st = read_state(sid), server = load_params(sid);

	return {
		reconnecting: st.session, prev_code: st.prev, session: st.up_at != null, server,
		asked: read_asked(sid), hostkey: read_hostkey_status(sid), key_format: key_format(server)
	};
};

function trusted_fp(sid) {
	return split(trim(readfile(`${ETC}/trusted.${sid}`) ?? ''), /[ \t]+/)[1];
}

// state.write() stamps `since` when the phase changes. While xray is parked by a config error
// (RUN/xray.fatal) nothing the session carries gets through, so its error stays shown instead.
function publish(phase, server, attempt, message, code) {
	if (phase != 'error' && stat(`${RUN}/xray.fatal`)) {
		let a = filter(state.attention_list() ?? [], (x) => x.code == 'xray_config')[0];

		phase = 'error';
		message = a?.message ?? 'Xray rejected the configuration.';
		code = 'xray_config';
	}

	state.write({
		phase, attempt, message, code, transport: 'ssh',
		target: server ? { kind: 'ssh', name: server.name, addr: `${server.host}:${server.port}` } : null
	});
}

// The ssh lines go to the -E file; the Log tab reads logd, so pass the end of each run on. They reach logd
// only when the next run starts, maybe hours later and stamped with that time: each says so.
function forward_log(log) {
	let lines = filter(split(log, '\n'), l => length(trim(l)) && !match(l, /^(Transferred|Bytes per second):/));
	let p = length(lines) ? popen('logger -t ssh -p daemon.notice >/dev/null 2>&1', 'w') : null;

	if (p) {
		p.write(join('\n', map(slice(lines, -FORWARD_LINES), (l) => `[previous run] ${l}`)) + '\n');
		p.close();
	}
}

function backoff(fails) {
	return (fails <= 0) ? 0 : (fails > 6) ? BACKOFF_MAX : min(BACKOFF_MAX, 1 << (fails - 1));
}

// Stops retries until an explicit Connect removes RUN/fatal; the balancer already uses its fallback.
function give_up(sid, server, st, res) {
	let msg = (st.attempt > 0) ? `Reconnect attempt ${st.attempt} failed: ${res.message}` : res.message;
	let why = (res.code == 'hostkey') ? 'Reconnect stopped because SSH host trust or credentials require user action.'
		: 'Reconnect stopped. Update the SSH configuration or key, then connect again.';

	put(`${RUN}/fatal`, sprintf('%J\n', { transport: 'ssh', sid, code: res.code, message: msg, at: time() }));
	put(file(sid, 'last'), sprintf('%J\n', { code: res.code, fatal: true, message: res.message, at: time() }));
	state.attention_add('ssh_fatal', msg, { sid, code: res.code });
	publish('error', server, st.attempt, msg, res.code);
	unlink(file(sid, 'state'));
	syslog('err', `ssh: ${msg} ${why}`);

	return SLEEP_FOREVER;
}


// --- ssh-run ------------------------------------------------------------------------------------

// plan(sid) -> 'fatal' or the seconds to wait before launch (DESIGN §8.2 steps 1-3).
export function plan(sid) {
	if (type(sid) != 'string' || !match(sid, SERVER_SID)) {
		syslog('err', 'ssh-run: invalid server id');
		return 'fatal';
	}

	mkdir(RUN, 0o700);

	if (stat(`${RUN}/fatal`)) {
		let f = read_json(`${RUN}/fatal`);

		publish('error', load_params(sid), 0, f?.message ?? 'SSH stopped after an error.', f?.code ?? null);
		return 'fatal';
	}

	let log = readfile(file(sid, 'log')) ?? '';
	let st = read_state(sid);

	// A Connect restarts the instance with a new generation: what the old series left is history.
	if (!st.fresh && st.gen != instance_gen()) {
		syslog('debug', `ssh: ${sid} starts a new generation (Connect or a changed server); the last run is not classified`);
		forward_log(log);
		writefile(file(sid, 'log'), '');
		unlink(file(sid, 'state'));
		return '0';
	}

	// Nothing to classify unless ssh ran: one that died before it wrote anything (launch() sends its
	// stderr to the log as well) is a failed run all the same, or procd would start it again every 2 s
	// without a backoff.
	if (!length(trim(log)) && !st.launched) {
		syslog('debug', `ssh: ${sid} has no run to classify; launching`);
		return '0';
	}

	let server = load_params(sid);
	let res = classify(log, context(sid));

	forward_log(log);
	writefile(file(sid, 'log'), '');
	put(file(sid, 'last'), sprintf('%J\n', { ...res, at: time() }));

	if (res.fatal) {
		give_up(sid, server, st, res);
		return 'fatal';
	}

	// Without a state file the log still shows whether a session ran: job wan-up removing the
	// file is a reset like reset_backoff().
	let lost_state = st.fresh && index(log, 'Authenticated to ') >= 0;
	let had_session = (st.up_at != null) || lost_state;
	let long_session = (st.up_at != null) && uptime() - st.up_at >= SESSION_RESETS_BACKOFF;

	st.fails = (long_session || st.reset || lost_state) ? 0 : st.fails + 1;
	st.session = st.session || had_session;
	st.prev = res.code;
	st.up_at = null;
	st.reset = false;
	st.launched = false;
	st.gen = instance_gen();
	save_state(sid, st);

	let delay = backoff(st.fails);
	let msg = had_session ? `SSH session lost (${res.message}); reconnecting.`
		: (st.attempt > 0) ? `Reconnect attempt ${st.attempt} failed: ${res.message}` : res.message;

	publish('reconnecting', server, st.attempt, msg, res.code);
	syslog('warning', `ssh: ${res.message} Reconnecting ${delay ? `in ${delay} s` : 'now'}.`);
	syslog('debug', sprintf('ssh: %s classified as %s, %d failure(s) in a row%s', sid, res.code ?? 'unknown', st.fails,
		had_session ? ', after a session' : ''));

	return `${delay}`;
};

// The one address ssh will use, through the router's resolver (dnsmasq sends the server's name to
// the normal upstream, never into the tunnel). IPv4 first, asked on its own: a lookup of both
// families fails as a whole when the upstream mishandles AAAA.
function resolve(host) {
	let literal = replace(host, /^\[(.*)\]$/, '$1');

	if (iptoarr(literal))
		return { ip: literal };

	let socket = require('socket'), err = null;

	for (let family in [ socket.AF_INET, socket.AF_INET6 ]) {
		let res = socket.addrinfo(host, null, { family, socktype: socket.SOCK_STREAM });
		let ip = res?.[0]?.addr?.address;

		if (ip)
			return { ip };

		err ??= socket.error(true);
	}

	return { error: socket.strerror(err ?? -2) };
}

// Exactly that address in @server4/6, so ssh's own connection always goes direct (DESIGN §7.2 step 1).
function set_server_addr(sid, ip) {
	let set = (index(ip, ':') >= 0) ? 'server6' : 'server4', path = file(sid, 'nft');

	writefile(path, `flush set inet ${NFT_TABLE} server4\nflush set inet ${NFT_TABLE} server6\n` +
		`add element inet ${NFT_TABLE} ${set} { ${ip} }\n`);

	let p = popen(`nft -f ${path} 2>&1`, 'r');
	let out = p ? (p.read('all') ?? '') : '';
	let rc = p ? p.close() : -1;

	unlink(path);

	// No table yet means nothing is diverted, so there is no loop to avoid.
	if (rc != 0 && index(out, 'No such file or directory') < 0)
		syslog('warning', `ssh: cannot put ${ip} into the server sets: ${trim(out)}`);

	put(file(sid, 'addr'), ip + '\n');
}

function render_pin(sid, fingerprint) {
	if (fingerprint)
		put(`${RUN}/pin.${sid}`, fingerprint + '\n');
	else
		unlink(`${RUN}/pin.${sid}`);
}

function probe_argv(server, ip, algs, log) {
	return [
		SSH, '-F', 'none', '-n', '-N', '-T', '-p', `${server.port}`, '-l', server.username,
		'-o', `HostName=${ip}`, '-o', `HostKeyAlias=shadow-${server.sid}`, '-o', `HostKeyAlgorithms=${algs}`,
		'-o', 'StrictHostKeyChecking=yes', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'GlobalKnownHostsFile=/dev/null',
		'-o', `KnownHostsCommand=${LIBEXEC}/ssh-hostkey %I %H %t %f %K probe`,
		'-o', 'CheckHostIP=no', '-o', 'UpdateHostKeys=no', '-o', 'BatchMode=yes',
		'-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1', '-o', 'LogLevel=ERROR', '-E', log, '--', `shadow-${server.sid}`
	];
}

// A pinned key of a type ssh does not prefer would be refused before ssh ever saw the pinned one.
// Ask the server for each key type in turn, stopping right after key exchange (the helper trusts
// nothing in probe mode, so no login happens); ssh-hostkey stores the key that matches the pin.
function find_pinned_key(server, ip) {
	let sid = server.sid, pin = server.fingerprint;
	let seen_path = `${RUN}/hostkey.${sid}.seen`, plog = file(sid, 'probe');
	let seen = [], text = '';

	for (let algs in HOSTKEY_FAMILIES) {
		unlink(seen_path);
		writefile(plog, '');
		system(sprintf('exec %s </dev/null >/dev/null 2>&1', join(' ', map(probe_argv(server, ip, algs, plog), shq))), PROBE_TIMEOUT_MS);

		let key = split(trim(readfile(seen_path) ?? ''), ' ');

		text = readfile(plog) ?? '';

		if (length(key) >= 2 && match(key[1], FINGERPRINT_RE)) {
			if (trusted_fp(sid) == pin) {
				unlink(plog);
				return {};
			}

			push(seen, key);
			continue;
		}

		if (index(text, 'Unable to negotiate') >= 0)
			continue;

		// The server was not reached: an ordinary failed run, retried with the backoff.
		writefile(file(sid, 'log'), text);
		unlink(plog);
		return { retry: true };
	}

	unlink(plog);

	if (!length(seen)) {
		// It offered none of the types; classified as a host-key negotiation failure.
		writefile(file(sid, 'log'), text);
		return { retry: true };
	}

	put(`${RUN}/hostkey.${sid}.status`, `pin_mismatch expected=${pin} got=${seen[0][1]} type=${seen[0][0]}\n`);

	return { mismatch: `SSH server fingerprint mismatch: expected ${pin}, got ${join(', ', map(seen, k => `${k[1]} (${k[0]})`))}.` };
}

// launch(sid) -> the shell line that execs ssh, the line that sleeps after a fatal problem, or null
// to let procd run ssh-run again (the run's failure is in the log by then). DESIGN §8.2 steps 4-5.
export function launch(sid) {
	if (type(sid) != 'string' || !match(sid, SERVER_SID))
		return SLEEP_FOREVER;

	let st = read_state(sid), server = load_params(sid);

	// A converge that switched servers removes the old params only once RUN/ssh.sid names the new one
	// (apply move_into_place), and its declaration replaces this instance next: nothing failed here.
	if (!server && trim(readfile(`${RUN}/ssh.sid`) ?? '') != sid)
		return SLEEP_FOREVER;

	if (!server)
		return give_up(sid, null, st, result('config', true, 'SSH server settings are missing.'));

	let key_path = null;

	if (server.auth == 'key') {
		key_path = secrets.path(server.key, 'key');

		if (!key_path || !stat(key_path))
			return give_up(sid, server, st, result('key', true, 'SSH private key is unavailable.'));
	}
	else if (!stat(secrets.path(sid, 'password') ?? '/nonexistent')) {
		return give_up(sid, server, st, result('auth', true, 'SSH password is unavailable.'));
	}

	st.attempt = st.fresh ? 0 : st.attempt + 1;
	st.gen = instance_gen();
	save_state(sid, st);
	publish(st.attempt ? 'reconnecting' : 'connecting', server, st.attempt,
		st.attempt ? `Reconnecting to ${server.host}:${server.port} (attempt ${st.attempt}).` : `Connecting to ${server.host}:${server.port}.`, null);

	render_pin(sid, server.fingerprint);
	writefile(file(sid, 'log'), '');
	unlink(file(sid, 'askpass'));
	unlink(`${RUN}/hostkey.${sid}.status`);

	let addr = resolve(server.host);

	if (!addr.ip) {
		writefile(file(sid, 'log'), `ssh: Could not resolve hostname ${server.host}: ${addr.error}\n`);
		return null;
	}

	set_server_addr(sid, addr.ip);

	if (server.fingerprint && trusted_fp(sid) != server.fingerprint) {
		let found = find_pinned_key(server, addr.ip);

		if (found.retry)
			return null;

		if (found.mismatch)
			return give_up(sid, server, st, result('hostkey', true, found.mismatch));
	}

	let args = argv(server, { server_ip: addr.ip, key_path });

	if (!args)
		return give_up(sid, server, st, result('config', true, 'SSH server settings are invalid.'));

	writefile(file(sid, 'log'), '');

	// plan() classifies this run even when its log stays empty
	st.launched = true;
	save_state(sid, st);
	syslog('debug', sprintf('ssh: %s launches to %s port %s (%s, attempt %d)', sid, addr.ip, server.port,
		(server.host == addr.ip) ? 'an address' : `resolved from ${server.host}`, st.attempt));

	// stderr goes to the log too: ssh reports some errors (a user name it refuses) before -E applies
	return sprintf('export SSH_ASKPASS=%s SSH_ASKPASS_REQUIRE=force SHADOW_ID=%s; unset DISPLAY; exec %s 2>>%s',
		shq(`${LIBEXEC}/ssh-askpass`), sid, join(' ', map(args, shq)), shq(file(sid, 'log')));
};

// step(name, sid) -> exit code for ssh-run. The answer goes to fd 3, so nothing that a module or a
// child process prints can end up in the line ssh-run evaluates.
export function step(name, sid) {
	state.load_log_level();

	let out = (name == 'plan') ? plan(sid) : (name == 'launch') ? launch(sid) : null;

	if (out == null)
		return 1;

	let fd = fdopen(3, 'w');

	if (!fd)
		return 1;

	fd.write(out + '\n');
	fd.close();

	return 0;
};

// session(sid) -> { up, up_at }: whether ssh-up saw the current run's session start (uptime seconds).
export function session(sid) {
	if (type(sid) != 'string' || !match(sid, SERVER_SID))
		return { up: false, up_at: null };

	let st = read_state(sid);

	return { up: st.up_at != null, up_at: st.up_at };
};

// job wan-up: whether the ssh run has to start over. A session that began after the link it runs over
// came up (link_age: seconds that interface has been up, null when unknown) already uses that link, so
// a second ifup (wan6 seconds after wan) leaves it alone; one that is older may hang on a dead path.
export function session_stale(sid, link_age) {
	let s = session(sid);

	if (!s.up || type(link_age) != 'int')
		return true;

	return uptime() - s.up_at > link_age;
};

// job wan-up: the next attempt starts at once instead of waiting out the backoff.
export function reset_backoff(sid) {
	if (type(sid) != 'string' || !match(sid, SERVER_SID) || !stat(file(sid, 'state')))
		return false;

	let st = read_state(sid);

	st.fails = 0;
	st.reset = true;
	save_state(sid, st);

	return true;
};


// --- ssh-up -------------------------------------------------------------------------------------

// LocalCommand: ssh serves nothing until it returns, so only record the session and detach the rest.
export function session_up(sid) {
	if (type(sid) != 'string' || !match(sid, SERVER_SID))
		return false;

	state.load_log_level();

	let st = read_state(sid), server = load_params(sid);

	st.up_at = uptime();
	st.session = true;
	st.prev = null;
	st.attempt = 0;
	save_state(sid, st);
	publish('connected', server, 0, `Connected to ${server?.name || server?.host || sid}.`, null);
	// the session's own "Authenticated to" stays in the -E file until the next run forwards it
	syslog('debug', sprintf('ssh: %s session up to %s', sid, trim(readfile(file(sid, 'addr')) ?? '') || server?.host || '?'));
	// the fatal stop it reported is over once a session runs again (DESIGN §6.6: until the cause is gone)
	state.attention_clear('ssh_fatal');

	if (stat(`${LIBEXEC}/gate-set`))
		system([ `${LIBEXEC}/gate-set` ]);

	if (stat(`${LIBEXEC}/ssh-up`))
		system([ 'start-stop-daemon', '-S', '-b', '-x', `${LIBEXEC}/ssh-up`, '--', sid, 'detached' ]);

	return true;
};

// ssh opens its -E file with O_APPEND, so cutting it from outside is safe.
export function cap_log(sid) {
	let path = file(sid, 'log'), size = stat(path)?.size ?? 0;

	if (size <= LOG_MAX)
		return false;

	let f = open(path, 'r');

	if (!f)
		return false;

	f.seek(size - LOG_KEEP);

	let tail = f.read(LOG_KEEP) ?? '';

	f.close();
	writefile(path, substr(tail, index(tail, '\n') + 1));

	return true;
};

// Runs detached from ssh-up: the work that may take a while once the tunnel serves.
export function after_up(sid) {
	if (type(sid) != 'string' || !match(sid, SERVER_SID))
		return false;

	cap_log(sid);

	let ctx = require('uci').cursor();

	if (ctx.get(UCI, 'main', 'check_after_connect') != '0' && stat(`${LIBEXEC}/job`)) {
		// ssh serves only after ssh-up has exited; let it enter its loop, so the check's
		// latency is the tunnel's and not ssh's start.
		sleep(1000);
		system([ `${LIBEXEC}/job`, 'check' ]);
	}

	return true;
};
