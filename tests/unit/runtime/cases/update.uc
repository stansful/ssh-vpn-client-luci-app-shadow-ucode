'use strict';

// update.uc and libexec/update (DESIGN.md 11, "Updates from LuCI"): the pure helpers, then check, install and due
// against stand-ins in a temp bin dir: uclient-fetch serves GitHub from files (and, like the real one, names an
// HTTP error on stderr only without -q), apk installs stand-in packages into a test database, df, the init
// scripts and fsync record their calls. The live parts write RUN/attention.json, so they run only where
// /var/run/shadow-vpn does not exist yet; everything is removed afterwards.

import { access, readfile, writefile, open, unlink, chmod, dirname, popen } from 'fs';
import { sha256 } from 'digest';
import * as update from 'shadow-vpn.update';
import * as state from 'shadow-vpn.state';
import * as C from 'shadow-vpn.const';
import { ok, eq, run, done, MODS, LIBEXEC } from 'rt';

const UPDATE = C.UPDATE;
const RUN = '/var/run/shadow-vpn', T = '/tmp/rt-update', W = `${T}/run/update.work`, LOCKFILE = `${T}/lock/update.lock`;
const NO_RELEASE = 'No Shadow release is published yet.';
const RATE = 'GitHub refused the request: too many requests from this address. Try again in an hour.';
const UNREACHABLE = 'Could not reach GitHub to check for updates.';
const UNREADABLE = 'GitHub returned a release that Shadow cannot read.';
const HINT = ' The tunnel is down, and Shadow’s kill switch may be what blocks the download.';

// pure helpers

eq('update/parse_version: the three forms', [ update.parse_version('1.2.3'), update.parse_version('v0.10.0'),
	update.parse_version('0.1.5-r1') ], [ [ 1, 2, 3 ], [ 0, 10, 0 ], [ 0, 1, 5 ] ]);
eq('update/parse_version: anything else', map([ '01.2.3', '1.2', '1.2.3.4', 'v1.2.3-r1', '1.2.3-r', ' 1.2.3', '', null, 5,
	'1234567890.0.0' ], (s) => update.parse_version(s)), [ null, null, null, null, null, null, null, null, null, null ]);
eq('update/compare: numeric per part', [ update.compare('0.1.10', '0.1.9'), update.compare('0.2.0', '0.10.0'),
	update.compare('1.0.0', '1.0.0-r1'), update.compare('v2.0.0', '1.9.9') ], [ 1, -1, 0, 1 ]);
eq('update/compare: null for an invalid side', [ update.compare('x', '1.0.0'), update.compare('1.0.0', null) ], [ null, null ]);

const DB_TEXT = 'P:apk-mbedtls\nV:3.0.5-r3\nA:aarch64_cortex-a53\n\nP:shadow-vpn\nV:0.1.5-r1\nF:usr\n\n' +
	'P:luci-app-shadow-vpn\nV:0.1.5-r1\n\nP:luci-i18n-shadow-vpn-ru\nV:0.1.5-r1\n\nP:luci-i18n-base-ru\nV:25.12-r1\n';

run(`rm -rf ${T} && mkdir -p ${T}`);
writefile(`${T}/db.fixture`, DB_TEXT);
eq('update/installed: Shadow packages of the apk db', update.installed({ db: `${T}/db.fixture` }), {
	version: '0.1.5',
	packages: { 'shadow-vpn': '0.1.5-r1', 'luci-app-shadow-vpn': '0.1.5-r1', 'luci-i18n-shadow-vpn-ru': '0.1.5-r1' }
});
eq('update/installed: no db', update.installed({ db: `${T}/missing` }), { version: null, packages: {} });

const HASH = sha256('x'), PAGE = `${UPDATE.page}tag/0.2.0`;

function info(rel, base) {
	return update.release_info(sprintf('%J', { tag_name: '0.2.0', html_url: PAGE, published_at: '2026-10-25T12:00:00Z',
		body: 'Notes', assets: [], ...rel }), base);
}

let ri = info({ assets: [
	{ name: 'shadow-vpn.apk', url: `${UPDATE.asset_api}123`, size: 10, digest: `sha256:${HASH}` },
	{ name: '../evil', url: `${UPDATE.asset_api}124`, size: 1 },
	{ name: 'has space.apk', url: `${UPDATE.asset_api}125`, size: 1 },
	{ name: 'SHA256SUMS', url: 'https://evil.example/releases/assets/1', size: '10', digest: `sha512:${HASH}` },
	{ name: 'x.apk', url: `${UPDATE.asset_api}12a`, size: -1, digest: 'sha256:XYZ' }
] });

eq('update/release_info: fields', [ ri.version, ri.tag, ri.url, ri.published, ri.notes, ri.console ],
	[ '0.2.0', '0.2.0', PAGE, 1792929600, 'Notes', false ]);
eq('update/release_info: asset filter', ri.assets, {
	'shadow-vpn.apk': { url: `${UPDATE.asset_api}123`, size: 10, digest: `sha256:${HASH}` },
	SHA256SUMS: { url: null, size: null, digest: null },
	'x.apk': { url: null, size: null, digest: null }
});
eq('update/release_info: vX.Y.Z tag', [ info({ tag_name: 'v0.3.0' }).version, info({ tag_name: 'v0.3.0' }).tag ], [ '0.3.0', 'v0.3.0' ]);
eq('update/release_info: bad tag', [ info({ tag_name: 'latest' }), info({ tag_name: null }), update.release_info('{', null),
	update.release_info('[]', null) ], [ { error: UNREADABLE }, { error: UNREADABLE }, { error: UNREADABLE }, { error: UNREADABLE } ]);
let big = '';

for (let i = 0; i < 300; i++)
	big += sprintf('%01000d', i);

eq('update/release_info: more than json_max', update.release_info(sprintf('%J', { tag_name: '0.2.0', body: big })), { error: UNREADABLE });
eq('update/release_info: a foreign page link is dropped', [ info({ html_url: 'https://evil.example/releases/' }).url,
	info({ html_url: 'javascript:alert(1)' }).url, info({ published_at: '2026-13-01T00:00:00Z' }).published ], [ null, null, null ]);
eq('update/release_info: console marker only as a whole line', [ info({ body: 'a\r\nshadow-update: console\r\nb' }).console,
	info({ body: 'shadow-update: console' }).console, info({ body: 'not shadow-update: console' }).console,
	info({ body: 'shadow-update: console now' }).console ], [ true, true, false, false ]);

let long = '';

for (let i = 0; i < 100; i++)
	long += sprintf('line %03d %s\r\n', i, sprintf('%060d', i));

let cut = info({ body: long }).notes;

ok('update/release_info: notes cut at a line end, without CR', length(cut) <= UPDATE.notes_max && length(cut) > UPDATE.notes_max - 80 &&
	index(cut, '\r') < 0 && match(cut, /\nline [0-9]{3} [0-9]{60}$/) != null && substr(cut, 0, 9) == 'line 000 ', cut);

// 'a' and 2100 two-byte characters: byte notes_max falls inside one
let wide = info({ body: 'a' + join('', map(split(sprintf('%02100d', 0), ''), () => 'é')) }).notes;

eq('update/release_info: one long line is cut on a character boundary', [ length(wide), substr(wide, -2) ], [ UPDATE.notes_max - 1, 'é' ]);

let rb = info({ html_url: 'http://base.test/rel/0.2.0', assets: [ { name: 'a.apk', url: `${UPDATE.asset_api}1`, size: 3 } ] },
	'http://base.test/rel');

eq('update/release_info: under a base URL', [ rb.url, rb.assets['a.apk'].url, info({}, 'http://base.test/rel').url ],
	[ 'http://base.test/rel/0.2.0', null, null ]);

eq('update/parse_sums', update.parse_sums(`${HASH}  shadow-vpn.apk\n\n${HASH}  install.sh\n`),
	{ 'shadow-vpn.apk': HASH, 'install.sh': HASH });
