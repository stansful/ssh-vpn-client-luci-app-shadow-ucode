'use strict';

import { cursor } from 'uci';
import * as validate from 'shadow-vpn.validate';
import { UCI, LIMITS, SID_RE, CHECK_ENDPOINT } from 'shadow-vpn.const';

const MAIN_DEFAULTS = {
	enabled: false, autostart: true, transport: 'ssh', ssh_server: null, xray_profile: null,
	mode: 'proxy-all', kill_switch: true, check_endpoint: CHECK_ENDPOINT, check_after_connect: true,
	ssh_udp: 'reject', tunnel_dns: true, ipv6: false, dns_redirect: true, router_traffic: true,
	lists_refresh: 24, log_level: 'warning'
};

const MAIN_BOOLS = [ 'enabled', 'autostart', 'kill_switch', 'check_after_connect', 'tunnel_dns', 'ipv6',
	'dns_redirect', 'router_traffic' ];

const MAIN_ENUMS = {
	transport: [ 'ssh', 'xray' ],
	mode: [ 'proxy-all', 'selected-rules' ],
	ssh_udp: [ 'reject', 'direct' ],
	log_level: [ 'info', 'warning', 'error' ]
};

const BOOL_WORDS = { '1': true, 'on': true, 'true': true, 'yes': true, 'enabled': true,
	'0': false, 'off': false, 'false': false, 'no': false, 'disabled': false };

const SERVER_SID = /^s_[0-9a-f]{12}$/, KEY_SID = /^k_[0-9a-f]{12}$/, PROFILE_SID = /^p_[0-9a-f]{12}$/;
const UUID = /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;
const TOKEN = /^[a-z0-9-]{0,32}$/;
// 'hmac:' is what UCI holds (secrets.profile_identity); 'sha256:' is the plain form earlier builds wrote
const PROFILE_FP = /^(hmac|sha256):[0-9a-f]{64}$/;
const HOP_PORTS = /^[0-9,-]{0,200}$/;
const NOTE_MAX = validate.ROUTER_NOTE_LENGTH, NAME_MAX = validate.ROUTER_NAME_LENGTH;

function errors_sink(errors) {
	return (section, option, message) => push(errors, { section, option, message });
}

// UCI values are strings or, for list options, arrays; anything else is unusable here.
function scalar(v) {
	return type(v) == 'string' ? v : null;
}

function parse_bool(v) {
	return type(v) == 'string' ? BOOL_WORDS[lc(trim(v))] : null;
}

function parse_int(v, lo, hi) {
	if (type(v) != 'string' || !match(v, /^[0-9]{1,10}$/))
		return null;

	let n = int(v);

	return (n >= lo && n <= hi) ? n : null;
}

// Runs a validator from validate.uc; a missing or malformed result counts as invalid.
function check(fn, v, ...args) {
	let r = (type(fn) == 'function') ? fn(v, ...args) : null;

	if (type(r) != 'object')
		return { error: 'Invalid value.' };

	if (r.error != null)
		return { error: r.error };

	return { ...r, value: r.value ?? v };
}

function load_main(s, err) {
	let main = { ...MAIN_DEFAULTS };

	for (let opt in MAIN_BOOLS) {
		if (s[opt] == null)
			continue;

		let b = parse_bool(s[opt]);

		if (b == null)
			err('main', opt, 'Must be 0 or 1.');
		else
			main[opt] = b;
	}

	for (let opt, allowed in MAIN_ENUMS) {
		if (s[opt] == null)
			continue;

		if (scalar(s[opt]) != null && index(allowed, s[opt]) >= 0)
			main[opt] = s[opt];
		else
			err('main', opt, `Must be one of: ${join(', ', allowed)}.`);
	}

	if (s.lists_refresh != null) {
		let n = parse_int(s.lists_refresh, 0, 8760);

		if (n == null)
			err('main', 'lists_refresh', 'Must be a whole number of hours from 0 to 8760.');
		else
			main.lists_refresh = n;
	}

	if (s.check_endpoint != null) {
		let r = check(validate.endpoint, scalar(s.check_endpoint) ?? '');

		if (r.error)
			err('main', 'check_endpoint', r.error);
		else
			main.check_endpoint = r.value;
	}

	for (let opt in [ 'ssh_server', 'xray_profile' ]) {
		let v = s[opt];

		if (v == null || v == '')
			continue;

		if (scalar(v) != null && match(v, opt == 'ssh_server' ? SERVER_SID : PROFILE_SID))
			main[opt] = v;
		else
			err('main', opt, 'Invalid section id.');
	}

	return main;
}

