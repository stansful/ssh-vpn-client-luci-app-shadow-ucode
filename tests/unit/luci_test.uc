'use strict';

// LuCI area: the rpcd plugin against contract stubs (tests/unit/luci/stubs), the ACL, the menu and the catalogs.
// The plugin uses the default UCI directory, so /etc/config/shadow-vpn is backed up and restored around the run.

import { readfile, writefile, unlink, access, mkdir, readlink } from 'fs';
import { cursor } from 'uci';

const SRC = '/src';
const APP = SRC + '/luci-app-shadow-vpn';
const PLUGIN = APP + '/root/usr/share/rpcd/ucode/luci.shadow-vpn';
const FIX = SRC + '/tests/unit/luci';
const ROOT = '/tmp/shv-luci';
const ETC = ROOT + '/etc', RUN = ROOT + '/run';
const UCI_FILE = '/etc/config/shadow-vpn';
const LEASES = '/tmp/dhcp.leases';
const APK_DB = ROOT + '/apk-installed';
const UPDATE_STATE = RUN + '/update.json', UPDATE_RUN = RUN + '/update.run.json', UPDATE_AUTO = ETC + '/update.state';

const CONTRACT = [
	'status', 'set_enabled', 'select', 'servers', 'server_save', 'server_delete', 'hostkey_pin', 'hostkey_forget',
	'keys', 'key_save', 'key_delete', 'key_show', 'profiles', 'profiles_import', 'profile_rename', 'profile_pin',
	'profile_delete', 'profiles_delete_unpinned', 'profile_link', 'lists', 'list_set', 'list_refresh', 'list_view',
	'rules', 'rule_add', 'rule_set', 'rule_delete', 'rules_import', 'rules_export', 'leases', 'check', 'job_status',
	'logs', 'logs_clear', 'attention_dismiss', 'update_status', 'update_check', 'update_install'
];
const IMPORTS = [ 'const', 'config', 'secrets', 'state', 'links', 'validate', 'lists', 'keys' ];

const L1 = 'vless://11111111-1111-4111-8111-111111111111@nl.example.net:443?type=tcp&security=reality#Amsterdam';
const L2 = 'vless://22222222-2222-4222-8222-222222222222@de.example.net:8443?type=xhttp&security=reality#Frankfurt';
const L3 = 'vless://33333333-3333-4333-8333-333333333333@old.example.org:80?type=h2&security=none#Old';

let failures = 0;

function check(name, cond, why) {
	if (cond) {
		print(`ok ${name}\n`);
	}
	else {
		failures++;
		print(`not ok ${name}: ${why ?? 'assertion failed'}\n`);
	}
}

function fp(c) {
	let s = 'SHA256:';

	for (let i = 0; i < 43; i++)
		s += c;

	return s;
}

function sh(cmd) {
	return system(cmd);
}

function uci_get(sec, opt) {
	return cursor().get('shadow-vpn', sec, opt);
}

function uci_set(sec, opt, value) {
	const c = cursor();

	c.set('shadow-vpn', sec, opt, value);
	c.commit('shadow-vpn');
}

function jobs_log() {
	return readfile(ROOT + '/jobs.log') ?? '';
}

function clear_jobs_log() {
	writefile(ROOT + '/jobs.log', '');
}

function setup() {
	sh(`rm -rf ${ROOT}; mkdir -p ${ETC} ${RUN}/jobs ${ROOT}/libexec ${ROOT}/backup`);

	for (let f in [ UCI_FILE, LEASES ])
		if (access(f))
			sh(`cp -p ${f} ${ROOT}/backup/`);

	sh(`cp ${FIX}/shadow-vpn.config ${UCI_FILE}`);
	sh(`cp ${FIX}/job ${ROOT}/libexec/job && chmod 755 ${ROOT}/libexec/job`);
	// versions() keeps the database until its mtime changes: written once, before the first call
	writefile(APK_DB, 'C:Q1x=\nP:luci-app-shadow-vpn\nV:0.1.5-r1\n\nP:shadow-vpn\nV:0.1.5-r1\nA:all\n\n' +
		'P:xray-core\nV:26.3.27-r1\n\nP:openssh-client\nV:10.6_p1-r1\n\n');
	writefile(LEASES, '1792900000 a4:83:e7:11:22:33 192.168.1.120 MacBook 01:a4:83:e7:11:22:33\n' +
		'1792900000 3c:22:fb:1a:0e:77 192.168.1.140 * *\n' +
		'1792900000 3C:22:FB:1A:0E:77 192.168.1.140 dup *\n' +
		'garbage line\n');
	clear_jobs_log();
}