eq('update/parse_sums: malformed', map([ `${HASH} shadow-vpn.apk\n`, `${HASH}  *shadow-vpn.apk\n`, `${HASH}  a b\n`,
	`${substr(HASH, 1)}  a\n`, `${HASH}  a\n${sha256('y')}  a\n`, `${HASH}  a\r\n`, null ], (t) => update.parse_sums(t)),
	[ null, null, null, null, null, null, null ]);

let sums = { 'shadow-vpn.apk': HASH, 'luci-app-shadow-vpn.apk': HASH, 'luci-i18n-shadow-vpn-ru.apk': HASH, 'install.sh': HASH,
	'shadow-vpn-extra.apk': HASH };

eq('update/install_set: Russian only when installed, new non-LuCI packages too', update.install_set(sums,
	{ packages: { 'shadow-vpn': '1', 'luci-app-shadow-vpn': '1' } }),
	{ files: [ 'shadow-vpn.apk', 'luci-app-shadow-vpn.apk', 'shadow-vpn-extra.apk' ] });
eq('update/install_set: everything installed', update.install_set(sums, { packages: { 'shadow-vpn': '1',
	'luci-app-shadow-vpn': '1', 'luci-i18n-shadow-vpn-ru': '1' } }).files,
	[ 'shadow-vpn.apk', 'luci-app-shadow-vpn.apk', 'luci-i18n-shadow-vpn-ru.apk', 'shadow-vpn-extra.apk' ]);
eq('update/install_set: no LuCI app installed', update.install_set(sums, { packages: { 'shadow-vpn': '1' } }).files,
	[ 'shadow-vpn.apk', 'shadow-vpn-extra.apk' ]);
eq('update/install_set: shadow-vpn.apk missing', update.install_set({ 'luci-app-shadow-vpn.apk': HASH }, { packages: {} }),
	{ error: 'The latest release has no shadow-vpn.apk.' });

if (access(RUN)) {
	print('ok update # live parts skipped: /var/run/shadow-vpn already exists\n');
	run(`rm -rf ${T}`);
	done();
}

// stand-ins

function put(path, data, mode) {
	state.mkdir_p(dirname(path));
	writefile(path, data);

	if (mode)
		chmod(path, mode);
}

put(`${T}/bin/uclient-fetch`, `#!/bin/sh
# serves ${T}/www/<URL without the scheme>; <file>.status makes it fail: an HTTP status, net, or sleep <s>;
# ${T}/fetch.hook runs once, before the first package download (something else changes the router meanwhile)
echo "$*" >> ${T}/fetch.log
quiet= out= url=
while [ $# -gt 0 ]; do
	case "$1" in
	-q) quiet=1 ;;
	-O) out="$2"; shift ;;
	-T) shift ;;
	-*) ;;
	*) url="$1" ;;
	esac
	shift
done
path="${T}/www/\${url#*://}"
case "$url" in *.apk) [ -f ${T}/fetch.hook ] && { sh ${T}/fetch.hook; rm -f ${T}/fetch.hook; } ;; esac
echo "Downloading '$url'" >&2
if [ -f "$path.status" ]; then
	st="$(cat "$path.status")"
	case "$st" in
	net) echo "Connection error: Connection refused" >&2; exit 4 ;;
	sleep*) sleep "\${st#sleep }" ;;
	*) [ -n "$quiet" ] || echo "HTTP error $st" >&2; exit 8 ;;
	esac
fi
if [ ! -f "$path" ]; then
	[ -n "$quiet" ] || echo "HTTP error 404" >&2
	exit 8
fi
cat "$path" > "$out"
echo "Download completed" >&2
`, 0o755);

// apk add installs the files it is given (each "<name> <version>") into ${T}/db and chatters on stdout and stderr;
// like apk 3.0.5 every call exits 99 when its --cache-dir does not exist. Flags: apk.fail (its text, then exit 1,
// nothing installed), apk.fail.rollback (only for files of W/rollback), apk.fail.after (installs, then exits 1 as
// after a failed package script), apk.partial (installs only the LuCI packages, then exits 1), apk.noop,
// apk.detach (a package script that leaves a daemon behind), apk.disable (a package script that turns Shadow off),
// apk.restart (procd restarts the instances: their declaration changed). A dry run (--simulate) changes nothing and
// names the packages of apk.purge as purged, or fails with apk.simulate.fail; fetch writes "<name>-1.0.0-r1.apk"
// stand-ins into -o <dir> unless apk.fetch.fail; del only records.
put(`${T}/bin/apk`, `#!/usr/bin/ucode
'use strict';
import * as fs from 'fs';
const D = '${T}';
let log = fs.open(D + '/apk.log', 'a');
log.write(join(' ', ARGV) + '\\n');
log.close();
let ci = index(ARGV, '--cache-dir');
if (ci >= 0 && fs.stat(ARGV[ci + 1])?.type != 'directory') {
	warn('ERROR: Unable to setup the cache: No such file or directory\\nERROR: Failed to open apk database: No such file or directory\\n');
	exit(99);
}
if (ARGV[0] == 'update')
	exit(fs.access(D + '/apk.update.fail') ? 1 : 0);
if (ARGV[0] == 'del')
	exit(0);
if (ARGV[0] == 'fetch') {
	if (fs.access(D + '/apk.fetch.fail')) {
		print('ERROR: bar: temporary error (try again later)\\n');
		exit(1);
	}
	let o = index(ARGV, '-o');
	for (let n in slice(ARGV, o + 2))
		fs.writefile(ARGV[o + 1] + '/' + n + '-1.0.0-r1.apk', n + ' 1.0.0-r1\\n');
	exit(0);
}
if (index(ARGV, '--simulate') >= 0) {
	if (fs.access(D + '/apk.simulate.fail')) {
		print('ERROR: unable to select packages:\\n  dnsmasq-full2 (no such package):\\n');
		exit(1);
	}
	print('(1/2) Upgrading shadow-vpn (0.1.5-r1 -> 0.2.0-r1)\\n');
	for (let n in split(trim(fs.readfile(D + '/apk.purge') ?? ''), ' '))
		if (n != '')
			print('(2/2) Purging ' + n + ' (1.0.0-r1)\\n');
	print('OK: 57.8 MiB in 196 packages\\n');
	exit(0);
}
print('(1/2) Upgrading shadow-vpn\\n');
warn('WARNING: opening something: No such file or directory\\n');
let rollback = length(filter(ARGV, (a) => index(a, '/rollback/') >= 0)) > 0;
if (fs.access(D + '/apk.fail') || (rollback && fs.access(D + '/apk.fail.rollback'))) {
	print(fs.readfile(D + '/apk.fail') ?? 'ERROR: the rollback failed\\n');
	exit(1);
}
if (fs.access(D + '/apk.noop'))
	exit(0);
let partial = !rollback && fs.access(D + '/apk.partial');
let db = [];
for (let e in split(trim(fs.readfile(D + '/db') ?? ''), '\\n\\n')) {
	let m = match(e, /^P:([^\\n]*)\\nV:([^\\n]*)/);
	if (m)
		push(db, [ m[1], m[2] ]);
}
for (let a in ARGV) {
	let p = (substr(a, -4) == '.apk') ? split(trim(fs.readfile(a) ?? ''), ' ') : null;
	if (!p || (partial && substr(p[0], 0, 5) != 'luci-'))
		continue;
	let e = filter(db, (x) => x[0] == p[0])[0];
	if (e)
		e[1] = p[1];
	else
		push(db, [ p[0], p[1] ]);
}
fs.writefile(D + '/db', join('', map(db, (x) => 'P:' + x[0] + '\\nV:' + x[1] + '\\n\\n')));
if (fs.access(D + '/apk.detach'))
	system('start-stop-daemon -S -b -x /bin/sleep -- 30');
if (fs.access(D + '/apk.disable'))
	fs.writefile(D + '/uci/shadow-vpn', replace(fs.readfile(D + '/uci/shadow-vpn'), "enabled '1'", "enabled '0'"));
if (fs.access(D + '/apk.restart') && fs.access(D + '/procd.json')) {
	let p = json(fs.readfile(D + '/procd.json'));
	for (let n in keys(p.instances))
		p.instances[n] = ++p.next;
	fs.writefile(D + '/procd.json', sprintf('%J', p));
}
if (partial || (!rollback && fs.access(D + '/apk.fail.after'))) {
	print('ERROR: dep-1.0.0-r1.post-install: script exited with error 1\\n1 error; 57 MiB in 197 packages\\n');
	exit(1);
}
`, 0o755);

