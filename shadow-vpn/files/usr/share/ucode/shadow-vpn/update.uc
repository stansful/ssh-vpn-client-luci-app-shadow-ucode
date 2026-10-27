'use strict';

// Updates from GitHub releases (DESIGN.md 11, CONTRACTS §8): install.sh's upgrade path moved onto the router,
// plus the hourly `due` that checks and, in automatic mode, installs at night. Files come only from the tag of
// the release just checked and are verified against its SHA256SUMS. Every command and every system path comes
// from opts (production defaults), so the tests run all of it against stubs.

import * as fs from 'fs';
import { sha256_file } from 'digest';
import { cursor } from 'uci';
import { UCI, RUN, LIBEXEC, APK_DB, UPDATE } from 'shadow-vpn.const';
import * as config from 'shadow-vpn.config';
import * as state from 'shadow-vpn.state';

const NO_RELEASE_MESSAGE = 'No Shadow release is published yet.';
const RATE_LIMIT_MESSAGE = 'GitHub refused the request: too many requests from this address. Try again in an hour.';
const UNREACHABLE_MESSAGE = 'Could not reach GitHub to check for updates.';
const UNREADABLE_MESSAGE = 'GitHub returned a release that Shadow cannot read.';
const BUSY_CHECK_MESSAGE = 'Shadow is already checking for or installing an update. Try again in a minute.';
const BUSY_INSTALL_MESSAGE = 'An update is already running.';
const LOCK_MESSAGE = 'Could not take the update lock.';
const CLOCK_MESSAGE = 'The router clock is wrong, so HTTPS does not work. Check time synchronization in System → System.';
const UNKNOWN_VERSION_MESSAGE = 'The installed Shadow version is unknown.';
const SPACE_MESSAGE = 'Not enough space on the router: %d MB free, %d MB needed.';
const MEMORY_MESSAGE = 'Not enough free memory: %d MB available, %d MB needed.';
const BLOCKED_MESSAGE = 'Shadow blocks the router’s own downloads while its tunnel is down (kill switch). Turn Shadow off, update, then turn it back on.';
const KILL_HINT_MESSAGE = '%s The tunnel is down, and Shadow’s kill switch may be what blocks the download.';
const DOWNLOAD_MESSAGE = 'Could not download %s from GitHub.';
const NO_FILE_MESSAGE = 'The latest release has no %s.';
const SUMS_MALFORMED_MESSAGE = 'SHA256SUMS is malformed.';
const SUMS_ENTRY_MESSAGE = 'SHA256SUMS has no entry for %s.';
const CHECKSUM_MESSAGE = 'The checksum of %s does not match SHA256SUMS: the file is damaged or was replaced.';
const SIZE_MESSAGE = 'The size of %s does not match the release.';
const DIGEST_MESSAGE = 'GitHub lists another checksum for %s than SHA256SUMS.';
const CONSOLE_MESSAGE = 'Shadow %s must be installed with the install command from the console.';
const APK_FAILED_MESSAGE = 'The package manager could not install the update: %s';
const NOT_INSTALLED_MESSAGE = 'The package manager did not install Shadow %s.';
const SETTLE_MESSAGE = 'Shadow %s was installed, but the tunnel did not come back within %d s.';
const ROLLED_BACK_MESSAGE = 'Shadow %s was installed, but the tunnel did not come back, so Shadow %s was put back.';
const ROLLBACK_FAILED_MESSAGE = 'Shadow %s was installed, but the tunnel did not come back, and putting Shadow %s back failed: %s';
const ROLLBACK_MISSING_MESSAGE = 'The packages of the installed Shadow %s could not be downloaded for a rollback, so it was not updated automatically.';
const AVAILABLE_MESSAGE = 'Shadow %s is available.';
const AUTO_FAILED_MESSAGE = 'The automatic update to %s failed: %s';
const INTERRUPTED_MESSAGE = 'The automatic update to %s was interrupted.';

// scripts/lib/version.sh: no leading zeros; vX.Y.Z is how the first release workflow named its tags
const VERSION_RE = /^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
const PKG_VERSION_RE = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-r[0-9]+$/;
const NAME_RE = /^[A-Za-z0-9._+-]+$/;
const SUM_LINE = /^([0-9a-f]{64})  ([A-Za-z0-9._+-]+)$/;
const DIGEST_RE = /^sha256:[0-9a-f]{64}$/;
const URL_RE = /^https?:\/\/[-A-Za-z0-9.:_~%\/]+$/;
const BASE_RE = /^https?:\/\/[A-Za-z0-9.:_~%\/-]+$/;
const ISO_RE = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?Z$/;
const CONSOLE_RE = /(^|\n)shadow-update: console(\n|$)/;
const ACCEPT_JSON = 'Accept: application/vnd.github+json', ACCEPT_FILE = 'Accept: application/octet-stream';
const APK_LOG_LINES = 20, APK_REASON_MAX = 300;

// UPDATE.state as rpcd reads it; fields of an older or newer writer are kept as they are
const STATE_DEFAULT = { checked: null, checked_up: null, ok: null, error: null, installed: null, latest: null, tag: null,
	url: null, published: null, notes: null, console: false, announced: null, last: null };

function q(s) {
	return "'" + replace(`${s}`, "'", "'\\''") + "'";
}

function starts(s, prefix) {
	return type(s) == 'string' && substr(s, 0, length(prefix)) == prefix;
}

function now_ms() {
	let c = clock(true);

	return c[0] * 1000 + c[1] / 1000000;
}

// 'X.Y.Z', 'vX.Y.Z' or apk's 'X.Y.Z-rN' -> [ x, y, z ]; null for anything else. At most 9 digits a part,
// so the numbers stay exact.
export function parse_version(s) {
	let m = (type(s) == 'string') ? (match(s, VERSION_RE) ?? match(s, PKG_VERSION_RE)) : null;

	if (!m || length(m[1]) > 9 || length(m[2]) > 9 || length(m[3]) > 9)
		return null;

	return [ int(m[1]), int(m[2]), int(m[3]) ];
};

// -1, 0 or 1 for a < b, a = b, a > b; null when either is not a version.
export function compare(a, b) {
	let x = parse_version(a), y = parse_version(b);

	if (!x || !y)
		return null;

	for (let i = 0; i < 3; i++)
		if (x[i] != y[i])
			return (x[i] > y[i]) ? 1 : -1;

	return 0;
};