function load_key(s, err) {
	let sid = s['.name'];

	if (!match(sid, KEY_SID)) {
		err(sid, null, 'Invalid section id.');
		return null;
	}

	let type_ = scalar(s.type) ?? 'ed25519', format = scalar(s.format) ?? 'openssh';
	let encrypted = parse_bool(s.encrypted) ?? false;

	// An encrypted PKCS#8 key hides its algorithm in the encrypted part (keys.normalize says 'unknown');
	// OpenSSH needs no type to load it.
	let unknown_ok = type_ == 'unknown' && format == 'pkcs8' && encrypted;

	if (index([ 'ed25519', 'ecdsa', 'rsa' ], type_) < 0 && !unknown_ok) {
		err(sid, 'type', 'Unsupported key type.');
		return null;
	}

	if (index([ 'openssh', 'pem', 'pkcs8' ], format) < 0) {
		err(sid, 'format', 'Unsupported key format.');
		return null;
	}

	let name = check(validate.name, scalar(s.name) ?? '', NAME_MAX);

	if (name.error)
		err(sid, 'name', name.error);

	return { sid, name: name.error ? sid : name.value, type: type_, format, encrypted };
}

function load_server(s, err, key_sids) {
	let sid = s['.name'];

	if (!match(sid, SERVER_SID)) {
		err(sid, null, 'Invalid section id.');
		return null;
	}

	let srv = { sid, note: '' };
	let ok = true;

	// A server with an unusable host, port, user or pin is dropped: guessing would connect somewhere else
	// or silently trust a key the user meant to pin.
	for (let f, def in { host: '', username: '', port: '22' }) {
		let r = check(validate[f], scalar(s[f]) ?? def);

		if (r.error) {
			err(sid, f, r.error);
			ok = false;
		}
		else {
			srv[f] = (f == 'port') ? int(r.value) : r.value;
		}
	}

	srv.fingerprint = scalar(s.fingerprint) ?? '';

	if (srv.fingerprint != '') {
		let r = check(validate.fingerprint, srv.fingerprint);

		if (r.error) {
			err(sid, 'fingerprint', r.error);
			ok = false;
		}
		else {
			srv.fingerprint = r.value;
		}
	}

	let keepalive = check(validate.keepalive, scalar(s.keepalive) ?? '15');

	if (keepalive.error)
		err(sid, 'keepalive', keepalive.error);

	srv.keepalive = keepalive.error ? 15 : int(keepalive.value);

	let name = check(validate.name, scalar(s.name) ?? '', NAME_MAX);

	if (name.error)
		err(sid, 'name', name.error);

	srv.name = name.error ? (srv.host ?? sid) : name.value;

	srv.auth = scalar(s.auth) ?? 'password';

	if (index([ 'password', 'key' ], srv.auth) < 0) {
		err(sid, 'auth', 'Must be password or key.');
		ok = false;
	}

	srv.key = null;

	if (srv.auth == 'key') {
		let k = scalar(s.key);

		if (k == null || !match(k, KEY_SID) || !key_sids[k]) {
			err(sid, 'key', 'Select a saved SSH key.');
			ok = false;
		}
		else {
			srv.key = k;
		}
	}

	let note = scalar(s.note) ?? '';

	// code points, as the form counts them (validate.server)
	if (validate.cplen(note) > NOTE_MAX)
		err(sid, 'note', `Must be at most ${NOTE_MAX} characters.`);
	else
		srv.note = note;

	return ok ? srv : null;
}

function load_profile(s, err) {
	let sid = s['.name'];

	if (!match(sid, PROFILE_SID)) {
		err(sid, null, 'Invalid section id.');
		return null;
	}

	let protocol = scalar(s.protocol) ?? '';

	if (index([ 'vless', 'vmess', 'trojan', 'hysteria2' ], protocol) < 0) {
		err(sid, 'protocol', 'Unsupported proxy URI protocol.');
		return null;
	}

	let host = check(validate.host, scalar(s.host) ?? ''), port = check(validate.port, scalar(s.port) ?? '443');

	if (host.error || port.error) {
		host.error && err(sid, 'host', host.error);
		port.error && err(sid, 'port', port.error);
		return null;
	}

	let p = { sid, protocol, host: host.value, port: int(port.value) };
	let name = check(validate.name, scalar(s.name) ?? '', NAME_MAX);

	if (name.error)
		err(sid, 'name', name.error);

	p.name = name.error ? `${host.value}:${p.port}` : name.value;

	for (let f in [ 'transport', 'security', 'flow' ]) {
		let v = scalar(s[f]) ?? '';

		if (!match(v, TOKEN)) {
			err(sid, f, 'Invalid value.');
			v = '';
		}

		p[f] = v;
	}

	p.hop_ports = scalar(s.hop_ports) ?? '';

	if (!match(p.hop_ports, HOP_PORTS)) {
		err(sid, 'hop_ports', 'Invalid port range.');
		p.hop_ports = '';
	}

	p.fingerprint = scalar(s.fingerprint) ?? '';

	if (p.fingerprint != '' && !match(p.fingerprint, PROFILE_FP)) {
		err(sid, 'fingerprint', 'Invalid profile fingerprint.');
		p.fingerprint = '';
	}

	p.pinned = parse_bool(s.pinned) ?? false;
	p.insecure_without_pin = parse_bool(s.insecure_without_pin) ?? false;
	p.supported = parse_bool(s.supported) ?? true;
	p.created = parse_int(s.created, 0, 0x7fffffff) ?? 0;
	p.updated = parse_int(s.updated, 0, 0x7fffffff) ?? p.created;

	return p;
}