put(`${T}/bin/df`, `#!/bin/sh
echo "Filesystem           1024-blocks    Used Available Capacity Mounted on"
echo "overlay                   200000    1000 $(cat ${T}/df.free 2>/dev/null || echo 90000)   1% $2"
`, 0o755);

for (let name in [ 'rpcd', 'job' ])
	put(`${T}/bin/${name}`, `#!/bin/sh\necho "${name} $*" >> ${T}/init.log\n`, 0o755);

// procd as ubus shows it, from ${T}/procd.json ({ instances: { <name>: pid }, declared: [ names ], next: pid }):
// service list, and service delete of one instance. The init script's start declares every instance of
// `declared` again, and procd starts the ones that are gone with a new pid; a running one keeps its pid.
put(`${T}/bin/ubus`, `#!/usr/bin/ucode
'use strict';
import * as fs from 'fs';
const D = '${T}';
let log = fs.open(D + '/ubus.log', 'a');
log.write(join(' ', ARGV) + '\\n');
log.close();
let p = json(fs.readfile(D + '/procd.json') ?? '{ "instances": {} }');
if (ARGV[2] == 'list') {
	let list = {};
	for (let n, pid in p.instances)
		list[n] = { running: true, pid, command: [ '/usr/libexec/shadow-vpn/' + n + '-run' ] };
	print(sprintf('%J\\n', length(list) ? { 'shadow-vpn': { instances: list } } : {}));
}
else if (ARGV[2] == 'delete') {
	delete p.instances[json(ARGV[3]).instance];
	fs.writefile(D + '/procd.json', sprintf('%J', p));
}
`, 0o755);

put(`${T}/bin/shadow-vpn`, `#!/usr/bin/ucode
'use strict';
import * as fs from 'fs';
const D = '${T}';
let log = fs.open(D + '/init.log', 'a');
log.write('shadow-vpn ' + join(' ', ARGV) + '\\n');
log.close();
let p = json(fs.readfile(D + '/procd.json') ?? 'null');
if (ARGV[0] == 'start' && p) {
	for (let n in p.declared)
		p.instances[n] ??= ++p.next;
	fs.writefile(D + '/procd.json', sprintf('%J', p));
}
`, 0o755);

// at each fsync (the automatic attempt on flash), whether the run file is still there and the at_up of the last
// result in UPDATE.state: the order in which an install leaves its files behind
put(`${T}/bin/fsync`, `#!/usr/bin/ucode
'use strict';
import * as fs from 'fs';
const D = '${T}';
let s = null;
try {
	s = json(fs.readfile(D + '/run/update.json'));
}
catch (e) { }
let log = fs.open(D + '/fsync.log', 'a');
log.write((fs.access(D + '/run/update.run.json') ? 'run ' : 'none ') + (s?.last?.at_up ?? '-') + '\\n');
log.close();
`, 0o755);

// like the real apk, the stand-in refuses a cache dir that is not there: an install that forgot to create it fails
eq('update/stubs: apk refuses a missing --cache-dir, as apk 3.0.5 does', [ run(`${T}/bin/apk update --cache-dir ${T}/nocache`).rc,
	run(`${T}/bin/apk add --cache-dir ${T}/nocache x.apk`).rc ], [ 99, 99 ]);
run(`rm -f ${T}/apk.log`);

function www(url) {
	return `${T}/www/${replace(url, /^https?:\/\//, '')}`;
}

let asset_id = 1000;

// A release in GitHub's shape: stand-in packages ("<name> <version>-r1", what the apk stub installs), SHA256SUMS
// with install.sh in it, the JSON at /tags/<v> (and /latest unless latest is false), each file at the tag's download
// URL (unless api_only) and at its asset API URL. o.edit(files, assets, rel) changes things after the sums.
function release(v, o) {
	o ??= {};

	let files = {};

	for (let n in o.names ?? [ 'shadow-vpn', 'luci-app-shadow-vpn', 'luci-i18n-shadow-vpn-ru' ])
		files[`${n}.apk`] = `${n} ${v}-r1\n`;

	files['install.sh'] = '#!/bin/sh\n';
	files.SHA256SUMS = join('', map(keys(files), (f) => `${sha256(files[f])}  ${f}\n`));

	let assets = map(keys(files), (f) => ({ name: f, url: `${UPDATE.asset_api}${++asset_id}`, size: length(files[f]),
		digest: `sha256:${sha256(files[f])}` }));
	let rel = { tag_name: v, html_url: `${UPDATE.page}tag/${v}`, published_at: '2026-10-25T12:00:00Z',
		body: o.body ?? `Changes in ${v}`, assets };

	if (o.edit)
		o.edit(files, assets, rel);

	for (let a in assets) {
		if (files[a.name] == null)
			continue;

		put(www(a.url), files[a.name]);

		if (!o.api_only)
			put(www(`${UPDATE.download}/${v}/${a.name}`), files[a.name]);
	}

	put(www(`${UPDATE.api}/tags/${v}`), sprintf('%J', rel));

	if (o.latest !== false)
		put(www(`${UPDATE.api}/latest`), sprintf('%J', rel));

	return { files, rel };
}

const UCI_TEXT = "config shadow 'main'\n\toption enabled '1'\n\toption kill_switch '1'\n\toption router_traffic '1'\n" +
	"\toption mode 'proxy-all'\n\toption update 'notify'\n";

let spawned = [], spawn_lock_free = null;

// A fresh router with Shadow 0.1.5 (no Russian pages), on, in notify mode; GitHub has nothing yet.
function reset() {
	run(`rm -rf ${T}/www ${T}/run ${T}/etc ${T}/lock ${T}/uci ${T}/*.log ${T}/apk.* ${T}/df.free ${T}/procd.json ${T}/fetch.hook ${RUN}/attention.json`);
	run(`mkdir -p ${T}/run ${T}/uci`);
	writefile(`${T}/db`, 'P:shadow-vpn\nV:0.1.5-r1\n\nP:luci-app-shadow-vpn\nV:0.1.5-r1\n\n');
	writefile(`${T}/uci/shadow-vpn`, UCI_TEXT);
	spawned = [];
	spawn_lock_free = null;
}

function opts(extra) {
	return {
		bin: `${T}/bin`, run: `${T}/run`, etc: `${T}/etc`, db: `${T}/db`, lock: LOCKFILE, confdir: `${T}/uci`, base_url: '',
		now: 1793000000, uptime: 5000, hour: 4, mode: 'notify', sleep: () => null, blocked: () => false, connected: () => true,
		spawn: (v) => {
			push(spawned, v);
			spawn_lock_free = run(`flock -n ${LOCKFILE} true`).rc == 0;
		},
		...(extra ?? {})
	};
}

function lines(path) {
	return filter(split(readfile(path) ?? '', '\n'), (l) => l != '');
}

function json_file(path) {
	try {
		return json(readfile(path) ?? 'null');
	}
	catch (e) {
		return null;
	}
}

function attention() {
	let a = {};

	for (let e in state.attention_list())
		a[e.code] = e.message;

	return a;
}

function version() {
	return update.installed({ db: `${T}/db` }).version;
}

const API_LATEST = `${UPDATE.api}/latest`;

// check

reset();
release('0.2.0');

let r = update.check(opts());