function plain(v) {
	let p = parse_version(v);

	return p ? join('.', p) : null;
}

// Shadow's packages in apk's database: version is shadow-vpn's X.Y.Z, packages every one of them with its apk
// version (the LuCI app and its translations too, whatever their names grow into).
export function installed(opts) {
	let f = fs.open(opts?.db ?? APK_DB, 'r');
	let packages = {}, name = null;

	if (f) {
		for (let line = f.read('line'); length(line); line = f.read('line')) {
			let tag = substr(line, 0, 2);

			if (tag == 'P:') {
				name = trim(substr(line, 2));
			}
			else if (tag == 'V:' && name != null) {
				if (name == 'shadow-vpn' || starts(name, 'luci-app-shadow-vpn') || starts(name, 'luci-i18n-shadow-vpn-'))
					packages[name] = trim(substr(line, 2));

				name = null;
			}
		}

		f.close();
	}

	return { version: plain(packages['shadow-vpn']), packages };
};

// ISO 8601 UTC as GitHub writes published_at -> epoch seconds, else null.
function epoch(iso) {
	let m = (type(iso) == 'string') ? match(iso, ISO_RE) : null;

	if (!m || int(m[2]) < 1 || int(m[2]) > 12 || int(m[3]) < 1 || int(m[3]) > 31 || int(m[4]) > 23 || int(m[5]) > 59 ||
	    int(m[6]) > 60)
		return null;

	return timegm({ year: int(m[1]), mon: int(m[2]), mday: int(m[3]), hour: int(m[4]), min: int(m[5]), sec: int(m[6]) });
}

// A cut inside a UTF-8 sequence would leave half a character: drop it.
function utf8_head(s) {
	let n = length(s);

	for (let i = n - 1; i >= 0 && i >= n - 4; i--) {
		let c = ord(s, i);

		if (c < 0x80)
			return s;

		if (c >= 0xc0)
			return (n - i >= ((c >= 0xf0) ? 4 : (c >= 0xe0) ? 3 : 2)) ? s : substr(s, 0, i);
	}

	return s;
}

// The release notes LuCI shows: cut to notes_max at the end of a line.
function notes(body) {
	let text = trim(body);

	if (length(text) > UPDATE.notes_max) {
		let head = substr(text, 0, UPDATE.notes_max), nl = rindex(head, '\n');

		text = rtrim((nl > 0) ? substr(head, 0, nl) : utf8_head(head));
	}

	return (text != '') ? text : null;
}

function asset_url(url) {
	return starts(url, UPDATE.asset_api) && match(substr(url, length(UPDATE.asset_api)), /^[0-9]+$/) != null;
}

// GitHub's release JSON (under a base URL: the lab's copy of it) -> what the updater uses, or { error }. Only
// what passes the checks is kept: the page link only on GitHub's release pages, asset URLs only of GitHub's
// asset API (under a base URL every file comes from the base, so none is used), digests only as sha256.
export function release_info(text, base) {
	if (type(text) != 'string' || length(text) > UPDATE.json_max)
		return { error: UNREADABLE_MESSAGE };

	let r;

	try {
		r = json(text);
	}
	catch (e) {
		return { error: UNREADABLE_MESSAGE };
	}

	let v = (type(r) == 'object') ? parse_version(r.tag_name) : null;

	if (!v)
		return { error: UNREADABLE_MESSAGE };

	let body = replace((type(r.body) == 'string') ? r.body : '', '\r', '');
	let assets = {};

	for (let a in (type(r.assets) == 'array') ? r.assets : []) {
		if (type(a) != 'object' || type(a.name) != 'string' || !match(a.name, NAME_RE))
			continue;

		assets[a.name] = {
			url: (!base && asset_url(a.url)) ? a.url : null,
			size: (type(a.size) == 'int' && a.size >= 0) ? a.size : null,
			digest: (type(a.digest) == 'string' && match(a.digest, DIGEST_RE)) ? a.digest : null
		};
	}

	return {
		version: join('.', v),
		tag: r.tag_name,
		url: starts(r.html_url, base ?? UPDATE.page) ? r.html_url : null,
		published: epoch(r.published_at),
		notes: notes(body),
		console: match(body, CONSOLE_RE) != null,
		assets
	};
};

// SHA256SUMS in the format install.sh accepts -> { <name>: <sha256> }; null when any line is not that.
export function parse_sums(text) {
	if (type(text) != 'string')
		return null;

	let sums = {};

	for (let line in split(text, '\n')) {
		if (line == '')
			continue;

		let m = match(line, SUM_LINE);

		// two different sums for one name: neither can be trusted
		if (!m || (sums[m[2]] != null && sums[m[2]] != m[1]))
			return null;

		sums[m[2]] = m[1];
	}

	return sums;
};

// The packages to install: every *.apk of the release, except LuCI packages that are not installed now (the
// LuCI app and the Russian pages stay as the user chose them). A package the release no longer ships is left
// alone. { files } in SHA256SUMS order, or { error }.
export function install_set(sums, inst) {
	let files = [];

	for (let name in keys(sums ?? {})) {
		if (!match(name, /\.apk$/))
			continue;

		let pkg = substr(name, 0, -4);

		if (starts(pkg, 'luci-') && inst?.packages?.[pkg] == null)
			continue;

		push(files, name);
	}

	if (index(files, 'shadow-vpn.apk') < 0)
		return { error: sprintf(NO_FILE_MESSAGE, 'shadow-vpn.apk') };

	return { files };
};

// opts.run moves the tmpfs files (tests), opts.etc the flash one; their names stay those of UPDATE.
function paths(opts) {
	let at = (dir, path) => dir ? `${dir}/${fs.basename(path)}` : path;

	return {
		state: at(opts.run, UPDATE.state), run: at(opts.run, UPDATE.run), work: at(opts.run, UPDATE.work),
		base_url: at(opts.run, UPDATE.base_url), active: `${opts.run ?? RUN}/active`, auto: at(opts.etc, UPDATE.auto),
		lock: opts.lock ?? UPDATE.lock
	};
}