function teardown() {
	for (let f in [ 'shadow-vpn', 'dhcp.leases' ]) {
		const dst = (f == 'shadow-vpn') ? UCI_FILE : LEASES;

		if (access(`${ROOT}/backup/${f}`))
			sh(`cp -p ${ROOT}/backup/${f} ${dst}`);
		else
			unlink(dst);
	}

	sh(`rm -rf ${ROOT}`);
}

function load_plugin(paths) {
	const factory = loadfile(PLUGIN, { module_search_path: paths, raw_mode: true });

	return factory()['luci.shadow-vpn'];
}

function run_tests(m) {
	const call = (name, args) => m[name].call({ args: args ?? {} });

	/* Shape */

	let missing = filter(CONTRACT, n => type(m[n]?.call) != 'function');
	check('luci: plugin exports every CONTRACTS §9 method', !length(missing), 'missing ' + join(', ', missing));

	check('luci: argument typehints match the rpc types',
		type(m.set_enabled.args.enabled) == 'bool' && type(m.logs.args.lines) == 'int' &&
		type(m.server_save.args.values) == 'object' && type(m.rules_import.args.apply) == 'bool' &&
		type(m.profile_pin.args.pinned) == 'bool' && type(m.select.args.sid) == 'string',
		sprintf('%J', m.set_enabled.args));

	/* Section ids never reach a path unchecked */

	let bad = 0;

	for (let sid in [ '../../etc/passwd', 's_../../../x', 's_0123456789AB', 'k_0123456789ab', 's_0123456789abc', '', null ]) {
		if (call('server_delete', { sid })?.error != 'Invalid arguments.')
			bad++;
		if (call('hostkey_pin', { sid, fingerprint: fp('b') })?.error != 'Invalid arguments.')
			bad++;
	}

	for (let sid in [ '../keys/k_0123456789ab', 's_0123456789ab', 'k_0123456789ab/..' ])
		if (call('key_show', { sid })?.error != 'Invalid arguments.')
			bad++;

	check('luci: malformed or foreign section ids are refused', bad == 0, `${bad} accepted`);
	check('luci: job and attention ids are checked',
		call('job_status', { id: '../../etc/passwd' }).error == 'Invalid arguments.' &&
		call('attention_dismiss', { id: '../x' }).error == 'Invalid arguments.');

	/* Servers and host keys */

	let r = call('server_save', { values: { name: 'Lab', host: 'vpn.example.com', port: '22', username: 'root', auth: 'password', keepalive: '15' }, password: 'pw-secret' });
	const s1 = r.sid;

	check('luci: server_save creates a server', match(s1 ?? '', /^s_[0-9a-f]{12}$/), sprintf('%J', r));
	check('luci: the first server becomes the selection', uci_get('main', 'ssh_server') == s1);
	check('luci: writes are followed by a converge job', index(jobs_log(), 'converge') >= 0, jobs_log());
	check('luci: the password is stored as a secret, not in UCI',
		readfile(`${ETC}/secrets/${s1}.password`) == 'pw-secret' && index(readfile(UCI_FILE), 'pw-secret') < 0);

	r = call('server_save', { values: { name: '', host: '', port: '99999', username: 'root', auth: 'password' } });
	check('luci: server_save returns field errors', r.errors?.name && r.errors?.host && r.errors?.port, sprintf('%J', r));

	r = call('server_save', { values: { name: 'K', host: 'h.example', port: '22', username: 'u', auth: 'key', key: 'k_0123456789ab' } });
	check('luci: auth=key needs an existing key', r.errors?.key == 'Select a private key.', sprintf('%J', r));

	const s2 = call('server_save', { values: { name: 'Other', host: 'o.example', port: '2222', username: 'u', auth: 'password' } }).sid;

	writefile(`${ETC}/trusted.${s1}`, `ssh-ed25519 ${fp('a')} 1792900000\n`);
	writefile(`${RUN}/hostkey.${s1}.seen`, `ssh-ed25519 ${fp('b')} AAAAC3NzaC1lZDI1NTE5AAAAIB\n`);
	writefile(`${RUN}/hostkey.${s1}.status`, `changed expected=${fp('a')} got=${fp('b')} type=ssh-ed25519\n`);
	writefile(`${ETC}/known_hosts`, `shadow-${s1} ssh-ed25519 AAAAold\nshadow-${s2} ssh-ed25519 AAAAother\n`);

	r = call('servers');
	const v1 = filter(r.servers, s => s.sid == s1)[0];
	check('luci: servers reports host-key state without the key itself',
		v1?.hostkey?.trusted?.fingerprint == fp('a') && v1?.hostkey?.seen?.fingerprint == fp('b') &&
		v1?.hostkey?.problem?.kind == 'changed' && v1?.has_password === true && index(sprintf('%J', r), 'AAAAC3') < 0,
		sprintf('%J', v1));

	r = call('hostkey_pin', { sid: s1 });
	check('luci: hostkey_pin needs the fingerprint the page showed', r.error == 'Invalid arguments.' && uci_get(s1, 'fingerprint') == null,
		sprintf('%J', r));

	// the page showed one key, and the next connect attempt met another one (an impostor's, say)
	r = call('hostkey_pin', { sid: s1, fingerprint: fp('d') });
	check('luci: hostkey_pin refuses a key seen after the page was loaded',
		r.error == 'The server key changed since this page was loaded; review the new key.' &&
		uci_get(s1, 'fingerprint') == null && access(`${ETC}/trusted.${s1}`), sprintf('%J', r));

	r = call('hostkey_pin', { sid: s1, fingerprint: fp('b') });
	check('luci: hostkey_pin pins the last seen key',
		r.ok && r.fingerprint == fp('b') && uci_get(s1, 'fingerprint') == fp('b') &&
		!access(`${ETC}/trusted.${s1}`) && !access(`${RUN}/hostkey.${s1}.status`), sprintf('%J', r));
	check('luci: pinning drops only that server from known_hosts',
		readfile(`${ETC}/known_hosts`) == `shadow-${s2} ssh-ed25519 AAAAother\n`, readfile(`${ETC}/known_hosts`));

	writefile(`${ETC}/trusted.${s2}`, `ssh-ed25519 ${fp('c')} 1792900000\n`);
	r = call('hostkey_forget', { sid: s2 });
	check('luci: hostkey_forget removes the trusted key', r.ok && !access(`${ETC}/trusted.${s2}`) && readfile(`${ETC}/known_hosts`) == '');

	writefile(`${ETC}/trusted.${s1}`, `ssh-ed25519 ${fp('b')} 1792900000\n`);
	r = call('server_save', { sid: s1, values: { name: 'Lab', host: 'new.example.com', port: '22', username: 'root', auth: 'password', fingerprint: fp('b') } });
	check('luci: changing the host forgets the trusted and the seen key',
		r.sid == s1 && !access(`${ETC}/trusted.${s1}`) && !access(`${RUN}/hostkey.${s1}.seen`) && readfile(`${ETC}/secrets/${s1}.password`) == 'pw-secret');

	/* Keys */

	r = call('key_save', { name: 'Laptop', text: '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n', passphrase: 'pp' });
	const k1 = r.sid;
	check('luci: key_save stores the key as a secret', match(k1 ?? '', /^k_[0-9a-f]{12}$/) && r.key?.type == 'ed25519' &&
		index(readfile(`${ETC}/keys/${k1}`) ?? '', 'BEGIN OPENSSH') >= 0 && readfile(`${ETC}/secrets/${k1}.passphrase`) == 'pp', sprintf('%J', r));
	check('luci: a new key needs its text', call('key_save', { name: 'x' }).errors?.text == 'Private key is required for a new key.');
	check('luci: DSA keys are refused', index(call('key_save', { name: 'd', text: '-----BEGIN DSA PRIVATE KEY-----\nAA\n' }).errors?.text ?? '', 'DSA') >= 0);

	r = call('key_save', { name: 'Enc', text: '-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n', passphrase: 'pp' });
	check('luci: an encrypted PKCS#8 key of hidden type is saved', match(r.sid ?? '', /^k_[0-9a-f]{12}$/) &&
		r.key?.type == 'unknown' && r.key?.format == 'pkcs8' && r.key?.encrypted === true && uci_get(r.sid, 'type') == 'unknown', sprintf('%J', r));
	call('key_delete', { sid: r.sid });

	r = call('key_save', { name: 'u', text: '-----BEGIN PRIVATE KEY-----\nunknown-alg\n-----END PRIVATE KEY-----\n' });
	check('luci: an unencrypted key of unknown type is refused without a DSA message',
		r.errors?.text == 'Unable to load SSH private key. Check the key format and passphrase.', sprintf('%J', r));
	check('luci: key_show returns the stored text', index(call('key_show', { sid: k1 }).text ?? '', 'BEGIN OPENSSH') >= 0);

	call('server_save', { sid: s2, values: { name: 'Other', host: 'o.example', port: '2222', username: 'u', auth: 'key', key: k1 } });
	check('luci: a key in use cannot be deleted',
		call('key_delete', { sid: k1 }).error == 'This private key is used by at least one SSH configuration.' &&
		call('keys').keys[0].used == 1);

	call('server_delete', { sid: s2 });
	r = call('key_delete', { sid: k1 });
	check('luci: an unused key is deleted with its secrets', r.ok && !access(`${ETC}/keys/${k1}`) && !access(`${ETC}/secrets/${k1}.passphrase`));

	call('server_delete', { sid: s1 });
	check('luci: deleting the selected server clears the selection', uci_get('main', 'ssh_server') == null && !access(`${ETC}/secrets/${s1}.password`));

	/* Profiles */

	r = call('profiles_import', { text: `# list\n${L1}\n\n${L2}\nvless://broken\n${L3}\n`, source: 'import' });
	check('luci: profiles_import counts added, skipped and failed',
		r.added == 3 && r.updated == 0 && r.skipped == 3 && r.failed == 1 && r.errors?.[0]?.line == 5 &&
		r.errors[0].message == 'Invalid VLESS URI.', sprintf('%J', r));

	let p = call('profiles').profiles;
	const pa = filter(p, x => x.name == 'Amsterdam')[0], pd = filter(p, x => x.name == 'Frankfurt')[0], po = filter(p, x => x.name == 'Old')[0];
	check('luci: the first supported profile becomes the selection', pa?.selected === true && uci_get('main', 'xray_profile') == pa.sid);
	check('luci: links are secrets', readfile(`${ETC}/secrets/${pa.sid}.link`) == L1 && index(readfile(UCI_FILE), '1111-4111') < 0);
	check('luci: UCI holds the keyed profile identity, not the link hash',
		match(uci_get(pa.sid, 'fingerprint') ?? '', /^hmac:/) != null && index(readfile(UCI_FILE), "'sha256:") < 0,
		uci_get(pa.sid, 'fingerprint'));

	call('profile_rename', { sid: pd.sid, name: 'My\nFrankfurt' });
	call('profile_pin', { sid: pd.sid, pinned: true });
	r = call('profiles_import', { text: L2, source: 'import' });
	const pd2 = filter(call('profiles').profiles, x => x.sid == pd.sid)[0];
	check('luci: re-import updates in place and keeps name and pin', r.updated == 1 && r.added == 0 &&
		pd2?.name == 'My Frankfurt' && pd2?.pinned === true, sprintf('%J', pd2));
	check('luci: profile_link returns the stored link', call('profile_link', { sid: pd.sid }).link == L2);
	check('luci: an unsupported profile cannot be selected', index(call('select', { transport: 'xray', sid: po.sid }).error ?? '', 'unsupported') >= 0);

	r = call('profiles_delete_unpinned');
	p = call('profiles').profiles;
	check('luci: delete unpinned keeps pinned and selected profiles', r.deleted == 1 && length(p) == 2 && !access(`${ETC}/secrets/${po.sid}.link`), sprintf('%J', r));

	call('profile_delete', { sid: pa.sid });
	check('luci: deleting the selected profile selects the next supported one', uci_get('main', 'xray_profile') == pd.sid);

	/* Rules */

	r = call('rule_add', { type: 'domain', value: 'YouTube.com' });
	const r1 = r.sid;
	check('luci: rule_add stores a normalised rule', match(r1 ?? '', /^r_[0-9a-f]{12}$/) && uci_get(r1, 'value') == 'youtube.com' &&
		match(uci_get(r1, 'id') ?? '', /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/), sprintf('%J', r));
	check('luci: rule_add refuses duplicates', call('rule_add', { type: 'domain', value: 'youtube.com' }).error == 'This rule already exists.');
	check('luci: rule_add returns the validation message', call('rule_add', { type: 'domain', value: 'localhost' }).error == 'Domain pattern must include at least two labels.');
	check('luci: rule_set toggles a rule', call('rule_set', { sid: r1, enabled: false }).ok && uci_get(r1, 'enabled') == '0');

	const doc = sprintf('%J', { rules: [
		{ id: '0b6f2bc4-2b36-4b0e-9d43-4f1a9b1c2d3e', type: 'domain', value: 'chatgpt.com', enabled: true },
		{ type: 'domain', value: 'ChatGPT.com' },
		{ type: 'process.name', value: 'telegram.exe' },
		{ type: 'url', value: 'x' },
		{ type: 'ip', value: '10.8.0.0/016' },
		{ type: 'domain', value: 'nodot' },
		5,
		{ type: 'device', value: '3c:22:fb:1a:0e:77', enabled: false }
	] });

	r = call('rules_import', { text: doc, apply: false });
	check('luci: rules_import preview counts every skip kind', r.total == 8 && r.imported == 3 &&
		r.skipped?.duplicates == 1 && r.skipped?.unsupported == 2 && r.skipped?.apps == 1 && r.skipped?.invalid == 1 &&
		r.skipped?.malformed == 1 && length(call('rules').rules) == 1, sprintf('%J', r));

	r = call('rules_import', { text: doc, apply: true });
	const rules = call('rules').rules;
	check('luci: rules_import replaces the rules', r.imported == 3 && length(rules) == 3 &&
		filter(rules, x => x.type == 'ip')[0]?.value == '10.8.0.0/16' &&
		filter(rules, x => x.type == 'domain')[0]?.id == '0b6f2bc4-2b36-4b0e-9d43-4f1a9b1c2d3e' &&
		filter(rules, x => x.type == 'device')[0]?.enabled === false, sprintf('%J', rules));

	const exported = json(call('rules_export').json);
	check('luci: rules_export writes the desktop shape', length(exported) == 3 && exported[0].id && exported[0].type && exported[0].value &&
		type(exported[0].enabled) == 'bool' && !exists(exported[0], 'sid'), sprintf('%J', exported));

	check('luci: rules_import rejects non-JSON and non-lists',
		call('rules_import', { text: '{', apply: false }).error == 'The file is not valid JSON, so nothing was imported.' &&
		call('rules_import', { text: '{"x":1}', apply: false }).error == 'Import file must contain a rules array.');

	/* Lists, jobs, settings, enable */

	clear_jobs_log();
	r = call('list_set', { kind: 'proxy', enabled: true });
	check('luci: using a list that was never downloaded starts its refresh', r.job && index(jobs_log(), 'list-refresh proxy') >= 0, jobs_log());
	check('luci: job_status reads the job file', call('job_status', { id: r.job })?.state == 'done');
	check('luci: list kinds are checked', call('list_refresh', { kind: 'proxy; reboot' }).error == 'Invalid arguments.');

	mkdir(ETC + '/lists', 0o700);
	writefile(ETC + '/lists/direct.lst', 'gosuslugi.ru\nya.ru\n');
	r = call('lists');
	check('luci: lists reports enabled state and counts', r.proxy?.enabled === true && r.direct?.count == 2 && r.direct?.enabled === false, sprintf('%J', r));
	check('luci: list_view returns the stored domains', length(call('list_view', { kind: 'direct' }).domains) == 2);

	r = call('settings_set', { values: { mode: 'selected-rules', lists_refresh: '6', check_endpoint: 'example.com:443' } });
	check('luci: settings_set stores mode, refresh and endpoint', r.ok && uci_get('main', 'mode') == 'selected-rules' &&
		uci_get('main', 'lists_refresh') == '6' && uci_get('main', 'check_endpoint') == 'example.com:443', sprintf('%J', r));
	r = call('settings_set', { values: { mode: 'all', lists_refresh: '-1', ipv6: '1' } });
	check('luci: settings_set refuses bad and unknown values without writing', r.errors?.mode && r.errors?.lists_refresh && r.errors?.ipv6 &&
		uci_get('main', 'mode') == 'selected-rules');

	call('select', { transport: 'ssh', sid: '' });
	r = call('set_enabled', { enabled: true });
	check('luci: turning on without a server is refused', r.error == 'Select or create an SSH configuration before connecting.' && uci_get('main', 'enabled') == '0');

	unlink(RUN + '/log.txt');
	call('select', { transport: 'xray', sid: pd.sid });
	writefile(RUN + '/fatal', '1');
	clear_jobs_log();
	r = call('set_enabled', { enabled: true });
	check('luci: turning on commits and starts a connecting converge',
		r.job && uci_get('main', 'enabled') == '1' && trim(jobs_log()) == 'converge --connect', sprintf('%J %s', r, jobs_log()));
	// what the user did goes to the log at info, under the level the settings hold (DESIGN.md 6.8)
	check('luci: select and turning on are logged at info',
		match(readfile(RUN + '/log.txt') ?? '', /^warning info luci: selected profile "[^"\n]*" \((p_[0-9a-f]{12})\), transport xray\nwarning info luci: turned on \(Connect\)\n$/)?.[1] == pd.sid,
		readfile(RUN + '/log.txt'));

	clear_jobs_log();
	call('set_enabled', { enabled: true });
	check('luci: a fatal stop makes set_enabled connect again', trim(jobs_log()) == 'converge --connect', jobs_log());

	unlink(RUN + '/fatal');
	clear_jobs_log();
	call('set_enabled', { enabled: true });
	check('luci: set_enabled while on and healthy only converges', trim(jobs_log()) == 'converge', jobs_log());
	check('luci: set_enabled wants a boolean', call('set_enabled', { enabled: 'yes' }).error == 'Invalid arguments.');

	// while on, a switch to a transport with nothing selected would tear the tunnel down: refused
	clear_jobs_log();
	r = call('select', { transport: 'ssh', sid: '' });
	check('luci: while on, select refuses a transport with nothing selected',
		r.error == 'Select or create an SSH configuration before connecting.' && uci_get('main', 'transport') == 'xray' &&
		trim(jobs_log()) == '', sprintf('%J %s', r, jobs_log()));
	check('luci: the tunnel check needs an active tunnel', call('check').error == 'Tunnel check is available while the tunnel is connected.');

	/* Status, leases, attention */

	const st = call('status');
	check('luci: status has the contract shape', st.enabled === true && type(st.phase) == 'string' &&
		type(st.tunnel) == 'object' && st.tunnel.fallback == 'block' && type(st.memory?.total_kb) == 'int' && st.memory.total_kb > 0 &&
		type(st.routing?.rules) == 'object' && type(st.attention) == 'array' &&
		type(st.versions) == 'object' && st.target?.kind == 'xray' && st.selected?.xray_profile == pd.sid, sprintf('%J', st));

	// status keeps its model between polls, but a committed change shows at once
	call('settings_set', { values: { check_endpoint: 'other.example:443' } });
	check('luci: status sees a change committed after the last poll', call('status').check_endpoint == 'other.example:443');

	r = call('leases');
	check('luci: leases parses dnsmasq leases once per MAC', length(r.leases) == 2 && r.leases[0].mac == 'A4:83:E7:11:22:33' &&
		r.leases[0].name == 'MacBook' && r.leases[1].name == '', sprintf('%J', r));

	const s3 = call('server_save', { values: { name: 'Pinned', host: 'p.example', port: '22', username: 'u', auth: 'password', fingerprint: fp('a') } }).sid;
	call('select', { transport: 'ssh', sid: s3 });
	writefile(`${RUN}/hostkey.${s3}.status`, `pin_mismatch expected=${fp('a')} got=${fp('d')} type=ssh-ed25519\n`);
	const st2 = call('status');
	check('luci: status reports a host-key mismatch of the selected server', st2.hostkey?.kind == 'pin_mismatch' &&
		st2.hostkey?.got == fp('d') && st2.target?.kind == 'ssh' && st2.target?.addr == 'u@p.example:22', sprintf('%J', st2.hostkey ?? st2));

	writefile(RUN + '/attention.json', sprintf('%J', [ { id: 'a1', code: 'port_busy', message: 'x', since: 1 } ]));
	check('luci: attention_dismiss removes the entry', call('attention_dismiss', { id: 'a1' }).ok && length(call('status').attention) == 0);
}