eq('update/check: ok', r, { ok: true, installed: '0.1.5', latest: '0.2.0', available: true, console: false });

let st = json_file(`${T}/run/update.json`);

eq('update/check: UPDATE.state', [ st.ok, st.error, st.installed, st.latest, st.tag, st.url, st.published, st.notes,
	st.console, st.announced, st.checked, st.checked_up, st.last ],
	[ true, null, '0.1.5', '0.2.0', '0.2.0', `${UPDATE.page}tag/0.2.0`, 1792929600, 'Changes in 0.2.0', false, '0.2.0',
		1793000000, 5000, null ]);
eq('update/check: the API with its Accept header, without -q', lines(`${T}/fetch.log`),
	[ `-T 15 --header=Accept: application/vnd.github+json -O ${W}/release.json ${API_LATEST}` ]);
eq('update/check: banner', attention().update_available, 'Shadow 0.2.0 is available.');
ok('update/check: no work dir or run file left', !access(W) && !access(`${T}/run/update.run.json`));

state.attention_dismiss('update_available');
update.check(opts());
eq('update/check: a dismissed banner stays dismissed for that version', attention().update_available, null);

update.check(opts({ mode: 'manual' }));
release('0.2.1');
update.check(opts({ mode: 'manual' }));
eq('update/check: manual mode never raises it', attention().update_available, null);
update.check(opts());
eq('update/check: the next version is announced again', [ attention().update_available, json_file(`${T}/run/update.json`).announced ],
	[ 'Shadow 0.2.1 is available.', '0.2.1' ]);

writefile(`${T}/db`, 'P:shadow-vpn\nV:0.2.1-r1\n\n');
eq('update/check: up to date clears it', [ update.check(opts()).available, attention().update_available ], [ false, null ]);
writefile(`${T}/db`, 'P:shadow-vpn\nV:0.1.5-r1\n\n');

unlink(www(API_LATEST));
unlink(`${T}/fetch.log`);
r = update.check(opts());
st = json_file(`${T}/run/update.json`);
eq('update/check: 404 is no release', [ r.ok, r.error, r.latest, r.available ], [ false, NO_RELEASE, '0.2.1', true ]);
eq('update/check: a failed check keeps the last release found', [ st.ok, st.error, st.latest, st.tag ],
	[ false, NO_RELEASE, '0.2.1', '0.2.1' ]);
eq('update/check: a 404 is asked once', length(lines(`${T}/fetch.log`)), 1);

for (let code in [ '403', '429' ]) {
	put(`${www(API_LATEST)}.status`, code);
	eq(`update/check: HTTP ${code} is the rate limit`, update.check(opts()).error, RATE);
}

let pauses = 0;

put(`${www(API_LATEST)}.status`, 'net');
unlink(`${T}/fetch.log`);
r = update.check(opts({ sleep: () => pauses++ }));
eq('update/check: network error, 3 tries with pauses', [ r.error, length(lines(`${T}/fetch.log`)), pauses ], [ UNREACHABLE, 3, 2 ]);
eq('update/check: the kill-switch hint while blocked', update.check(opts({ blocked: () => true })).error, UNREACHABLE + HINT);

put(`${www(API_LATEST)}.status`, 'sleep 5');

let t0 = time();

r = update.check(opts({ limits: { fetch_ms: 500, check_ms: 1500 } }));
eq('update/check: timeout', r.error, UNREACHABLE);
ok('update/check: the deadline kills uclient-fetch', time() - t0 <= 3, `${time() - t0} s`);

unlink(`${www(API_LATEST)}.status`);
put(www(API_LATEST), '{ "tag_name": ');
eq('update/check: unreadable release', update.check(opts()).error, UNREADABLE);

put(`${T}/www/base.test/rel/release.json`, sprintf('%J', { tag_name: '0.3.0', html_url: 'http://base.test/rel/0.3.0',
	body: 'from the base', assets: [] }));
unlink(`${T}/fetch.log`);
r = update.check(opts({ base_url: 'http://base.test/rel/' }));
st = json_file(`${T}/run/update.json`);
eq('update/check: base URL', [ r.ok, r.latest, st.url, lines(`${T}/fetch.log`) ],
	[ true, '0.3.0', 'http://base.test/rel/0.3.0', [ `-T 15 -O ${W}/release.json http://base.test/rel/release.json` ] ]);
put(`${T}/run/update.base_url`, 'http://base.test/rel\n');
eq('update/check: base URL from RUN/update.base_url', update.check(opts()).latest, '0.3.0');

// install

const ADD = `add --cache-dir ${W}/cache --cache-predownload --allow-untrusted`;

reset();
release('0.2.0');
r = update.install(opts());
eq('update/install: result', r, { ok: true, changed: true, from: '0.1.5', to: '0.2.0' });
eq('update/install: apk as install.sh runs it, Russian not added', lines(`${T}/apk.log`), [ `update --cache-dir ${W}/cache`,
	`${ADD} ${W}/shadow-vpn.apk ${W}/luci-app-shadow-vpn.apk` ]);
eq('update/install: installed', update.installed({ db: `${T}/db` }),
	{ version: '0.2.0', packages: { 'shadow-vpn': '0.2.0-r1', 'luci-app-shadow-vpn': '0.2.0-r1' } });
eq('update/install: files from the tag path', filter(map(lines(`${T}/fetch.log`), (l) => split(l, ' ')[-1]),
	(u) => index(u, '/releases/download/') > 0), [ `${UPDATE.download}/0.2.0/SHA256SUMS`, `${UPDATE.download}/0.2.0/shadow-vpn.apk`,
	`${UPDATE.download}/0.2.0/luci-app-shadow-vpn.apk` ]);
eq('update/install: rpcd reloaded, Shadow not restarted (still on)', lines(`${T}/init.log`), [ 'rpcd reload' ]);

st = json_file(`${T}/run/update.json`);
eq('update/install: last', st.last, { ok: true, changed: true, from: '0.1.5', to: '0.2.0', error: null, auto: false,
	rolled_back: null, at: 1793000000, at_up: 5000 });
ok('update/install: run file and work dir removed', !access(`${T}/run/update.run.json`) && !access(W));
eq('update/install: banners cleared', [ attention().update_available, attention().update_failed ], [ null, null ]);

r = update.install(opts({ uptime: 7000 }));
eq('update/install: not newer', [ r, length(lines(`${T}/apk.log`)) ], [ { ok: true, changed: false, version: '0.2.0' }, 2 ]);
eq('update/install: not newer records nothing', json_file(`${T}/run/update.json`).last.at_up, 5000);

reset();
release('0.2.0', { api_only: true });
r = update.install(opts());

let api_lines = filter(lines(`${T}/fetch.log`), (l) => index(l, UPDATE.asset_api) >= 0);

eq('update/install: asset API fallback', [ r.ok, version(), length(api_lines) ], [ true, '0.2.0', 3 ]);
ok('update/install: asset API with Accept: application/octet-stream',
	length(filter(api_lines, (l) => index(l, '--header=Accept: application/octet-stream') >= 0)) == 3, sprintf('%J', api_lines));

// the stand-ins of 0.1.5 for the rollback: the same names, at the installed version's own tag
function failing(edit, extra) {
	reset();
	release('0.2.0', { edit });

	let res = update.install(opts(extra));

	ok('update/install: failure leaves no run file, no work dir and the old version',
		!access(`${T}/run/update.run.json`) && !access(W) && version() == '0.1.5', sprintf('%J', res));

	return res;
}

r = failing((f) => f['shadow-vpn.apk'] = replace(f['shadow-vpn.apk'], '0.2.0', '9.9.9'));
eq('update/install: checksum mismatch', [ r.ok, r.changed, r.error ],
	[ false, false, 'The checksum of shadow-vpn.apk does not match SHA256SUMS: the file is damaged or was replaced.' ]);
eq('update/install: a failure is the last result', json_file(`${T}/run/update.json`).last.error, r.error);