// The lab's hook: SHADOW_BASE_URL, else RUN/update.base_url (rpcd's jobs do not pass the environment on).
// Release JSON and files then come from <base>/... instead of GitHub.
function base_url(ctx) {
	let b = ctx.opts.base_url ?? getenv('SHADOW_BASE_URL') ?? '';

	if (b == '')
		b = trim(fs.readfile(ctx.p.base_url) ?? '');

	b = replace(b, /\/+$/, '');

	if (b == '')
		return null;

	if (!match(b, BASE_RE)) {
		state.log('warning', `The update base URL is invalid and was ignored: ${b}`);
		return null;
	}

	return b;
}

function uci(opts) {
	return opts.confdir ? cursor(opts.confdir) : cursor();
}

function context(opts) {
	opts ??= {};

	let model = opts.config ?? config.load(uci(opts));
	let ctx = {
		opts, model,
		L: { ...UPDATE, ...(opts.limits ?? {}) },
		mode: opts.mode ?? model?.main?.update ?? 'notify',
		p: paths(opts),
		sleep: opts.sleep ?? ((s) => sleep(s * 1000)),
		lock: null, blocked: null, release: null, installed: null, deadline: null, auto: null, from: null, target: null,
		started: null, record: null
	};

	ctx.base = base_url(ctx);

	return ctx;
}

function now(ctx) {
	return ctx.opts.now ?? time();
}

function uptime(ctx) {
	return ctx.opts.uptime ?? state.uptime();
}

// opts.bin holds a stub of every command (tests); production relies on PATH and the absolute paths.
function exe(ctx, path) {
	return ctx.opts.bin ? `${ctx.opts.bin}/${fs.basename(path)}` : path;
}

function command_line(ctx, argv) {
	return join(' ', map([ exe(ctx, argv[0]), ...slice(argv, 1) ], (a) => q(a)));
}

// Every command reads /dev/null and writes into a file of the work dir or /dev/null, never into our stdout, which
// carries the CLI's one JSON line. With ms the command is killed after ms ms: exec makes it the process that
// system() kills, not a shell that would leave it running.
function sh(ctx, argv, out, ms) {
	let cmd = sprintf('exec %s </dev/null >%s 2>&1', command_line(ctx, argv), q(out ?? '/dev/null'));

	return (ms != null) ? system(cmd, ms) : system(cmd);
}

function output(ctx, argv) {
	let p = fs.popen(sprintf('exec %s </dev/null 2>/dev/null', command_line(ctx, argv)), 'r');

	if (!p)
		return '';

	let out = p.read('all') ?? '';

	p.close();

	return out;
}

function rm_rf(path) {
	let st = fs.lstat(path);

	if (st?.type == 'directory') {
		for (let name in fs.lsdir(path) ?? [])
			rm_rf(`${path}/${name}`);

		fs.rmdir(path);
	}
	else if (st) {
		fs.unlink(path);
	}
}

function work_dir(ctx) {
	// RUN is 0700; mkdir_p would create it 0755
	state.ensure_run();
	state.mkdir_p(ctx.p.work, 0o700);

	return ctx.p.work;
}

function read_state(ctx) {
	let s = state.read_json(ctx.p.state);

	return { ...STATE_DEFAULT, ...((type(s) == 'object') ? s : {}) };
}

function write_state(ctx, patch) {
	let next = { ...read_state(ctx), ...patch };

	state.write_json(ctx.p.state, next);

	return next;
}

// The install in progress, for rpcd (its pid tells a live run from one a reboot or the OOM killer ended).
function stage(ctx, name) {
	ctx.started ??= { started: now(ctx), started_up: uptime(ctx) };

	state.write_json(ctx.p.run, {
		pid: int(fs.readlink('/proc/self')), stage: name, version: ctx.target, auto: ctx.auto != null, ...ctx.started
	});
}

function read_auto(ctx) {
	let r = state.read_json(ctx.p.auto);

	return (type(r) == 'object' && type(r.version) == 'string') ? r : null;
}

// The automatic attempts live on flash, so a reboot does not reset the count: written only when they change,
// tmp + fsync + rename as lists.uc stores a list.
function write_auto(ctx, rec) {
	let path = ctx.p.auto, dir = fs.dirname(path), tmp = `${path}.tmp`;
	let data = sprintf('%J\n', rec);

	if (fs.readfile(path) == data)
		return true;

	state.mkdir_p(dir, 0o700);

	let f = fs.open(tmp, 'w', 0o600);

	if (!f)
		return false;

	let ok = f.write(data) == length(data);

	f.close();
	fs.chmod(tmp, 0o600);
	sh(ctx, [ 'fsync', tmp ]);

	if (!ok || !fs.rename(tmp, path)) {
		fs.unlink(tmp);
		return false;
	}

	sh(ctx, [ 'fsync', dir ]);

	return true;
}

// install.sh shadow_blocks_router: Shadow is on with the kill switch and routes the router's own traffic, and its
// tunnel is down. An xray that does not answer counts as down; one that answers before its first probe gets
// tunnel_wait s for a verdict, then the router counts as not blocked.
function router_blocked(ctx) {
	let m = ctx.model?.main;

	if (!m?.enabled || !fs.access(ctx.p.active) || !m.kill_switch || !m.router_traffic)
		return false;

	for (let i = 0; ; i++) {
		let h = state.tunnel_health(3000);

		if (!h.answered || h.probed)
			return h.alive !== true;

		if (i >= ctx.L.tunnel_wait)
			return false;

		ctx.sleep(1);
	}
}

// Asked once per action: it can wait for xray's first probe.
function blocked(ctx) {
	ctx.blocked ??= !!(ctx.opts.blocked ? ctx.opts.blocked() : router_blocked(ctx));

	return ctx.blocked;
}

// Connected with a tunnel xray's own probe calls alive.
function tunnel_up(ctx) {
	if (ctx.opts.connected)
		return !!ctx.opts.connected();

	return state.read().phase == 'connected' && state.tunnel_health().alive === true;
}

// A network failure while the kill switch blocks the router: say what is probably behind it.
function hinted(ctx, kind, message) {
	return ((kind == 'unreachable' || kind == 'timeout') && blocked(ctx)) ? sprintf(KILL_HINT_MESSAGE, message) : message;
}

