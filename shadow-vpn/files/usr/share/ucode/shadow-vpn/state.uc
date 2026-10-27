'use strict';

import { open, rename, unlink, mkdir, readfile, glob, stat, access } from 'fs';
import { RUN, PORT_METRICS, LOG_TAG } from 'shadow-vpn.const';

const STATE = `${RUN}/state.json`, ATTENTION = `${RUN}/attention.json`, JOBS = `${RUN}/jobs`;
const PHASES = [ 'disconnected', 'connecting', 'connected', 'reconnecting', 'error' ];
const JOB_ID = /^[A-Za-z0-9_-]{1,64}$/;
const JOBS_KEPT = 20;
const METRICS_MAX = 1048576, HTTP_OK = /^HTTP\/1\.[01] 200 /;
const PRIORITY = { error: 'daemon.err', warning: 'daemon.warn', info: 'daemon.info', debug: 'daemon.debug' };
const SEVERITY = { error: 3, warning: 2, info: 1, debug: 0 };

let log_threshold = SEVERITY.warning;

function mkdir_p(path, mode) {
	let parts = split(path, '/'), cur = '';

	for (let i = 1; i < length(parts); i++) {
		cur += '/' + parts[i];

		if (parts[i] != '')
			mkdir(cur, (i == length(parts) - 1) ? (mode ?? 0o755) : 0o755);
	}
}

// /var/run is a link into /tmp that procd creates at boot; outside a booted system it may be missing.
function ensure_run() {
	if (!access(RUN))
		mkdir_p(RUN, 0o700);
}

function read_json(path) {
	let text = readfile(path);

	if (text == null)
		return null;

	try {
		return json(text);
	}
	catch (e) {
		return null;
	}
}

// tmp + rename, so readers (rpcd status) never parse a half-written file.
function write_json(path, value) {
	ensure_run();

	let c = clock(true), tmp = sprintf('%s.%d%d', path, c[0], c[1]);
	let f = open(tmp, 'wx', 0o600);

	if (!f)
		return false;

	let data = sprintf('%J\n', value);
	let ok = f.write(data) == length(data);

	f.close();

	if (!ok || !rename(tmp, path)) {
		unlink(tmp);
		return false;
	}

	return true;
}

function with_lock(name, fn) {
	ensure_run();

	let f = open(`${RUN}/${name}.lock`, 'ae', 0o600);

	if (f)
		f.lock('x');

	let result = fn();

	if (f)
		f.close();

	return result;
}