r = failing((f) => f['shadow-vpn.apk'] += 'x');
eq('update/install: size mismatch', r.error, 'The size of shadow-vpn.apk does not match the release.');

r = failing((f, a) => a[0].digest = `sha256:${HASH}`);
eq('update/install: GitHub digest mismatch', r.error, 'GitHub lists another checksum for shadow-vpn.apk than SHA256SUMS.');

r = failing((f, a) => {
	f.SHA256SUMS = 'not a sum\n';
	a[4].size = length(f.SHA256SUMS);
});
eq('update/install: malformed sums', r.error, 'SHA256SUMS is malformed.');

r = failing((f, a) => a[0].size = UPDATE.file_max + 1);
eq('update/install: a too large asset is refused before downloading', [ r.error, index(readfile(`${T}/fetch.log`), 'shadow-vpn.apk') ],
	[ 'The size of shadow-vpn.apk does not match the release.', -1 ]);

r = failing((f, a, rel) => rel.body = 'Big change.\r\nshadow-update: console\r\n');
eq('update/install: console-only release', [ r.error, lines(`${T}/apk.log`) ],
	[ 'Shadow 0.2.0 must be installed with the install command from the console.', [] ]);

r = failing(null, { blocked: () => true });
eq('update/install: full mode refuses while the kill switch blocks', [ r.error, lines(`${T}/fetch.log`) ],
	[ 'Shadow blocks the router’s own downloads while its tunnel is down (kill switch). Turn Shadow off, update, then turn it back on.', [] ]);

r = failing((f, a) => {
	put(`${www(`${UPDATE.download}/0.2.0/shadow-vpn.apk`)}.status`, 'net');
	put(`${www(a[0].url)}.status`, 'net');
}, { blocked: () => true, config: { main: { enabled: true, mode: 'selected-rules', kill_switch: true, router_traffic: true } } });
eq('update/install: split mode tries, and explains a failed download', r.error,
	'Could not download shadow-vpn.apk from GitHub.' + HINT);

r = failing(null, { now: 1000 });
eq('update/install: wrong clock', r.error,
	'The router clock is wrong, so HTTPS does not work. Check time synchronization in System → System.');

writefile(`${T}/df.free`, '3000');
r = update.install(opts());
eq('update/install: space', r.error, 'Not enough space on the router: 2 MB free, 5 MB needed.');
unlink(`${T}/df.free`);
r = update.install(opts({ limits: { mem_kb: 1073741824 } }));
ok('update/install: memory', match(r.error, /^Not enough free memory: [0-9]+ MB available, 1048576 MB needed\.$/) != null, r.error);

writefile(`${T}/db`, '');
eq('update/install: unknown version', update.install(opts()).error, 'The installed Shadow version is unknown.');

r = failing((f) => writefile(`${T}/apk.fail`, 'ERROR: unable to select packages:\n  dnsmasq-full (no such package):\n'));
eq('update/install: apk failure with its ERROR line', [ r.error, r.changed ],
	[ 'The package manager could not install the update: ERROR: unable to select packages:', false ]);

r = failing((f) => writefile(`${T}/apk.noop`, ''));
eq('update/install: apk that installs nothing', r.error, 'The package manager did not install Shadow 0.2.0.');

// apk 3 exits non-zero when a package script failed, also after the transaction went through: the database decides
reset();
release('0.2.0');
writefile(`${T}/apk.fail.after`, '');
r = update.install(opts());
eq('update/install: apk exits 1, but the release is installed', [ r, version(), lines(`${T}/init.log`) ],
	[ { ok: true, changed: true, from: '0.1.5', to: '0.2.0' }, '0.2.0', [ 'rpcd reload' ] ]);

reset();
release('0.2.0');
writefile(`${T}/apk.partial`, '');
r = update.install(opts());
eq('update/install: apk installs part of the release (manual): reported, with rpcd and LuCI reloaded',
	[ r, version(), update.installed({ db: `${T}/db` }).packages['luci-app-shadow-vpn'], lines(`${T}/init.log`) ],
	[ { ok: false, changed: true, from: '0.1.5', to: '0.2.0',
		error: 'The package manager could not install the update: ERROR: dep-1.0.0-r1.post-install: script exited with error 1' },
		'0.1.5', '0.2.0-r1', [ 'rpcd reload' ] ]);

// Shadow removed from the console while the files downloaded: installing would bring it back
reset();
release('0.2.0');
writefile(`${T}/fetch.hook`, `printf '' > ${T}/db`);
r = update.install(opts());
eq('update/install: Shadow removed during the downloads is not installed again', [ r.error, r.changed, lines(`${T}/apk.log`), version() ],
	[ 'The installed Shadow version is unknown.', false, [], null ]);

// an upgrade keeps Shadow on: the init script starts it when the packages turned it off
reset();
release('0.2.0');
writefile(`${T}/apk.disable`, '');
r = update.install(opts());
eq('update/install: Shadow on again after the upgrade', [ r.ok, lines(`${T}/init.log`), match(readfile(`${T}/uci/shadow-vpn`),
	/enabled '1'/) != null ], [ true, [ 'shadow-vpn start', 'rpcd reload' ], true ]);

// and one that was off when apk ran stays off, whatever the config said when the run started
reset();
release('0.2.0');
writefile(`${T}/uci/shadow-vpn`, replace(UCI_TEXT, "enabled '1'", "enabled '0'"));
r = update.install(opts({ config: { main: { enabled: true, mode: 'proxy-all' } } }));
eq('update/install: Shadow turned off meanwhile stays off', [ r.ok, lines(`${T}/init.log`), match(readfile(`${T}/uci/shadow-vpn`),
	/enabled '0'/) != null ], [ true, [ 'rpcd reload' ], true ]);

// the lock

reset();
release('0.2.0');
state.mkdir_p(`${T}/lock`);

let held = open(LOCKFILE, 'ae', 0o600);

held.lock('xn');
eq('update/lock: busy', [ update.check(opts()), update.install(opts()), update.install(opts(), '0.2.0'), update.due(opts()) ], [
	{ ok: false, error: 'Shadow is already checking for or installing an update. Try again in a minute.' },
	{ ok: false, error: 'An update is already running.' }, { ok: true, changed: false, skipped: 'busy' }, { ok: true, skipped: 'busy' }
]);
ok('update/lock: busy records nothing', !access(`${T}/run/update.json`) && !access(`${T}/fetch.log`) && !access(`${T}/etc/update.state`));
held.close();

// a separate process, as the CLI: stdout carries only the JSON line, and the daemon apk's scripts leave behind
// holds neither the lock nor that stdout
writefile(`${T}/apk.detach`, '');
put(`${T}/driver.uc`, `'use strict';
import { readfile } from 'fs';
import { install } from 'shadow-vpn.update';
let o = json(readfile('${T}/opts.json'));
o.sleep = () => null;
o.blocked = () => false;
o.connected = () => true;
print(sprintf('%J', install(o)), '\\n');
`);
let o = opts();

for (let k in [ 'sleep', 'blocked', 'connected', 'spawn' ])
	delete o[k];

writefile(`${T}/opts.json`, sprintf('%J', o));
t0 = time();

let p = popen(`ucode -L ${MODS} ${T}/driver.uc </dev/null 2>/dev/null`, 'r');
let out = p.read('all');

p.close();

// start-stop-daemon -b returns before its child has become the daemon
let daemon = '';

for (let i = 0; i < 20 && daemon == ''; i++, sleep(100))
	daemon = trim(run("pgrep -f '[b]in/sleep 30'").out);

eq('update/process: stdout is one JSON line', [ length(split(trim(out), '\n')), json(out) ],
	[ 1, { ok: true, changed: true, from: '0.1.5', to: '0.2.0' } ]);
ok('update/process: the run does not wait for the daemon', time() - t0 < 20 && daemon != '', `${time() - t0} s, ${daemon}`);
eq('update/process: the lock is free while the daemon lives', run(`flock -n ${LOCKFILE} true`).rc, 0);
run(`kill ${daemon}`);