/* Updates: the updater's files as the plugin reads them; checks and installs are jobs (DESIGN §11) */

function uptime() {
	return int(split(readfile('/proc/uptime'), ' ')[0]);
}

// A live process whose command line names the updater, as the detached install's does.
function fake_updater() {
	sh(`sh -c 'sleep 30; exit 0' /usr/libexec/shadow-vpn/update >/dev/null 2>&1 & echo $! > ${ROOT}/updater.pid`);

	return int(trim(readfile(`${ROOT}/updater.pid`) ?? '0'));
}

function update_tests(m) {
	const call = (name, args) => m[name].call({ args: args ?? {} });
	let u = call('update_status');

	check('luci: update_status before any check', u.mode == 'notify' && u.installed == '0.1.5' && u.latest == null &&
		u.available === false && u.checked_age == null && u.running == null && u.last == null && u.auto == null &&
		match(u.clock?.time ?? '', /^[0-2][0-9]:[0-5][0-9]$/) && type(u.clock?.zone) == 'string', sprintf('%J', u));

	const up = uptime();

	writefile(UPDATE_STATE, sprintf('%J', {
		checked: time() - 7200, checked_up: up - 30, ok: false, error: 'Could not reach GitHub to check for updates.',
		installed: '0.1.5', latest: '0.1.6', tag: 'v0.1.6', url: 'https://github.com/stansful/x/releases/tag/v0.1.6',
		published: 1792886400, notes: 'Fixes.', console: false, announced: '0.1.6', from_a_newer_writer: [ 1 ],
		last: { ok: false, changed: true, from: '0.1.4', to: '0.1.5', auto: true, rolled_back: false, at: 1, at_up: up - 60,
			error: 'Shadow 0.1.5 was installed, but the tunnel did not come back within 90 s.' }
	}));
	writefile(UPDATE_AUTO, sprintf('%J', { version: '0.1.6', tries: 3, at: time(), finished: true, ok: false, error: 'x' }));
	u = call('update_status');
	check('luci: update_status reads the last check, the last install and the automatic attempts',
		u.latest == '0.1.6' && u.available === true && u.check_ok === false &&
		u.check_error == 'Could not reach GitHub to check for updates.' && u.checked_age >= 30 && u.checked_age < 40 &&
		u.url == 'https://github.com/stansful/x/releases/tag/v0.1.6' && u.published == 1792886400 && u.notes == 'Fixes.' &&
		u.console === false && u.last?.changed === true && u.last?.auto === true && u.last?.from == '0.1.4' &&
		u.last?.age >= 60 && u.last?.age < 70 && index(u.last?.error ?? '', 'did not come back') > 0 &&
		u.auto?.version == '0.1.6' && u.auto?.stopped === true, sprintf('%J', u));

	writefile(UPDATE_STATE, sprintf('%J', { latest: '0.1.5', url: 'javascript:alert(1)', console: 'yes', last: 'x' }));
	writefile(UPDATE_AUTO, sprintf('%J', { version: '0.1.6', tries: 2, finished: true, ok: false }));
	u = call('update_status');
	check('luci: update_status tolerates odd fields and links only a web address',
		u.latest == '0.1.5' && u.available === false && u.url == null && u.console === false && u.last == null &&
		u.checked_age == null && u.auto?.stopped === false, sprintf('%J', u));

	writefile(UPDATE_STATE, '{ not json');
	writefile(UPDATE_AUTO, '[ 1 ]');
	u = call('update_status');
	check('luci: update_status survives damaged files', u.latest == null && u.auto == null && u.installed == '0.1.5', sprintf('%J', u));

	uci_set('main', 'update', 'auto');
	check('luci: update_status reports the mode', call('update_status').mode == 'auto');

	// a run file whose pid runs something else (here: this test) is a leftover, not a running update
	writefile(UPDATE_RUN, sprintf('%J', { pid: int(readlink('/proc/self')), stage: 'install', version: '0.1.6', started: time() }));
	clear_jobs_log();
	check('luci: a stale run file is no running update', call('update_status').running == null);
	check('luci: update_check and update_install start their jobs',
		call('update_check').job && call('update_install').job && jobs_log() == 'update-check\nupdate-install\n', jobs_log());

	const pid = fake_updater();

	writefile(UPDATE_RUN, sprintf('%J', { pid, stage: 'download', version: '0.1.6', auto: false, started: time(),
		started_up: uptime() - 5 }));
	clear_jobs_log();
	u = call('update_status');
	check('luci: update_status sees the install in progress', u.running?.stage == 'download' &&
		u.running?.version == '0.1.6' && u.running?.auto === false && u.running?.age >= 5, sprintf('%J pid %d', u.running, pid));
	check('luci: update_check and update_install are refused while an update runs',
		call('update_check').error == 'An update is already running.' &&
		call('update_install').error == 'An update is already running.' && jobs_log() == '', jobs_log());

	sh(`kill ${pid}`);
	unlink(UPDATE_RUN);
}