// One uclient-fetch run into file: {} or { kind } with kind missing (HTTP 404), rate (403, 429), timeout or
// unreachable. Never through a pipeline, and never -q: only its stderr tells the HTTP status (install.sh
// release_missing). That stderr is never shown or logged, as it holds github.com's signed redirect URLs.
function fetch_once(ctx, url, file, header, deadline) {
	let left = int(deadline - now_ms());

	if (!match(url, URL_RE))
		return { kind: 'unreachable' };

	if (left <= 0)
		return { kind: 'timeout' };

	let err = `${work_dir(ctx)}/fetch.err`;

	fs.unlink(file);

	let rc = system(sprintf('exec %s -T 15 %s-O %s %s </dev/null >/dev/null 2>%s', q(exe(ctx, 'uclient-fetch')),
		header ? `--header=${q(header)} ` : '', q(file), q(url), q(err)), min(ctx.L.fetch_ms, left));
	let status = null;

	for (let line in split(fs.readfile(err) ?? '', '\n')) {
		let m = match(line, /^HTTP error ([0-9]+)/);

		if (m)
			status = int(m[1]);
	}

	fs.unlink(err);

	if (rc == 0)
		return {};

	if (rc < 0)
		return { kind: 'timeout' };

	if (rc == 8 && status == 404)
		return { kind: 'missing' };

	if (rc == 8 && (status == 403 || status == 429))
		return { kind: 'rate' };

	return { kind: 'unreachable' };
}

// Up to `tries` rounds `pause` s apart over the sources in order, within the action's deadline. Each file must
// fit max and, when the release lists its size, have exactly that size. A file missing from every source, or the
// rate limit, ends the rounds: asking again does not help. A round reports its most telling failure.
function fetch_file(ctx, sources, file, max, size, deadline) {
	let kind = 'unreachable';

	for (let i = 0; i < ctx.L.tries; i++) {
		if (i > 0) {
			if (now_ms() + ctx.L.pause * 1000 >= deadline)
				return { kind: 'timeout' };

			ctx.sleep(ctx.L.pause);
		}

		let kinds = [];

		for (let src in sources) {
			let r = fetch_once(ctx, src.url, file, src.header, deadline);

			if (r.kind == null) {
				let got = fs.stat(file)?.size;

				if (got != null && got <= max && (size == null || got == size))
					return {};

				fs.unlink(file);
				r.kind = 'size';
			}

			push(kinds, r.kind);
		}

		for (let k in [ 'rate', 'size', 'timeout', 'unreachable', 'missing' ]) {
			if (index(kinds, k) >= 0) {
				kind = k;
				break;
			}
		}

		if (kind == 'rate' || kind == 'missing')
			break;
	}

	return { kind };
}

// Where a release's JSON is: GitHub's API, or the lab's base (<base>/release.json for the latest one,
// <base>/<tag>/release.json for a tag).
function json_url(ctx, tag) {
	if (ctx.base)
		return tag ? `${ctx.base}/${tag}/release.json` : `${ctx.base}/release.json`;

	return tag ? `${UPDATE.api}/tags/${tag}` : `${UPDATE.api}/latest`;
}

// The release JSON of the latest release or of tag -> release_info() plus `prefix`, where its files are: the
// download URL of its own tag (so "latest" cannot move between two downloads), or the base.
function fetch_release(ctx, tag, deadline) {
	let file = `${work_dir(ctx)}/release.json`;
	let r = fetch_file(ctx, [ { url: json_url(ctx, tag), header: ctx.base ? null : ACCEPT_JSON } ], file, ctx.L.json_max,
		null, deadline);

	if (r.kind)
		return { kind: (r.kind == 'size') ? 'invalid' : r.kind };

	let rel = release_info(fs.readfile(file), ctx.base);

	fs.unlink(file);

	if (rel.error)
		return { kind: 'invalid' };

	rel.prefix = ctx.base ? (tag ? `${ctx.base}/${tag}` : ctx.base) : `${UPDATE.download}/${rel.tag}`;

	return rel;
}

// install.sh's two paths: the tag's download URL, then the asset's API URL. github.com's redirects for the first
// carry a header near uclient-fetch's 4 KB line limit; the API's do not.
function sources(rel, name) {
	let list = [ { url: `${rel.prefix}/${name}` } ];

	if (rel.assets?.[name]?.url)
		push(list, { url: rel.assets[name].url, header: ACCEPT_FILE });

	return list;
}

function check_message(kind) {
	switch (kind) {
	case 'missing':
		return NO_RELEASE_MESSAGE;

	case 'rate':
		return RATE_LIMIT_MESSAGE;

	case 'invalid':
		return UNREADABLE_MESSAGE;
	}

	return UNREACHABLE_MESSAGE;
}

function file_message(kind, name) {
	switch (kind) {
	case 'missing':
		return sprintf(NO_FILE_MESSAGE, name);

	case 'rate':
		return RATE_LIMIT_MESSAGE;

	case 'size':
		return sprintf(SIZE_MESSAGE, name);
	}

	return sprintf(DOWNLOAD_MESSAGE, name);
}

function fetch_asset(ctx, rel, name, dir) {
	let size = rel.assets?.[name]?.size;

	if (size != null && size > ctx.L.file_max)
		return { error: sprintf(SIZE_MESSAGE, name) };

	let r = fetch_file(ctx, sources(rel, name), `${dir}/${name}`, ctx.L.file_max, size, ctx.deadline);

	return r.kind ? { error: hinted(ctx, r.kind, file_message(r.kind, name)) } : {};
}

// SHA256SUMS of the release, then each package: its SHA256SUMS line, and GitHub's own digest when the release
// lists one. names: the packages to fetch (the rollback's), else install_set() picks them. { files } or { error }.
function fetch_set(ctx, rel, dir, names) {
	let r = fetch_asset(ctx, rel, 'SHA256SUMS', dir);

	if (r.error)
		return r;

	let sums = parse_sums(fs.readfile(`${dir}/SHA256SUMS`));

	if (!sums)
		return { error: SUMS_MALFORMED_MESSAGE };

	let set = names ? { files: names } : install_set(sums, ctx.installed);

	if (set.error)
		return set;

	for (let name in set.files) {
		if (sums[name] == null)
			return { error: sprintf(SUMS_ENTRY_MESSAGE, name) };

		r = fetch_asset(ctx, rel, name, dir);

		if (r.error)
			return r;

		let hash = sha256_file(`${dir}/${name}`), digest = rel.assets?.[name]?.digest;

		if (hash != sums[name])
			return { error: sprintf(CHECKSUM_MESSAGE, name) };

		if (digest != null && digest != `sha256:${hash}`)
			return { error: sprintf(DIGEST_MESSAGE, name) };
	}

	return { files: set.files };
}