// Desktop redactSecrets, plus the places where xray -test echoes a malformed credential.
function redact(text) {
	if (type(text) != 'string')
		return text;

	text = replace(text, /"([A-Za-z0-9_-]*password|auth)"[ \t]*:[ \t]*"([^"\\]|\\.)*"/gi, '"$1":"<redacted>"');
	text = replace(text, /([a-z0-9+.-]:\/\/)[^ \t\r\n\/?#@]+@/gi, '$1<redacted>@');
	text = replace(text, /(password|passphrase|private key|proxy uri|uri)[ \t]*[:=][ \t]*[^ \t\r\n]+/gi, '$1=<redacted>');
	text = replace(text, /(invalid UUID:|invalid "password":|"shortId":|shortId:|invalid short ?[Ii][Dd]:?)[^\r\n]*/g, '$1 <redacted>');

	return text;
}

// Settings → Logs (main.log_level, DESIGN.md 6.8); anything unknown counts as the default, warning.
function set_log_level(level) {
	log_threshold = SEVERITY[level] ?? SEVERITY.warning;
}

// Helpers that do not converge take the level the last converge validated (RUN/log_level): a file read
// instead of a UCI parse, as some of them run inside ssh's LocalCommand or fw4's lock.
function load_log_level() {
	set_log_level(trim(readfile(`${RUN}/log_level`) ?? ''));
}

// Whether log(level, …) would write: callers skip building a debug line nobody will see.
function log_on(level) {
	return (SEVERITY[level] ?? SEVERITY.error) >= log_threshold;
}

function log(level, message) {
	if (!log_on(level))
		return;

	system([ 'logger', '-t', LOG_TAG, '-p', PRIORITY[level] ?? PRIORITY.error, redact(message) ]);
}

function default_state() {
	return { phase: 'disconnected', since: 0, since_up: null, attempt: 0, message: '', code: null, transport: null, target: null };
}

// Seconds since boot: unlike time(), NTP never steps it. A router without a battery clock starts with the
// time of its newest file in /etc, and sysntpd runs after Shadow (S98), so `since` alone can be days off.
function uptime() {
	return int(split(readfile('/proc/uptime') ?? '0', ' ')[0]);
}

function read() {
	let s = read_json(STATE);

	return (type(s) == 'object') ? { ...default_state(), ...s } : default_state();
}

// Merges `patch` into state.json. A phase change stamps `since` (and `since_up`, the same moment on the
// uptime clock, which status turns into the age LuCI shows) unless the patch sets it, and is logged at
// info: every writer (apply, xray-run, ssh-run, ssh-up) goes through here.
function write(patch) {
	let changed = null;
	let res = with_lock('state', () => {
		let s = read();

		if (patch?.phase != null && index(PHASES, patch.phase) < 0)
			die(`invalid phase ${patch.phase}`);

		let next = { ...s, ...patch };

		if (patch?.phase != null && patch.phase != s.phase) {
			changed = s.phase;

			if (patch.since == null) {
				next.since = time();
				next.since_up = uptime();
			}
		}

		write_json(STATE, next);

		return next;
	});

	// after the lock: logger forks, and the next writer should not wait for it
	if (changed != null)
		log('info', `phase: ${changed} -> ${res.phase}${length(res.message ?? '') ? ` (${res.message})` : ''}`);

	return res;
}

function attention_list() {
	let a = read_json(ATTENTION);

	return (type(a) == 'array') ? a : [];
}

// One entry per code (per code and extra.key when given); a repeat refreshes the text and time.
function attention_add(code, message, extra) {
	let id = (extra?.key != null) ? `${code}:${extra.key}` : code;

	return with_lock('attention', () => {
		let list = filter(attention_list(), (e) => e.id != id);
		let entry = { id, code, message, since: time() };

		if (extra != null)
			entry.extra = extra;

		push(list, entry);
		write_json(ATTENTION, list);

		return entry;
	});
}

function attention_dismiss(id) {
	return with_lock('attention', () => {
		let list = attention_list();
		let kept = filter(list, (e) => e.id != id);

		if (length(kept) != length(list))
			write_json(ATTENTION, kept);

		return length(kept) != length(list);
	});
}

// Drops every entry of a code once its cause is gone (e.g. nothing_to_route after a rule was added).
function attention_clear(code) {
	return with_lock('attention', () => {
		let list = attention_list();
		let kept = filter(list, (e) => e.code != code);

		if (length(kept) != length(list))
			write_json(ATTENTION, kept);
	});
}

function valid_job_id(id) {
	return type(id) == 'string' && match(id, JOB_ID) != null;
}

function job_read(id) {
	if (!valid_job_id(id))
		return null;

	return read_json(`${JOBS}/${id}.json`);
}

function prune_jobs() {
	let files = glob(`${JOBS}/*.json`) ?? [];

	if (length(files) <= JOBS_KEPT)
		return;

	files = sort(files, (a, b) => (stat(a)?.mtime ?? 0) - (stat(b)?.mtime ?? 0));

	for (let i = 0; i < length(files) - JOBS_KEPT; i++)
		unlink(files[i]);
}

function job_write(id, patch) {
	if (!valid_job_id(id))
		return null;

	ensure_run();
	mkdir(JOBS, 0o700);

	let job = job_read(id) ?? { id, name: null, state: 'running', started: time(), finished: null, result: {} };

	job = { ...job, ...patch, id };

	if (job.state != 'running' && job.finished == null)
		job.finished = time();

	write_json(`${JOBS}/${id}.json`, job);

	if (patch?.state == 'running')
		prune_jobs();

	return job;
}

// The reason in xray's "Failed to start: ..." line (else its last line), redacted and cut from the
// front as the desktop does; null when xray printed nothing.
function xray_failure(output) {
	let reason = null;

	for (let line in split(output ?? '', '\n')) {
		line = trim(line);

		if (match(line, /^Failed to start:/))
			reason = trim(replace(replace(line, /^Failed to start:[ \t]*/, ''),
				/^main: failed to load config files: \[[^\]]*\][ \t]*>[ \t]*/, ''));
	}

	if (reason == null) {
		// explicit lambdas: map() and filter() pass the index too, which trim() would take as its charset
		let lines = filter(map(split(output ?? '', '\n'), (l) => trim(l)), (l) => l != '');

		reason = lines[length(lines) - 1];
	}

	if (reason == null || reason == '')
		return null;

	reason = redact(reason);

	return (length(reason) > 400) ? '…' + substr(reason, -400) : reason;
}

function now_ms() {
	let c = clock(true);

	return c[0] * 1000 + c[1] / 1000000;
}

// GET /debug/vars of xray's metrics listener; null when xray does not answer within the deadline.
// A socket instead of uclient-fetch: LuCI polls status every 5 s and a fork per poll adds up.
function metrics_vars(timeout_ms) {
	let socket = require('socket');
	let s = socket.connect('127.0.0.1', PORT_METRICS, null, timeout_ms);

	if (!s)
		return null;

	s.send('GET /debug/vars HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n');

	let deadline = now_ms() + timeout_ms, buf = '';

	while (length(buf) < METRICS_MAX) {
		let left = int(deadline - now_ms());
		let ev = (left > 0) ? socket.poll(left, [ s, socket.POLLIN ]) : null;

		if (!ev || !length(ev) || !ev[0][1])
			break;

		let chunk = s.recv(65536);

		if (chunk == null || chunk == '')
			break;

		buf += chunk;
	}

	s.close();

	let body = index(buf, '\r\n\r\n');

	if (body < 0 || !match(buf, HTTP_OK))
		return null;

	try {
		return json(substr(buf, body + 4));
	}
	catch (e) {
		return null;
	}
}

// Tunnel health as xray's own observatory sees it (DESIGN.md 6.6): alive is null while xray is not
// answering or has not probed yet; fallback is what the balancer uses while the tunnel is dead.
// answered and probed tell those two apart: the updater counts a silent xray as down but waits for a probe.
function tunnel_health(timeout_ms) {
	let fallback = trim(readfile(`${RUN}/fallback`) ?? '') || null;
	let vars = metrics_vars(timeout_ms ?? 800);
	let proxy = vars?.observatory?.proxy;

	if (type(proxy) != 'object')
		return { alive: null, fallback, delay_ms: null, answered: vars != null, probed: false };

	// protobuf JSON omits false and zero values
	let alive = proxy.alive === true;

	return { alive, fallback, delay_ms: (alive && proxy.delay != null) ? int(proxy.delay) : null, answered: true, probed: true };
}

export {
	read, write, attention_add, attention_dismiss, attention_list, attention_clear,
	job_write, job_read, valid_job_id, redact, xray_failure, set_log_level, load_log_level, log_on, log, tunnel_health,
	read_json, write_json, ensure_run, mkdir_p, uptime
};