/* The transport follows the first server or profile set up while Shadow is off (DESIGN §10) */

// A new install's config: no servers or profiles, Shadow off, transport ssh.
function fresh_config() {
	sh(`rm -f ${UCI_FILE}; cp ${FIX}/shadow-vpn.config ${UCI_FILE}`);
	clear_jobs_log();
}

function transport_tests(m) {
	const call = (name, args) => m[name].call({ args: args ?? {} });
	const add_server = () => call('server_save', { values: { name: 'First', host: 'first.example', port: '22', username: 'u', auth: 'password' }, password: 'pw' }).sid;
	const transport = () => uci_get('main', 'transport');
	let r;

	fresh_config();
	call('profiles_import', { text: L3, source: 'manual' });
	check('luci: an unsupported profile alone leaves the transport', transport() == 'ssh' && uci_get('main', 'xray_profile') == null, transport());

	r = call('profiles_import', { text: L1, source: 'manual' });
	const p1 = uci_get('main', 'xray_profile');
	check('luci: the first usable profile becomes the transport when SSH has no server',
		r.added == 1 && p1 != null && transport() == 'xray', sprintf('%J %s', r, transport()));

	clear_jobs_log();
	r = call('set_enabled', { enabled: true });
	check('luci: an Xray-only setup turns on without the transport switch',
		r.job && uci_get('main', 'enabled') == '1' && trim(jobs_log()) == 'converge --connect', sprintf('%J %s', r, jobs_log()));
	call('set_enabled', { enabled: false });

	// SSH picked on the Overview with a profile ready: an import that selects nothing new keeps that choice
	call('select', { transport: 'ssh', sid: '' });
	call('profiles_import', { text: L2, source: 'manual' });
	check('luci: a later import keeps the transport the user picked', transport() == 'ssh' && uci_get('main', 'xray_profile') == p1, transport());

	fresh_config();
	call('select', { transport: 'xray', sid: '' });
	const s1 = add_server();
	check('luci: the first server becomes the transport when Xray has no usable profile', s1 && transport() == 'ssh', transport());

	call('select', { transport: 'xray', sid: '' });
	const s2 = add_server();
	check('luci: a later server keeps the transport the user picked', s2 && transport() == 'xray', transport());

	call('select', { transport: 'ssh', sid: '' });
	call('profiles_import', { text: L1, source: 'manual' });
	check('luci: the first profile keeps a transport that has a usable selection', transport() == 'ssh' && uci_get('main', 'xray_profile') != null, transport());

	call('server_delete', { sid: s1 });
	call('server_delete', { sid: s2 });
	check('luci: deleting the last server never switches the transport', transport() == 'ssh' && uci_get('main', 'ssh_server') == null, transport());

	// Shadow left on after its only server was deleted: an import must not bring a tunnel up on its own
	fresh_config();
	uci_set('main', 'enabled', '1');
	call('profiles_import', { text: L1, source: 'manual' });
	check('luci: the first profile never switches the transport while Shadow is on', transport() == 'ssh' && uci_get('main', 'xray_profile') != null,
		transport());
}