// the CLI as cron and the jobs run it: the real paths, the stand-ins on PATH, files from a base URL
reset();
put(`${T}/www/base.test/rel/release.json`, sprintf('%J', { tag_name: '0.3.0', html_url: 'http://base.test/rel/0.3.0', assets: [] }));

const CLI = `PATH=${T}/bin:$PATH SHADOW_BASE_URL=http://base.test/rel ucode -L ${MODS} ${LIBEXEC}/update`;

// stdout only, and the exit code after it
function cli(args) {
	let p = popen(`${CLI} ${args} </dev/null 2>/dev/null; echo "rc=$?"`, 'r');
	let text = p.read('all'), at = rindex(text, 'rc=');

	p.close();

	return { rc: int(substr(text, at + 3)), out: substr(text, 0, at) };
}

let c = cli('check');

eq('update/cli: check prints one JSON line', [ c.rc, length(split(trim(c.out), '\n')), json(c.out).ok, json(c.out).latest ],
	[ 0, 1, true, '0.3.0' ]);
c = cli('install');
eq('update/cli: install with no Shadow installed', [ c.rc, json(c.out) ],
	[ 1, { ok: false, changed: false, from: null, to: null, error: 'The installed Shadow version is unknown.' } ]);
eq('update/cli: usage', [ cli('').rc, cli('bogus').rc, cli('install --auto 1.2').rc, cli('check now').rc, cli('due x').rc,
	cli('install --auto 1.2.3 x').rc, cli('bogus').out ], [ 2, 2, 2, 2, 2, 2, '' ]);
ok('update/cli: the real UPDATE files', access(UPDATE.state) && !access(UPDATE.run) && !access(UPDATE.work) &&
	run(`flock -n ${UPDATE.lock} true`).rc == 0);
run(`rm -f ${UPDATE.state} ${UPDATE.lock}`);

// settle and rollback: Shadow was connected; the stub verdict says whether the tunnel came back

// one answer per call, the last one for good; the first call asks whether Shadow was connected before
function verdicts(list) {
	let polls = [ ...list ];

	return () => (length(polls) > 1) ? shift(polls) : polls[0];
}

// Shadow 0.1.5 on and connected, procd running its xray and ssh instances; GitHub still has the 0.1.5 release
function connected_router() {
	reset();
	release('0.1.5', { names: [ 'shadow-vpn', 'luci-app-shadow-vpn' ], latest: false });
	release('0.2.0');
	writefile(`${T}/run/active`, '');
	writefile(`${T}/procd.json`, sprintf('%J', { instances: { xray: 100, ssh: 101 }, declared: [ 'xray', 'ssh' ], next: 101 }));
}

function pids() {
	return json(readfile(`${T}/procd.json`)).instances;
}

function deletes() {
	return filter(lines(`${T}/ubus.log`), (l) => index(l, ' delete ') >= 0);
}

const DELETE = 'call service delete { "name": "shadow-vpn", "instance": ';

connected_router();
state.attention_add('update_available', 'Shadow 0.2.0 is available.');
r = update.install(opts({ limits: { settle: 30 } }));
eq('update/settle: back and stable', r, { ok: true, changed: true, from: '0.1.5', to: '0.2.0' });
eq('update/settle: procd kept the instances over the upgrade, so they are declared again and run the new code',
	[ deletes(), lines(`${T}/init.log`), pids() ],
	[ [ `${DELETE}"xray" }`, `${DELETE}"ssh" }` ], [ 'rpcd reload', 'shadow-vpn start' ], { xray: 102, ssh: 103 } ]);

connected_router();
writefile(`${T}/apk.restart`, '');
r = update.install(opts({ limits: { settle: 30 } }));
eq('update/settle: instances the upgrade restarted already are left alone', [ r.ok, deletes(), lines(`${T}/init.log`) ],
	[ true, [], [ 'rpcd reload' ] ]);

// an instance that procd does not start again: the new code never ran, so nothing came back
connected_router();
writefile(`${T}/procd.json`, sprintf('%J', { instances: { xray: 100 }, declared: [], next: 100 }));
eq('update/settle: an instance that does not run again is no tunnel back', update.install(opts({ limits: { settle: 6 } })).error,
	'Shadow 0.2.0 was installed, but the tunnel did not come back within 6 s.');

// right after apk the state may still say connected from before; only a verdict that holds for `stable` s counts
connected_router();
state.attention_add('update_available', 'Shadow 0.2.0 is available.');
r = update.install(opts({ connected: verdicts([ true, true, true, true, true, true, false ]), limits: { settle: 30 } }));
eq('update/settle: connected on the first polls (8 s), then down: not back', r, { ok: false, changed: true, from: '0.1.5',
	to: '0.2.0', error: 'Shadow 0.2.0 was installed, but the tunnel did not come back within 30 s.' });
eq('update/settle: manual keeps the new version, and its banner goes with the failure', [ version(), attention().update_available ],
	[ '0.2.0', null ]);

connected_router();
r = update.install(opts({ connected: verdicts([ true, false, false, true ]), limits: { settle: 30 } }));
eq('update/settle: back after a while, and stays for 10 s', r.ok, true);

connected_router();
writefile(`${T}/apk.purge`, 'bar');
r = update.install(opts({ connected: verdicts([ true, false, false, false, true ]), limits: { settle: 6, stable: 2 } }), '0.2.0');
eq('update/rollback: automatic install put back', r, { ok: false, changed: false, from: '0.1.5', to: '0.2.0', rolled_back: true,
	error: 'Shadow 0.2.0 was installed, but the tunnel did not come back, so Shadow 0.1.5 was put back.' });
eq('update/rollback: apk: a dry run, what it would purge fetched, the release, then the previous version and that, offline',
	slice(lines(`${T}/apk.log`), 1), [
		`add --simulate --no-network --cache-dir ${W}/cache --allow-untrusted ${W}/shadow-vpn.apk ${W}/luci-app-shadow-vpn.apk`,
		`fetch --cache-dir ${W}/cache -o ${W}/rollback/deps bar`,
		`${ADD} ${W}/shadow-vpn.apk ${W}/luci-app-shadow-vpn.apk`,
		`add --no-network --cache-dir ${W}/cache --allow-untrusted ${W}/rollback/shadow-vpn.apk ${W}/rollback/luci-app-shadow-vpn.apk ` +
			`${W}/rollback/deps/bar-1.0.0-r1.apk`,
		'del --no-network bar'
	]);
eq('update/rollback: the old version again, its instances restarted too', [ version(), length(deletes()), pids() ],
	[ '0.1.5', 4, { xray: 104, ssh: 105 } ]);
eq('update/rollback: the attempt on flash', json_file(`${T}/etc/update.state`), { version: '0.2.0', tries: 1, at: 1793000000,
	finished: true, ok: false, error: r.error });
eq('update/rollback: attention', attention().update_failed, `The automatic update to 0.2.0 failed: ${r.error}`);
eq('update/rollback: last', [ json_file(`${T}/run/update.json`).last.auto, json_file(`${T}/run/update.json`).last.rolled_back ],
	[ true, true ]);
// fsync runs as the attempt goes to flash: before the download (no result yet), and at the end, when UPDATE.state
// has the result already and the run file is still there (rpcd reads the run file first)
eq('update/rollback: the attempt before the download; the result before the run file goes', lines(`${T}/fsync.log`),
	[ 'run -', 'run -', 'run 5000', 'run 5000' ]);

writefile(`${T}/apk.fail.rollback`, '');
r = update.install(opts({ connected: verdicts([ true, false ]), limits: { settle: 2 } }), '0.2.0');
eq('update/rollback: failed', [ r.ok, r.changed, r.rolled_back, r.error, version() ], [ false, true, false,
	'Shadow 0.2.0 was installed, but the tunnel did not come back, and putting Shadow 0.1.5 back failed: ERROR: the rollback failed',
	'0.2.0' ]);