// The installed version's own packages (tag X.Y.Z), so an automatic install can put them back. Its release
// JSON only adds the second path and the digests: without it the files are still checked against its sums.
function fetch_rollback(ctx, inst, dir) {
	let rel = fetch_release(ctx, inst.version, ctx.deadline);

	if (rel.kind || rel.version != inst.version)
		rel = { version: inst.version, tag: inst.version, assets: {},
			prefix: ctx.base ? `${ctx.base}/${inst.version}` : `${UPDATE.download}/${inst.version}` };

	state.mkdir_p(dir, 0o700);

	return fetch_set(ctx, rel, dir, map(keys(inst.packages), (p) => `${p}.apk`));
}

// apk's reason for a failure: its last ERROR: line, else its last line. The end of its output goes to the log at
// level: error, or warning when the packages went in all the same.
function apk_report(path, rc, level) {
	let lines = filter(map(split(fs.readfile(path) ?? '', '\n'), (l) => trim(l)), (l) => l != '');
	let errors = filter(lines, (l) => match(l, /^ERROR:/));
	let reason = errors[length(errors) - 1] ?? lines[length(lines) - 1] ?? `apk exited with ${rc}`;

	for (let l in slice(lines, -APK_LOG_LINES))
		state.log(level, `apk: ${l}`);

	return (length(reason) > APK_REASON_MAX) ? substr(reason, 0, APK_REASON_MAX) + '…' : reason;
}

// Whether any of Shadow's packages has another version (or is there or gone) in b than in a.
function moved(a, b) {
	for (let name in uniq([ ...keys(a.packages), ...keys(b.packages) ]))
		if (a.packages[name] != b.packages[name])
			return true;

	return false;
}