/* Static checks: plugin source, ACL, menu, catalogs */

// ucode resolves names lexically: a top-level function called before its definition fails at run time.
function forward_refs(src) {
	const lines = split(src, '\n');
	const defs = {};
	const bad = [];

	for (let i = 0; i < length(lines); i++) {
		const d = match(lines[i], /^function ([a-z_][a-z0-9_]*)\(/);

		if (d)
			defs[d[1]] = i;
	}

	for (let name, at in defs)
		for (let i = 0; i < at; i++)
			if (match(lines[i], regexp('(^|[^a-z0-9_.])' + name + '\\(')))
				push(bad, `${name} on line ${i + 1}, defined on line ${at + 1}`);

	return bad;
}

function static_checks(m) {
	const fwd = forward_refs(readfile(PLUGIN));

	check('luci: the plugin calls no function before its definition', !length(fwd), join('; ', fwd));

	const acl = json(readfile(APP + '/root/usr/share/rpcd/acl.d/luci-app-shadow-vpn.json'))['luci-app-shadow-vpn'];
	const rd = acl.read.ubus['luci.shadow-vpn'], wr = acl.write.ubus['luci.shadow-vpn'];
	const all = [ ...rd, ...wr ];
	const names = keys(m);
	const dup = filter(names, n => length(filter(all, x => x == n)) != 1);
	const extra = filter(all, n => !(n in names));

	check('luci: ACL lists every method exactly once', !length(dup) && !length(extra), `dup ${join(',', dup)} extra ${join(',', extra)}`);
	check('luci: secrets are readable only with write access', !('key_show' in rd) && !('profile_link' in rd) && ('key_show' in wr) && ('profile_link' in wr));
	check('luci: ACL grants no file access and uci only for shadow-vpn',
		!exists(acl.read, 'file') && !exists(acl.write, 'file') && acl.read.uci[0] == 'shadow-vpn' && acl.write.uci[0] == 'shadow-vpn' &&
		length(acl.read.uci) == 1 && length(acl.write.uci) == 1);

	const menu = json(readfile(APP + '/root/usr/share/luci/menu.d/luci-app-shadow-vpn.json'));
	let views = 0, missing = [];

	for (let path, node in menu) {
		if (node.action?.type != 'view')
			continue;

		views++;

		if (!access(`${APP}/htdocs/luci-static/resources/view/${node.action.path}.js`))
			push(missing, node.action.path);
	}

	check('luci: the menu has six views and all exist', views == 6 && !length(missing), join(', ', missing));

	const po = readfile(APP + '/po/ru/shadow-vpn.po');
	const pot = readfile(APP + '/po/templates/shadow-vpn.pot');
	const count = (text, re) => length(match(text, re) ?? []);
	const ids = match(pot, /\nmsgid "/g);
	const strs = match(po, /\nmsgstr(\[0\])? "[^"]/g);

	check('luci: every template msgid has a Russian translation', length(ids) > 300 && length(strs) + 4 >= length(ids),
		sprintf('%d msgids, %d translations', length(ids), length(strs)));
	check('luci: the catalog declares Russian plural forms', index(po, 'nplurals=3;') >= 0 && count(po, /msgstr\[2\]/g) > 0);
}

/* Plugin against the real backend modules, when they exist */

function real_modules() {
	const dir = SRC + '/shadow-vpn/files/usr/share/ucode/shadow-vpn';
	const missing = filter(IMPORTS, n => !access(`${dir}/${n}.uc`));

	if (length(missing)) {
		print(`# skip luci: plugin against the real modules (missing ${join(', ', missing)})\n`);
		return;
	}

	let m = null, err = null;

	try {
		m = load_plugin([ '/usr/lib/ucode/*.so', SRC + '/shadow-vpn/files/usr/share/ucode/*.uc', FIX + '/stubs/*.uc' ]);
	}
	catch (e) {
		err = e;
	}

	check('luci: the plugin compiles against the real modules', m && !length(filter(CONTRACT, n => type(m[n]?.call) != 'function')), `${err}`);
}

setup();

try {
	const m = load_plugin([ '/usr/lib/ucode/*.so', FIX + '/stubs/*.uc' ]);

	check('luci: the plugin compiles', type(m) == 'object');
	run_tests(m);
	update_tests(m);
	transport_tests(m);
	static_checks(m);
}
catch (e) {
	failures++;
	print(`not ok luci: unexpected exception: ${e}\n${e.stacktrace?.[0]?.context ?? ''}\n`);
}

teardown();
real_modules();

exit(failures ? 1 : 0);