eq('update/rollback: the second attempt is counted', json_file(`${T}/etc/update.state`).tries, 2);
update.due(opts({ uptime: 5001 }));
eq('update/rollback: a failed rollback keeps its banner, though its version is installed', attention().update_failed,
	`The automatic update to 0.2.0 failed: ${r.error}`);

// apk exits 1 after it installed the release: the tunnel decides, as after any install
connected_router();
writefile(`${T}/apk.fail.after`, '');
r = update.install(opts({ connected: verdicts([ true, false ]), limits: { settle: 6 } }), '0.2.0');
eq('update/rollback: apk exited 1 after installing, the tunnel did not come back: put back', [ r.rolled_back, r.error, version() ],
	[ true, 'Shadow 0.2.0 was installed, but the tunnel did not come back, so Shadow 0.1.5 was put back.', '0.1.5' ]);

connected_router();
writefile(`${T}/apk.partial`, '');
r = update.install(opts({ limits: { settle: 6, stable: 2 } }), '0.2.0');
eq('update/rollback: a release that went in only in part is put back',
	[ r, version(), update.installed({ db: `${T}/db` }).packages['luci-app-shadow-vpn'] ],
	[ { ok: false, changed: false, from: '0.1.5', to: '0.2.0', rolled_back: true,
		error: 'The package manager could not install the update: ERROR: dep-1.0.0-r1.post-install: script exited with error 1' },
		'0.1.5', '0.1.5-r1' ]);

function installs() {
	return filter(lines(`${T}/apk.log`), (l) => substr(l, 0, 4) == 'add ' && index(l, '--simulate') < 0);
}

connected_router();
writefile(`${T}/apk.purge`, 'bar');
writefile(`${T}/apk.fetch.fail`, '');
r = update.install(opts(), '0.2.0');
eq('update/rollback: what the upgrade would purge cannot be fetched: no automatic install', [ r.error, r.changed, installs(), version() ],
	[ 'The packages of the installed Shadow 0.1.5 could not be downloaded for a rollback, so it was not updated automatically.',
		false, [], '0.1.5' ]);

connected_router();
writefile(`${T}/apk.simulate.fail`, '');
r = update.install(opts(), '0.2.0');
eq('update/rollback: a dry run that fails stops before anything changes', [ r.error, r.changed, installs(), version() ],
	[ 'The package manager could not install the update: ERROR: unable to select packages:', false, [], '0.1.5' ]);

// turned off (or removed) from the console during the wait: no tunnel to wait for, and putting the packages
// back would start Shadow again
connected_router();

let calls = 0;

r = update.install(opts({ limits: { settle: 6 }, connected: () => {
	if (++calls == 2)
		writefile(`${T}/uci/shadow-vpn`, replace(UCI_TEXT, "enabled '1'", "enabled '0'"));

	return calls == 1;
} }), '0.2.0');
eq('update/rollback: Shadow turned off during the wait is not put back', [ r, version(), length(installs()) ],
	[ { ok: false, changed: true, from: '0.1.5', to: '0.2.0', error: 'Shadow 0.2.0 was installed, but the tunnel did not come back within 6 s.' },
		'0.2.0', 1 ]);

reset();
release('0.2.0');
r = update.install(opts(), '0.2.0');
eq('update/rollback: no packages of the installed version, no automatic install', [ r.error, lines(`${T}/apk.log`), version() ],
	[ 'The packages of the installed Shadow 0.1.5 could not be downloaded for a rollback, so it was not updated automatically.',
		[], '0.1.5' ]);
eq('update/rollback: that counts as an attempt', json_file(`${T}/etc/update.state`),
	{ version: '0.2.0', tries: 1, at: 1793000000, finished: true, ok: false, error: r.error });

reset();
release('0.2.0');
r = update.install(opts(), '0.1.9');
eq('update/install --auto: a newer release than due saw is left to the next due', [ r, access(`${T}/etc/update.state`),
	json_file(`${T}/run/update.json`).last ], [ { ok: true, changed: false, version: '0.1.5' }, null, null ]);

// stopped before any download (here: the space on flash): still an attempt, so due starts it once a night
const SPACE = 'Not enough space on the router: 2 MB free, 5 MB needed.';

reset();
release('0.2.0');
writefile(`${T}/df.free`, '3000');
r = update.install(opts(), '0.2.0');
eq('update/install --auto: a failed precondition is a counted attempt', [ r.error, json_file(`${T}/etc/update.state`),
	attention().update_failed, lines(`${T}/apk.log`) ], [ SPACE, { version: '0.2.0', tries: 1, at: 1793000000, finished: true,
	ok: false, error: SPACE }, `The automatic update to 0.2.0 failed: ${SPACE}`, [] ]);

// the nights after: due every hour of the window spawns the install job, which fails the same way
let night_runs = [], banners = [];

for (let night = 0; night < 4; night++) {
	for (let hour = 3; hour < 6; hour++) {
		let t = 1793000000 + night * 86400 + (hour - 3) * 3600;
		let o = { mode: 'auto', hour, now: t, uptime: 5000 + t - 1793000000 };

		state.attention_dismiss('update_failed');
		update.due(opts({ ...o, spawn: (v) => push(night_runs, `${night}:${hour} ${update.install(opts(o), v).error == SPACE}`) }));

		if (attention().update_failed)
			push(banners, `${night}:${hour}`);
	}
}

eq('update/due: a failing precondition is tried once a night and three times in all, its banner once each',
	[ night_runs, banners, json_file(`${T}/etc/update.state`).tries ], [ [ '1:3 true', '2:3 true' ], [ '1:3', '2:3' ], 3 ]);

// due

reset();
release('0.2.0');
state.attention_add('update_available', 'Shadow 0.1.9 is available.');
eq('update/due: manual clears the banner and asks nobody', [ update.due(opts({ mode: 'manual' })), attention().update_available,
	access(`${T}/fetch.log`) ], [ { ok: true, mode: 'manual' }, null, null ]);

r = update.due(opts());
eq('update/due: notify checks when nothing was checked yet', [ r, attention().update_available ],
	[ { ok: true, mode: 'notify', checked: true, available: true }, 'Shadow 0.2.0 is available.' ]);
state.attention_dismiss('update_available');

const DAY = UPDATE.interval - UPDATE.slack, RETRY = UPDATE.retry - UPDATE.slack;

eq('update/due: not again within the day (slack)', [ update.due(opts({ uptime: 5000 + DAY - 1 })).checked,
	length(lines(`${T}/fetch.log`)) ], [ false, 1 ]);
eq('update/due: again after a day less the slack', [ update.due(opts({ uptime: 5000 + DAY })).checked,
	length(lines(`${T}/fetch.log`)), attention().update_available ], [ true, 2, null ]);

put(`${www(API_LATEST)}.status`, 'net');
r = update.due(opts({ uptime: 5000 + 2 * DAY }));
eq('update/due: a failed check', [ r.ok, r.checked, r.error, r.available ], [ false, true, UNREACHABLE, true ]);
eq('update/due: retried sooner after a failure', [ update.due(opts({ uptime: 5000 + 2 * DAY + RETRY - 1 })).checked,
	update.due(opts({ uptime: 5000 + 2 * DAY + RETRY })).checked ], [ false, true ]);
unlink(`${www(API_LATEST)}.status`);

state.attention_add('update_available', 'Shadow 0.2.0 is available.');
writefile(`${T}/db`, 'P:shadow-vpn\nV:0.2.0-r1\n\n');
eq('update/due: installed meanwhile clears the banner without asking', [ update.due(opts({ uptime: 5000 + 2 * DAY + RETRY + 1 })).checked,
	attention().update_available ], [ false, null ]);

// auto mode
reset();
release('0.2.0');

const AUTO = { mode: 'auto' };