const RULE_VALIDATORS = { domain: 'domain_rule', ip: 'ip_rule', device: 'device_rule' };

function load_rule(s, err) {
	let sid = s['.name'], kind = scalar(s.type) ?? '';

	if (!RULE_VALIDATORS[kind]) {
		err(sid, 'type', 'Must be domain, ip or device.');
		return null;
	}

	let r = check(validate[RULE_VALIDATORS[kind]], scalar(s.value) ?? '');

	if (r.error) {
		err(sid, 'value', r.error);
		return null;
	}

	let rule = { sid, id: scalar(s.id) ?? '', type: kind, value: r.value, enabled: parse_bool(s.enabled) ?? true };

	if (rule.id != '' && !match(rule.id, UUID)) {
		err(sid, 'id', 'Invalid rule id.');
		rule.id = '';
	}

	if (r.family != null)
		rule.family = r.family;

	if (r.kind != null)
		rule.kind = r.kind;

	return rule;
}

// Reads UCI into the normalized model of CONTRACTS.md 3. Invalid values are dropped and listed in
// `errors`; nothing here throws on bad configuration.
function load(c) {
	c ??= cursor();

	let errors = [];
	let err = errors_sink(errors);
	let model = {
		main: load_main(c.get_all(UCI, 'main') ?? {}, err),
		lists: { proxy: { enabled: false }, direct: { enabled: false } },
		servers: [], keys: [], profiles: [], rules: [], errors
	};

	c.foreach(UCI, 'list', (s) => {
		if (model.lists[s['.name']])
			model.lists[s['.name']].enabled = parse_bool(s.enabled) ?? false;
	});

	let key_sids = {};

	c.foreach(UCI, 'ssh_key', (s) => {
		let k = load_key(s, err);

		if (k) {
			push(model.keys, k);
			key_sids[k.sid] = true;
		}
	});

	c.foreach(UCI, 'ssh_server', (s) => {
		let srv = load_server(s, err, key_sids);

		if (srv)
			push(model.servers, srv);
	});

	let dropped = { profiles: 0, rules: 0 };

	c.foreach(UCI, 'profile', (s) => {
		if (length(model.profiles) >= LIMITS.profiles) {
			dropped.profiles++;
			return;
		}

		let p = load_profile(s, err);

		if (p)
			push(model.profiles, p);
	});

	c.foreach(UCI, 'rule', (s) => {
		if (length(model.rules) >= LIMITS.rules) {
			dropped.rules++;
			return;
		}

		let r = load_rule(s, err);

		if (r)
			push(model.rules, r);
	});

	for (let what, n in dropped)
		if (n > 0)
			err(null, what, `Only the first ${LIMITS[what]} ${what} are used; ${n} more were ignored.`);

	let main = model.main;

	if (main.ssh_server && !filter(model.servers, (s) => s.sid == main.ssh_server)[0]) {
		err('main', 'ssh_server', 'The selected SSH server does not exist or is invalid.');
		main.ssh_server = null;
	}

	if (main.xray_profile && !filter(model.profiles, (p) => p.sid == main.xray_profile)[0]) {
		err('main', 'xray_profile', 'The selected Xray profile does not exist or is invalid.');
		main.xray_profile = null;
	}

	return model;
}

// The selected server (SSH) or profile (Xray), or null.
function selected(model) {
	let main = model.main;

	if (main.transport == 'ssh')
		return filter(model.servers, (s) => s.sid == main.ssh_server)[0];

	return filter(model.profiles, (p) => p.sid == main.xray_profile)[0];
}

// Whether there is anything to tunnel: always in proxy-all; in selected-rules an enabled rule or the proxy list.
function targets(model) {
	if (model.main.mode != 'selected-rules')
		return true;

	if (model.lists.proxy.enabled)
		return true;

	for (let r in model.rules)
		if (r.enabled)
			return true;

	return false;
}

// The dnsmasq instance that serves the LAN and its confdir (dnsmasq.init: confdir or /tmp/dnsmasq.<sec>.d).
// Same choice as the init's default instance: the first enabled anonymous section, else the first enabled one.
function dnsmasq_instance(c) {
	c ??= cursor();

	let first = null, anon = null;

	c.foreach('dhcp', 'dnsmasq', (s) => {
		if (parse_bool(s.disabled) === true)
			return;

		let ifc = s.interface;
		let serves_lan = ifc == null || ifc == 'lan' || (type(ifc) == 'array' && index(ifc, 'lan') >= 0);

		if (!serves_lan)
			return;

		first ??= s;

		if (s['.anonymous'])
			anon ??= s;
	});

	let s = anon ?? first;

	if (!s || !match(s['.name'], /^[A-Za-z0-9_]+$/))
		return null;

	let confdir = scalar(s.confdir);

	if (confdir != null)
		confdir = split(confdir, ',')[0];

	if (confdir == null || substr(confdir, 0, 1) != '/')
		confdir = `/tmp/dnsmasq.${s['.name']}.d`;

	return { name: s['.name'], confdir };
}

export { load, selected, targets, dnsmasq_instance, parse_bool };