// What the upgrade removes: a package that only the installed version needs is purged with it, and a rollback
// could not download it again once the tunnel is down (the kill switch blocks the router then). apk tells in a
// dry run, offline with the indexes the `apk update` before left in the cache (it never waits on a feed; lab
// image); those packages are fetched now, while the router still reaches the feeds, next to the rollback files.
// { names, files } or { error }.
function rollback_deps(ctx, files, inst) {
	let W = ctx.p.work, dir = `${W}/rollback/deps`, log = `${W}/apk-simulate.log`;
	let rc = sh(ctx, [ 'apk', 'add', '--simulate', '--no-network', '--cache-dir', `${W}/cache`, '--allow-untrusted',
		...map(files, (f) => `${W}/${f}`) ], log, ctx.L.apk_update_ms);

	// the real transaction would fail the same way: say why, before anything changed
	if (rc != 0)
		return { error: sprintf(APK_FAILED_MESSAGE, apk_report(log, rc, 'error')) };

	let names = [];

	for (let line in split(fs.readfile(log) ?? '', '\n')) {
		let m = match(line, /^\([0-9]+\/[0-9]+\) Purging ([^ ]+) \(/);

		// Shadow's own packages are in the rollback files already
		if (m && match(m[1], NAME_RE) && inst.packages[m[1]] == null)
			push(names, m[1]);
	}

	if (!length(names))
		return { names, files: [] };

	state.mkdir_p(dir, 0o700);
	rc = sh(ctx, [ 'apk', 'fetch', '--cache-dir', `${W}/cache`, '-o', dir, ...names ], `${W}/apk-fetch.log`,
		ctx.L.apk_update_ms);

	let got = filter(fs.lsdir(dir) ?? [], (f) => match(f, /\.apk$/));
	let missing = filter(names, (n) => !length(filter(got, (f) => substr(f, 0, length(n) + 1) == `${n}-` &&
		match(substr(f, length(n) + 1), /^[0-9]/))));

	if (rc != 0 || length(missing)) {
		state.log('warning', sprintf('The packages the update to Shadow %s removes could not be fetched for a rollback: %s',
			ctx.target, join(' ', length(missing) ? missing : names)));

		return { error: sprintf(ROLLBACK_MISSING_MESSAGE, inst.version) };
	}

	return { names, files: got };
}

// procd's running instances of Shadow, { <name>: pid }, as `apply` reads them.
function instances(ctx) {
	let r = null;

	try {
		r = json(output(ctx, [ 'ubus', 'call', 'service', 'list', '{"name":"shadow-vpn"}' ]));
	}
	catch (e) { }

	let list = r?.['shadow-vpn']?.instances, pids = {};

	for (let name, inst in (type(list) == 'object') ? list : {})
		if (inst?.running === true && type(inst.pid) == 'int')
			pids[name] = inst.pid;

	return pids;
}

// Whether every instance of before runs again, each with a pid of its own (the code apk just installed).
function renewed(ctx, before) {
	let now = instances(ctx);

	for (let name in keys(before))
		if (now[name] == null || now[name] == before[name])
			return false;

	return true;
}

// apk's post-install starts Shadow again, but procd keeps an instance whose declaration did not change (the same
// command, files and env: an upgrade that renders the same xray.json): the old helpers would go on running, and
// the wait for the tunnel would judge them instead of the new ones. An instance that still has its pid from
// before apk is deleted and declared again by the new init script; the nft table and the kill switch stay, so
// the LAN waits a few seconds instead of going direct.
function restart(ctx, before) {
	let now = instances(ctx);
	let kept = filter(keys(before), (name) => now[name] == before[name]);

	if (!length(kept))
		return;

	for (let name in kept)
		sh(ctx, [ 'ubus', 'call', 'service', 'delete', sprintf('%J', { name: 'shadow-vpn', instance: name }) ]);

	sh(ctx, [ '/etc/init.d/shadow-vpn', 'start' ]);
}

// install.sh after apk add: an upgrade keeps Shadow on when it was on, LuCI drops its caches and rpcd loads the
// new plugin (rpcd keeps the sessions over its reload, so nobody has to log in again). From here on only the init
// script runs Shadow's helpers: apk has just replaced them.
function after_apk(ctx, was_enabled) {
	if (was_enabled) {
		let c = uci(ctx.opts);

		if (c.get(UCI, 'main', 'enabled') != '1') {
			c.set(UCI, 'main', 'enabled', '1');
			c.commit(UCI);
			sh(ctx, [ '/etc/init.d/shadow-vpn', 'start' ]);
		}
	}

	for (let f in fs.glob('/tmp/luci-indexcache.*') ?? [])
		rm_rf(f);

	rm_rf('/tmp/luci-modulecache');
	sh(ctx, [ '/etc/init.d/rpcd', 'reload' ]);
}

// Polls every 2 s for up to settle s until the tunnel is back: every instance of before runs again with a new
// pid, Shadow is connected and xray's probe calls the tunnel alive, on consecutive polls over stable s. Right
// after apk the state can still say connected from before the restart, and a helper that fails a little later
// would pass a single look.
function settle(ctx, before) {
	let since = null;

	for (let waited = 0; waited < ctx.L.settle; ) {
		ctx.sleep(2);
		waited += 2;

		if (!renewed(ctx, before) || !tunnel_up(ctx)) {
			since = null;
			continue;
		}

		since ??= waited;

		if (waited - since >= ctx.L.stable)
			return true;
	}

	return false;
}

// Asks for the latest release and records the answer in UPDATE.state; a failed check keeps what the last good
// one found. The banner comes once per version (announced) and never in manual mode.
function do_check(ctx) {
	let inst = installed(ctx.opts);
	let rel = fetch_release(ctx, null, now_ms() + ctx.L.check_ms);
	let error = rel.kind ? hinted(ctx, rel.kind, check_message(rel.kind)) : null;
	let found = error ? {} : { latest: rel.version, tag: rel.tag, url: rel.url, published: rel.published, notes: rel.notes,
		console: rel.console };
	let st = write_state(ctx, { ...found, checked: now(ctx), checked_up: uptime(ctx), ok: !error, error, installed: inst.version });
	let available = compare(st.latest, inst.version) == 1;

	if (!error) {
		if (!available || ctx.mode == 'manual') {
			state.attention_clear('update_available');
		}
		else if (st.latest != st.announced) {
			state.attention_add('update_available', sprintf(AVAILABLE_MESSAGE, st.latest));
			write_state(ctx, { announced: st.latest });
		}
	}

	ctx.release = error ? null : rel;
	ctx.installed = inst;

	let res = { ok: !error, installed: inst.version, latest: st.latest, available, console: st.console === true };

	if (error)
		res.error = error;

	return res;
}

// The next automatic attempt at version: one more try than the last one at it, else the first.
function attempt(ctx, version) {
	let rec = read_auto(ctx);
	let tries = (rec?.version == version && type(rec.tries) == 'int') ? rec.tries + 1 : 1;

	return { version, tries, at: now(ctx), finished: false, ok: false, error: null };
}

function at_least(a, b) {
	let c = compare(a, b);

	return c === 0 || c === 1;
}

// update_failed knows the version it is about and what was installed when it came, so tidy() can tell an
// install from elsewhere from the state the failure left behind.
function failed_banner(ctx, version, message, inst) {
	state.attention_add('update_failed', message, { version, installed: inst.version });
}

// The banners follow what is installed, whoever installed it (LuCI, the console, a release that came out
// meanwhile): update_available goes once the installed version is the latest; update_failed once its version or
// a later one is installed by something other than the run that failed, as a failed rollback leaves the broken
// version installed, and that banner must stay.
function tidy(ctx, inst) {
	if (at_least(inst.version, read_state(ctx).latest))
		state.attention_clear('update_available');

	for (let e in state.attention_list())
		if (e.code == 'update_failed' && at_least(inst.version, e.extra?.version) && inst.version != e.extra?.installed)
			state.attention_clear('update_failed');
}

// The automatic install's way back: the verified packages of the version it replaced, and what the upgrade purged,
// from the work dir and without the network (the kill switch may block the router by now). run: what do_install
// knew before apk; cause: the error of an apk that installed only part of the release, else the tunnel did not
// come back. The result says whether the old version is back.
function put_back(ctx, run, cause) {
	let W = ctx.p.work, from = ctx.from, to = ctx.target;
	let cur = installed(ctx.opts);
	let off = cause == null && config.parse_bool(uci(ctx.opts).get(UCI, 'main', 'enabled')) !== true;

	// removed or turned off from the console meanwhile: putting the packages back would undo that
	if (cur.version == null || off) {
		state.log('warning', `Shadow was removed or turned off during the update to ${to}; the previous version is not put back.`);

		return { ok: false, changed: moved(run.inst, cur), from, to, error: cause ?? sprintf(SETTLE_MESSAGE, to, ctx.L.settle) };
	}

	stage(ctx, 'rollback');

	if (cause == null)
		state.log('warning', `The tunnel did not come back after the update to Shadow ${to}; putting ${from} back.`);
	else
		state.log('warning', `The update to Shadow ${to} went in only in part; putting ${from} back.`);

	let pids = run.was_connected ? instances(ctx) : {};
	let rc = sh(ctx, [ 'apk', 'add', '--no-network', '--cache-dir', `${W}/cache`, '--allow-untrusted',
		...map(run.rollback, (f) => `${W}/rollback/${f}`), ...map(run.deps.files, (f) => `${W}/rollback/deps/${f}`) ],
		`${W}/apk-rollback.log`);
	let now_inst = installed(ctx.opts), back = now_inst.version == from;
	let reason = (rc != 0) ? apk_report(`${W}/apk-rollback.log`, rc, back ? 'warning' : 'error') : null;

	if (!back)
		reason ??= sprintf(NOT_INSTALLED_MESSAGE, from);
	else if (length(run.deps.names))
		// apk keeps a package given as a file in its world, pinned: make them dependencies again, as before
		sh(ctx, [ 'apk', 'del', '--no-network', ...run.deps.names ], `${W}/apk-del.log`);

	after_apk(ctx, run.was_enabled);

	if (back && run.was_connected) {
		restart(ctx, pids);

		// the result stays a rollback either way; a tunnel that stays down with the old version too is the server's
		if (!settle(ctx, pids))
			state.log('warning', `The tunnel did not come back after the rollback to Shadow ${from} either.`);
	}

	let error = cause;

	if (error == null)
		error = back ? sprintf(ROLLED_BACK_MESSAGE, to, from) : sprintf(ROLLBACK_FAILED_MESSAGE, to, from, reason);
	else if (!back)
		state.log('error', `Putting Shadow ${from} back failed: ${reason}`);

	return { ok: false, changed: moved(run.inst, now_inst), from, to, rolled_back: back, error };
}

// install.sh do_install for an upgrade, then (when Shadow was connected) the wait for the tunnel and, in an
// automatic install, the rollback. The result before conclude() records it.
function do_install(ctx, auto) {
	let L = ctx.L, inst = installed(ctx.opts), from = inst.version;
	let fail = (error, extra) => ({ ok: false, changed: false, from, to: ctx.target, error, ...(extra ?? {}) });

	ctx.from = from;
	ctx.target = auto;
	stage(ctx, 'check');

	if (now(ctx) < L.clock_floor)
		return fail(CLOCK_MESSAGE);

	if (!from)
		return fail(UNKNOWN_VERSION_MESSAGE);

	let dir = (fs.stat('/overlay')?.type == 'directory') ? '/overlay' : '/';
	let free = split(trim(split(output(ctx, [ 'df', '-Pk', dir ]), '\n')[1] ?? ''), /[ \t]+/)[3];
	let mem = match(fs.readfile('/proc/meminfo') ?? '', /MemAvailable:[ \t]*([0-9]+)/)?.[1];

	free = match(free ?? '', /^[0-9]+$/) ? int(free) : 0;
	mem = (mem != null) ? int(mem) : 0;

	if (free < L.free_kb)
		return fail(sprintf(SPACE_MESSAGE, free / 1024, L.free_kb / 1024));

	if (mem < L.mem_kb)
		return fail(sprintf(MEMORY_MESSAGE, mem / 1024, L.mem_kb / 1024));

	// full mode routes every download into the dead tunnel; split mode routes only listed hosts, so it tries
	if (blocked(ctx) && ctx.model?.main?.mode != 'selected-rules')
		return fail(BLOCKED_MESSAGE);

	let c = do_check(ctx), rel = ctx.release;

	if (!c.ok)
		return fail(c.error);

	ctx.target = rel.version;

	if (!c.available)
		return { ok: true, changed: false, version: from, quiet: true };

	// a newer release came out after due started this run: the next due picks that one up (and sees whether it
	// must come from the console)
	if (auto && rel.version != auto)
		return { ok: true, changed: false, version: from, quiet: true };

	if (rel.console)
		return fail(sprintf(CONSOLE_MESSAGE, rel.version));

	// on flash before any download: a reboot or the OOM killer cannot reset the count (conclude() finishes it)
	if (auto) {
		ctx.record = attempt(ctx, rel.version);
		write_auto(ctx, ctx.record);
	}

	stage(ctx, 'download');

	let W = ctx.p.work;

	rm_rf(W);
	work_dir(ctx);
	state.mkdir_p(`${W}/cache`, 0o700);
	ctx.deadline = now_ms() + L.total_ms;

	let set = fetch_set(ctx, rel, W);

	if (set.error)
		return fail(set.error);

	let rollback = null;

	if (auto) {
		rollback = fetch_rollback(ctx, inst, `${W}/rollback`);

		if (rollback.error) {
			state.log('warning', `The packages of Shadow ${from} for a rollback: ${rollback.error}`);
			return fail(sprintf(ROLLBACK_MISSING_MESSAGE, from));
		}
	}

	stage(ctx, 'install');

	// read now, as install.sh does: Shadow turned off while the files downloaded stays off
	let was_enabled = config.parse_bool(uci(ctx.opts).get(UCI, 'main', 'enabled')) === true;
	let was_connected = was_enabled && fs.access(ctx.p.active) && tunnel_up(ctx);

	// removed while the files downloaded (`apk del` by hand; install.sh waits for this lock): installing now
	// would bring it back
	if (installed(ctx.opts).version == null)
		return fail(UNKNOWN_VERSION_MESSAGE);

	// as install.sh: apk add can still find the dependencies with the indexes it has
	if (sh(ctx, [ 'apk', 'update', '--cache-dir', `${W}/cache` ], `${W}/apk-update.log`, L.apk_update_ms) != 0)
		state.log('warning', 'apk update failed before the update; installing anyway.');

	let deps = { names: [], files: [] };

	if (auto) {
		deps = rollback_deps(ctx, set.files, inst);

		if (deps.error)
			return fail(deps.error);
	}

	let run = { inst, rollback: rollback?.files ?? [], deps, was_enabled, was_connected };
	let pids = was_connected ? instances(ctx) : {};

	// never killed: apk may be in the middle of its transaction. It downloads every dependency first, as dnsmasq
	// can be replaced by dnsmasq-full and the router resolves names through it.
	let rc = sh(ctx, [ 'apk', 'add', '--cache-dir', `${W}/cache`, '--cache-predownload', '--allow-untrusted',
		...map(set.files, (f) => `${W}/${f}`) ], `${W}/apk.log`);

	// apk 3 can exit non-zero after the transaction went through (a package script failed, now or on an earlier
	// run, which apk goes on counting): what is installed tells what happened, not the exit code
	let now_inst = installed(ctx.opts), went_in = now_inst.version == rel.version;
	let reason = (rc != 0) ? apk_report(`${W}/apk.log`, rc, went_in ? 'warning' : 'error') : null;

	if (!went_in) {
		let error = (reason != null) ? sprintf(APK_FAILED_MESSAGE, reason) : sprintf(NOT_INSTALLED_MESSAGE, rel.version);

		if (!moved(inst, now_inst))
			return fail(error);

		// part of the release went in: rpcd and LuCI may have new files, and an automatic install puts the
		// previous version back
		stage(ctx, 'finish');
		after_apk(ctx, was_enabled);

		return auto ? put_back(ctx, run, error) : fail(error, { changed: true });
	}

	if (reason != null)
		state.log('warning', `apk exited with an error, but Shadow ${rel.version} is installed: ${reason}`);

	stage(ctx, 'finish');
	after_apk(ctx, was_enabled);

	let done = { ok: true, changed: true, from, to: rel.version };

	// a tunnel that was down is not waited for: the new helpers run from Shadow's next start
	if (!was_connected)
		return done;

	stage(ctx, 'settle');
	restart(ctx, pids);

	if (settle(ctx, pids))
		return done;

	if (!auto)
		return { ...done, ok: false, error: sprintf(SETTLE_MESSAGE, rel.version, L.settle) };

	return put_back(ctx, run, null);
}

// What every install leaves behind: last in UPDATE.state, the attention entries, the automatic attempt finished
// on flash, the log; the work dir and the run file go. A run that changed nothing (not newer, or a newer release
// than due asked for) records nothing.
function conclude(ctx, auto, res) {
	let inst = installed(ctx.opts);

	if (!res.quiet) {
		write_state(ctx, {
			last: {
				ok: res.ok, changed: res.changed, from: res.from, to: res.to, error: res.error ?? null, auto: auto != null,
				rolled_back: res.rolled_back ?? null, at: now(ctx), at_up: uptime(ctx)
			},
			installed: inst.version
		});

		if (res.ok) {
			state.attention_clear('update_failed');
			state.log('info', sprintf('Shadow was updated from %s to %s.', res.from, res.to));
		}
		else {
			state.log('error', sprintf('The update of Shadow %s to %s failed: %s', res.from, res.to, res.error ?? 'see the messages above'));

			// an error the run could not word (an exception, logged) still tells that the attempt ended
			if (auto)
				failed_banner(ctx, res.to ?? auto, (res.error != null) ? sprintf(AUTO_FAILED_MESSAGE, res.to ?? auto, res.error) :
					sprintf(INTERRUPTED_MESSAGE, res.to ?? auto), inst);
		}

		// Every automatic run that gets here is an attempt, also one that a precondition (clock, space, memory,
		// the kill switch) or GitHub stopped before any download: due would start it again every hour of the
		// night otherwise, and raise its banner again each time.
		if (auto)
			write_auto(ctx, { ...(ctx.record ?? attempt(ctx, res.to ?? auto)), finished: true, ok: res.ok, error: res.error ?? null });
	}

	tidy(ctx, inst);
	rm_rf(ctx.p.work);

	// last: rpcd looks at the run file before it reads UPDATE.state, so a call that finds no run file reads the
	// final `last`, and LuCI's poll never stops on the result of the run before
	fs.unlink(ctx.p.run);
	delete res.quiet;

	return res;
}

// The hourly cron entry: the banner, a check once a day (after a failure every few hours), an interrupted
// automatic attempt, and in automatic mode the install job at night. Runs under the lock; it closes the lock before
// it starts the install, which takes it itself.
function do_due(ctx) {
	let L = ctx.L;

	// while we hold the lock no install runs: a run file is what a killed one left
	fs.unlink(ctx.p.run);

	let st = read_state(ctx), inst = installed(ctx.opts);

	// installed from the console or LuCI meanwhile: the banners of older versions go without a request
	tidy(ctx, inst);

	if (ctx.mode == 'manual') {
		state.attention_clear('update_available');
		return { ok: true, mode: ctx.mode };
	}

	let res = { ok: true, mode: ctx.mode, checked: false };

	if (st.checked_up == null || uptime(ctx) - st.checked_up >= (st.ok ? L.interval : L.retry) - L.slack) {
		let c = do_check(ctx);

		res.checked = true;

		if (!c.ok) {
			res.ok = false;
			res.error = c.error;
			state.log('info', `The update check failed: ${c.error}`);
		}

		st = read_state(ctx);
	}

	let rec = read_auto(ctx);

	// Also when its version is installed: a run killed after apk skipped its wait for the tunnel and the rollback,
	// so nobody saw that version work. The banner goes once another install moves the version on (tidy).
	if (rec && !rec.finished) {
		rec = { ...rec, finished: true, ok: false, error: sprintf(INTERRUPTED_MESSAGE, rec.version) };
		write_auto(ctx, rec);
		failed_banner(ctx, rec.version, rec.error, inst);
	}

	let latest = st.latest, hour = ctx.opts.hour ?? localtime().hour;
	let mine = (rec?.version == latest) ? rec : null;

	res.available = compare(latest, inst.version) == 1;

	// a failed check of this run: the install would ask the same GitHub again, and fail the same way
	if (ctx.mode != 'auto' || !res.ok || !res.available || st.console === true || hour < L.window[0] || hour >= L.window[1])
		return res;

	// one attempt per version a night, max_tries per version
	if (mine && (now(ctx) - (mine.at ?? 0) < L.attempt_gap || (mine.tries ?? 0) >= L.max_tries))
		return res;

	if (blocked(ctx))
		return res;

	rm_rf(ctx.p.work);
	ctx.lock.close();
	ctx.lock = null;

	if (ctx.opts.spawn)
		ctx.opts.spawn(latest);
	else
		sh(ctx, [ `${LIBEXEC}/job`, 'update-install', '--auto', latest ]);

	res.spawned = latest;

	return res;
}

// The lock of every action; never Shadow's main LOCK, which the converge of an install's restart takes. Opened
// close-on-exec: start-stop-daemon -b keeps inherited descriptors, and a daemon that apk's scripts start would
// hold the lock for as long as it lives.
function locked(ctx, busy, fn) {
	state.mkdir_p(fs.dirname(ctx.p.lock));

	let f = fs.open(ctx.p.lock, 'ae', 0o600);

	if (!f)
		return { ok: false, error: LOCK_MESSAGE };

	if (!f.lock('xn')) {
		f.close();
		return busy;
	}

	ctx.lock = f;

	let res;

	try {
		res = fn();
	}
	catch (e) {
		state.log('error', `The update failed: ${e.message}`);
		res = { ok: false };
	}

	// due closes it itself before it starts the install
	if (ctx.lock) {
		rm_rf(ctx.p.work);
		ctx.lock.close();
		ctx.lock = null;
	}

	return res;
}

export function check(opts) {
	let ctx = context(opts);

	return locked(ctx, { ok: false, error: BUSY_CHECK_MESSAGE }, () => {
		let res = do_check(ctx);

		if (!res.ok)
			state.log('warning', `The update check failed: ${res.error}`);

		return res;
	});
};

// auto: the version due saw (install --auto); a busy lock then is no failure, the next due tries again.
export function install(opts, auto) {
	let ctx = context(opts);

	ctx.auto = auto;

	return locked(ctx, auto ? { ok: true, changed: false, skipped: 'busy' } : { ok: false, error: BUSY_INSTALL_MESSAGE }, () => {
		let res;

		try {
			res = do_install(ctx, auto);
		}
		catch (e) {
			state.log('error', `The update failed: ${e.message}`);

			let v = installed(ctx.opts).version;

			res = { ok: false, changed: ctx.from != null && v != ctx.from, from: ctx.from, to: ctx.target };
		}

		return conclude(ctx, auto, res);
	});
};

export function due(opts) {
	let ctx = context(opts);

	return locked(ctx, { ok: true, skipped: 'busy' }, () => do_due(ctx));
};