eq('update/due: auto outside the night window', [ update.due(opts({ ...AUTO, hour: 2 })).spawned, update.due(opts({ ...AUTO, hour: 6,
	uptime: 6000 })).spawned, spawned ], [ null, null, [] ]);
r = update.due(opts({ ...AUTO, hour: 3 }));
eq('update/due: auto at night starts the install, the lock closed first', [ r.spawned, spawned, spawn_lock_free ], [ '0.2.0', [ '0.2.0' ], true ]);
ok('update/due: due records no attempt itself', !access(`${T}/etc/update.state`));

function attempt(tries, finished, at) {
	put(`${T}/etc/update.state`, sprintf('%J\n', { version: '0.2.0', tries, at: at ?? 1793000000, finished, ok: false, error: 'x' }));
}

attempt(1, true);
spawned = [];
eq('update/due: once a night', [ update.due(opts({ ...AUTO, now: 1793000000 + 3600 })).spawned,
	update.due(opts({ ...AUTO, now: 1793000000 + UPDATE.attempt_gap })).spawned ], [ null, '0.2.0' ]);
attempt(3, true);
eq('update/due: at most 3 tries a version', update.due(opts({ ...AUTO, now: 1793000000 + 10 * UPDATE.attempt_gap })).spawned, null);

attempt(1, false, 1793000000 - UPDATE.attempt_gap);
r = update.due(opts(AUTO));
eq('update/due: an interrupted attempt', [ json_file(`${T}/etc/update.state`), attention().update_failed ],
	[ { version: '0.2.0', tries: 1, at: 1793000000 - UPDATE.attempt_gap, finished: true, ok: false,
		error: 'The automatic update to 0.2.0 was interrupted.' }, 'The automatic update to 0.2.0 was interrupted.' ]);
eq('update/due: after the gap it tries again', r.spawned, '0.2.0');

unlink(`${T}/etc/update.state`);
eq('update/due: never while the kill switch blocks', update.due(opts({ ...AUTO, blocked: () => true })).spawned, null);
put(`${T}/run/update.run.json`, '{ "pid": 1, "stage": "install" }');
update.due(opts(AUTO));
ok('update/due: the run file of a killed install goes', !access(`${T}/run/update.run.json`));

release('0.2.0', { body: 'shadow-update: console' });
eq('update/due: never a console-only release', update.due(opts({ ...AUTO, uptime: 5000 + 2 * DAY })).spawned, null);

// its own check failed: the install would ask the same GitHub again (an earlier check still knows 0.2.0)
reset();
release('0.2.0');
update.check(opts());
put(`${www(API_LATEST)}.status`, 'net');
r = update.due(opts({ ...AUTO, uptime: 5000 + DAY }));
eq('update/due: no automatic install right after its own check failed', [ r.ok, r.checked, r.available, r.spawned, spawned ],
	[ false, true, true, null, [] ]);

// update_failed follows what is installed: it goes once its version (or a later one) got installed another way
reset();
release('0.2.0', { edit: (f) => f['shadow-vpn.apk'] = replace(f['shadow-vpn.apk'], '0.2.0', '9.9.9') });

const CHECKSUM_FAILED = 'The automatic update to 0.2.0 failed: The checksum of shadow-vpn.apk does not match SHA256SUMS: ' +
	'the file is damaged or was replaced.';

update.install(opts(), '0.2.0');
update.due(opts({ uptime: 5001 }));
eq('update/banners: a failed automatic update stays while nothing else is installed', attention().update_failed, CHECKSUM_FAILED);
writefile(`${T}/db`, 'P:shadow-vpn\nV:0.2.0-r1\n\n');
update.due(opts({ uptime: 5002 }));
eq('update/banners: ...and goes once its version is installed from the console', attention().update_failed, null);

state.attention_add('update_failed', 'The automatic update to 0.1.9 failed: x', { version: '0.1.9', installed: '0.1.5' });
update.due(opts({ mode: 'manual' }));
eq('update/banners: a later version installed counts too, in every mode', attention().update_failed, null);
state.attention_add('update_failed', 'The automatic update to 0.3.0 failed: x', { version: '0.3.0', installed: '0.1.5' });
update.install(opts({ uptime: 5003 }));
eq('update/banners: not for an older version installed', attention().update_failed, 'The automatic update to 0.3.0 failed: x');
state.attention_add('update_failed', 'The automatic update to 0.2.0 failed: x', { version: '0.2.0', installed: '0.1.5' });
eq('update/banners: an install that finds nothing newer clears it as well', [ update.install(opts({ uptime: 5004 })).changed,
	attention().update_failed ], [ false, null ]);

// an attempt killed after apk installed its version: it skipped the wait for the tunnel, so the banner comes, and
// stays until another install moves the version on
reset();
release('0.2.0');
writefile(`${T}/db`, 'P:shadow-vpn\nV:0.2.0-r1\n\n');
attempt(1, false, 1793000000 - 3600);
update.due(opts({ ...AUTO, uptime: 5001 }));
update.due(opts({ ...AUTO, uptime: 5002 }));
eq('update/due: an attempt interrupted after its install', [ attention().update_failed, json_file(`${T}/etc/update.state`).finished ],
	[ 'The automatic update to 0.2.0 was interrupted.', true ]);

// What an updater of an older version reads of the newer runtime it has just installed and of its own files
// (DESIGN.md 11.1, Compatibility): these stay, whatever a later release changes around them.
const SRC = (f) => readfile(`${MODS}/shadow-vpn/${f}`) ?? '';
const INIT = readfile(`${MODS}/../../../etc/init.d/shadow-vpn`) ?? '';

eq('update/compat: the updater\'s own paths and GitHub', [ C.REPO, UPDATE.api, UPDATE.download, UPDATE.asset_api, UPDATE.state,
	UPDATE.run, UPDATE.work, UPDATE.base_url, UPDATE.auto, UPDATE.lock ], [ 'stansful/ssh-vpn-client-luci-app-shadow-ucode',
	'https://api.github.com/repos/stansful/ssh-vpn-client-luci-app-shadow-ucode/releases',
	'https://github.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/releases/download',
	'https://api.github.com/repos/stansful/ssh-vpn-client-luci-app-shadow-ucode/releases/assets/', '/var/run/shadow-vpn/update.json',
	'/var/run/shadow-vpn/update.run.json', '/var/run/shadow-vpn/update.work', '/var/run/shadow-vpn/update.base_url',
	'/etc/shadow-vpn/update.state', '/var/lock/shadow-vpn-update.lock' ]);
ok('update/compat: RUN/state.json with the phase connected', C.RUN == '/var/run/shadow-vpn' &&
	index(SRC('state.uc'), 'const STATE = `${RUN}/state.json`') >= 0 &&
	match(SRC('state.uc'), /const PHASES = \[[^\]]*'connected'/) != null);
ok('update/compat: xray\'s metrics at 127.0.0.1:12348/debug/vars, observatory.proxy.alive', C.PORT_METRICS == 12348 &&
	index(SRC('xray.uc'), 'listen: `127.0.0.1:${PORT_METRICS}`') >= 0 && index(SRC('state.uc'), 'GET /debug/vars') >= 0 &&
	index(SRC('state.uc'), 'vars?.observatory?.proxy') >= 0 && index(SRC('xray.uc'), "subjectSelector: [ 'proxy' ]") >= 0 &&
	index(SRC('state.uc'), 'proxy.alive === true') >= 0);
ok('update/compat: uci shadow-vpn.main.enabled, the procd service of /etc/init.d/shadow-vpn', C.UCI == 'shadow-vpn' &&
	match(SRC('config.uc'), /const MAIN_BOOLS = \[ 'enabled',/) != null &&
	match(INIT, /\nUSE_PROCD=1\n/) != null && match(INIT, /\nstart_service\(\) \{/) != null &&
	match(INIT, /procd_open_instance [a-z]+/) != null);

run(`rm -rf ${T} ${RUN} /var/lock/shadow-vpn-update.lock`);

done();
