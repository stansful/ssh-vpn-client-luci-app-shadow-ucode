'use strict';

// links.uc against the desktop: tests/unit/vectors/links.json (118 links run through the desktop's
// parser and outbound builder) and tests/unit/links/extra.json (edge cases, made by
// tests/unit/links/gen-extra.mjs from the same desktop code). Every outbound that builds is also
// loaded with `xray run -test`, and the credential checks are compared with what xray accepts.

import { readfile, writefile, unlink } from 'fs';
import { sha256 } from 'digest';
import { parse, parse_import, outbound, normalize_name, ascii_host } from 'shadow-vpn.links';

const HERE = sourcepath(0, true);
const TMP = '/tmp/links_test';
const U = '11111111-1111-4111-8111-111111111111';
const PBK = 'Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw';
const X25519_ENCRYPTION = 'mlkem768x25519plus.native.0rtt.RINAYYLZa3HDG3fU5hnxBg2jrkJ1wg-bq5HwEitmXHA';

let failures = 0;

function pass(name) {
	print(`ok ${name}\n`);
}

function fail(name, why) {
	failures++;
	print(`not ok ${name}: ${why}\n`);
}

function check(name, cond, why) {
	cond ? pass(name) : fail(name, why ?? 'false');
}

// First difference between two JSON values (types strict, key order ignored), or null.
function diff(a, b, path) {
	path ??= '$';

	if (type(a) != type(b))
		return `${path}: ${sprintf('%J', a)} != ${sprintf('%J', b)}`;

	if (type(a) == 'array') {
		if (length(a) != length(b))
			return `${path}: length ${length(a)} != ${length(b)}`;

		for (let i = 0; i < length(a); i++) {
			let d = diff(a[i], b[i], `${path}[${i}]`);

			if (d)
				return d;
		}

		return null;
	}

	if (type(a) == 'object') {
		for (let k in a)
			if (!exists(b, k))
				return `${path}.${k}: unexpected`;

		for (let k in b) {
			if (!exists(a, k))
				return `${path}.${k}: missing`;

			let d = diff(a[k], b[k], `${path}.${k}`);

			if (d)
				return d;
		}

		return null;
	}

	return (a === b) ? null : `${path}: ${sprintf('%J', a)} != ${sprintf('%J', b)}`;
}

function range(n) {
	let a = [];

	for (let i = 0; i < n; i++)
		push(a, i);

	return a;
}

// JSON.stringify with sorted keys, which the corpus digests outbounds with.
function json_text(s) {
	let out = '"';

	for (let i = 0; i < length(s); i++) {
		let c = ord(s, i);

		if (c == 0x22 || c == 0x5c)
			out += '\\' + chr(c);
		else if (c == 0x08) out += '\\b';
		else if (c == 0x09) out += '\\t';
		else if (c == 0x0a) out += '\\n';
		else if (c == 0x0c) out += '\\f';
		else if (c == 0x0d) out += '\\r';
		else if (c < 0x20)
			out += sprintf('\\u%04x', c);
		else
			out += chr(c);
	}

	return out + '"';
}

function canon(v) {
	let t = type(v);

	if (t == 'array')
		return '[' + join(',', map(v, canon)) + ']';
	if (t == 'object')
		return '{' + join(',', map(sort(keys(v)), (k) => json_text(k) + ':' + canon(v[k]))) + '}';
	if (t == 'string')
		return json_text(v);

	return sprintf('%J', v);
}

function load(path) {
	return json(readfile(path));
}

function scheme_supported(link) {
	return match(link, /^(vless|vmess|trojan|hysteria2|hy2):\/\//i) != null;
}

// String#trim for the plain vectors (the generated ones carry the desktop's own trim).
function trimmed(link) {
	return replace(replace(link, /^[ \t\r\n]+/, ''), /[ \t\r\n]+$/, '');
}

// What parse() must return for a desktop parse result.
function expected_profile(desktop, ob) {
	return {
		name: normalize_name(desktop.name) || `${desktop.protocol}-${desktop.host}:${desktop.port}`,
		protocol: desktop.protocol,
		host: desktop.host,
		port: desktop.port,
		hop_ports: desktop.hopPorts ?? '',
		transport: desktop.transport,
		security: desktop.security,
		flow: desktop.flow,
		insecure_without_pin: desktop.insecureWithoutPin ?? false,
		supported: ob.error == null,
		fingerprint: desktop.fingerprint,
		hosts: [ desktop.host ]
	};
}

function check_parse(name, link, want, want_outbound, stored) {
	let r = parse(link);

	if (want.error != null) {
		check(name, !r.ok && r.error == want.error, r.ok ? 'parsed' : `error ${sprintf('%J', r.error)} != ${sprintf('%J', want.error)}`);
		return;
	}

	if (!r.ok) {
		fail(name, `error ${sprintf('%J', r.error)}`);
		return;
	}

	let profile = { ...r.profile };

	delete profile.problem;

	let d = diff(profile, expected_profile(want, want_outbound));

	if (!d && !r.profile.supported && r.profile.problem != want_outbound.error)
		d = `problem ${sprintf('%J', r.profile.problem)} != ${sprintf('%J', want_outbound.error)}`;
	if (!d && r.link != (stored ?? trimmed(link)))
		d = 'link is not the trimmed input';

	d ? fail(name, d) : pass(name);
}

function check_outbound(name, link, want, opts) {
	let r = outbound(link, opts);

	if (want.error != null) {
		check(name, !r.ok && r.error == want.error, r.ok ? 'built' : `error ${sprintf('%J', r.error)} != ${sprintf('%J', want.error)}`);
		return;
	}

	if (!r.ok) {
		fail(name, `error ${sprintf('%J', r.error)}`);
		return;
	}

	if (want.sha256 != null) {
		check(name, sha256(canon(r.outbound)) == want.sha256, `digest differs: ${canon(r.outbound)}`);
		return;
	}

	let d = diff(r.outbound, want);

	d ? fail(name, d) : pass(name);
}

let xray_runs = 0;

// Exit status of `xray run -test` on a minimal config around the outbound; output in TMP.log.
function xray_test(ob) {
	let path = `${TMP}.${xray_runs++}.json`;
	let config = {
		log: { loglevel: 'warning' },
		inbounds: [ { tag: 'socks-in', protocol: 'socks', listen: '127.0.0.1', port: 19080, settings: { udp: true, auth: 'noauth' } } ],
		outbounds: [ ob, { tag: 'direct', protocol: 'freedom' } ]
	};

	writefile(path, sprintf('%J', config));

	let rc = system(`xray run -test -c ${path} >${TMP}.log 2>&1`);

	unlink(path);

	return rc;
}

function xray_error() {
	let lines = filter(split(readfile(`${TMP}.log`) ?? '', '\n'), (l) => l != '');

	return length(lines) ? lines[length(lines) - 1] : '?';
}

function check_xray(name, ob) {
	let rc = xray_test(ob);

	(rc == 0) ? pass(name) : fail(name, `xray exit ${rc}: ${xray_error()}`);
}

// The router builds no outbound for a link its parser rejects; the desktop's builder did not
// check (a missing port, "443abc") or failed with a runtime message ("Invalid URL", a JSON.parse
// message). A link with an unknown scheme keeps the builder's own message.
function router_outbound(v, parsed) {
	if (parsed.error != null && scheme_supported(trimmed(v.link)))
		return { error: parsed.error };

	return v.outbound;
}

// ---- Desktop vectors ------------------------------------------------------------------------

const REALITY_KEY_MESSAGE = 'Invalid REALITY public key (pbk): expected 43 base64url characters.';
const ENCRYPTION_MESSAGE = 'Unsupported VLESS encryption. Ask your provider for a current link.';

// Where the router differs from links.json on purpose (DESIGN §5).
const DEVIATIONS = {
	// pbk=PUBLICKEY is not a REALITY key; xray would print it back.
	'43': { parse: { error: REALITY_KEY_MESSAGE }, outbound: { error: REALITY_KEY_MESSAGE } },
	// encryption=mlkem768x25519plus.native.0rtt.abc has no key and makes xray 26.3.27 panic.
	'50': { outbound: { error: ENCRYPTION_MESSAGE } }
};

let vectors = load(`${HERE}/vectors/links.json`);

check('vectors: 118 desktop vectors', length(vectors) == 118, `${length(vectors)} vectors`);

for (let i = 0; i < length(vectors); i++) {
	let v = vectors[i], dev = DEVIATIONS[`${i}`] ?? {};
	let want_parse = dev.parse ?? v.parse;
	let want_outbound = dev.outbound ?? router_outbound(v, want_parse);

	if (want_parse.name != null && normalize_name(want_parse.name) != want_parse.name)
		fail(`vector ${i} name`, 'normalize_name changes a desktop vector name');

	check_parse(`vector ${i} parse`, v.link, want_parse, want_outbound);
	check_outbound(`vector ${i} outbound`, v.link, want_outbound);

	if (want_outbound.error == null)
		check_xray(`vector ${i} xray accepts`, outbound(v.link).outbound);
}

// ---- Extra desktop vectors ------------------------------------------------------------------

let extra = load(`${HERE}/links/extra.json`);

for (let i = 0; i < length(extra.vectors); i++) {
	let v = extra.vectors[i];
	let want_outbound = router_outbound(v, v.parse);

	check_parse(`extra ${i} parse`, v.link, v.parse, want_outbound, v.stored);
	check_outbound(`extra ${i} outbound`, v.link, want_outbound);

	if (v.outbound_new != null)
		check_outbound(`extra ${i} outbound xray ${extra.xray_version_new}`, v.link,
			router_outbound({ link: v.link, outbound: v.outbound_new }, v.parse), { xray_version: extra.xray_version_new });

	if (want_outbound.error != null)
		continue;

	if (v.xray === false)
		check(`extra ${i} xray refuses, as for the desktop`, xray_test(outbound(v.link).outbound) != 0, 'xray accepted it');
	else
		check_xray(`extra ${i} xray accepts`, outbound(v.link).outbound);
}

// ---- Seeded corpus of mutated links ---------------------------------------------------------

// Errors the desktop does not have. Where the router gives one and the desktop does not, xray
// must refuse what the desktop would have rendered.
const ROUTER_ONLY = [
	'Invalid VLESS id: expected a UUID or up to 30 characters.',
	'Invalid VMess id: expected a UUID or up to 30 characters.',
	'Trojan link must contain a password.',
	'Invalid Trojan password: expected percent-encoded UTF-8.',
	'Hysteria 2 link must contain a password.',
	REALITY_KEY_MESSAGE,
	'Invalid REALITY short id (sid): expected up to 8 bytes in hex.',
	ENCRYPTION_MESSAGE
];

let stricter = 0;

for (let i = 0; i < length(extra.fuzz); i++) {
	let v = extra.fuzz[i];

	if (v.strict) {
		let r = parse(v.link), ob = outbound(v.link);
		let router_error = r.ok ? ob.error : r.error;

		stricter++;
		check(`fuzz ${i} stricter where xray refuses`, index(ROUTER_ONLY, router_error) >= 0 &&
			(v.outbound.error != null || xray_test(v.outbound) != 0), `router: ${router_error}`);
		continue;
	}

	let want_outbound = router_outbound(v, v.parse);

	check_parse(`fuzz ${i} parse`, v.link, v.parse, want_outbound, v.stored);
	check_outbound(`fuzz ${i} outbound`, v.link, want_outbound);
}

check('fuzz: most links compared field by field', stricter < length(extra.fuzz) / 4, `${stricter} of ${length(extra.fuzz)} skipped`);

// ---- Bulk import ----------------------------------------------------------------------------

{
	let r = parse_import(extra.import.text);
	let names = map(filter(r.results, (x) => x.ok), (x) => x.profile.name);
	let fps = map(filter(r.results, (x) => x.ok), (x) => x.profile.fingerprint);
	let errors = map(filter(r.results, (x) => !x.ok), (x) => x.error);
	let lines = map(r.results, (x) => x.line);

	check('import: names', !diff(names, extra.import.names), diff(names, extra.import.names));
	check('import: fingerprints', !diff(fps, extra.import.fingerprints), diff(fps, extra.import.fingerprints));
	check('import: errors', !diff(errors, extra.import.errors), diff(errors, extra.import.errors));
	check('import: skipped', r.skipped == extra.import.skipped, `${r.skipped}`);
	check('import: line numbers', !diff(lines, [ 3, 4, 5, 6 ]), sprintf('%J', lines));
	check('import: link is the trimmed line', r.results[0].link == `vless://${U}@example.com:443#one`, r.results[0].link);
}

{
	let r = parse_import(join('', map(range(2097153), () => 'x')));

	check('import: text limit', length(r.results) == 1 && r.results[0].error == 'Import text is longer than 2097152 characters.' && r.skipped == 0,
		sprintf('%J', r.results[0]));
}

{
	let lines = [];

	for (let i = 0; i < 2001; i++)
		push(lines, '#');

	let r = parse_import(join('\n', lines));

	// the router's limit (const.uc LIMITS.import_lines): what the 1000-profile cap can use
	check('import: line limit', r.results[0]?.error == 'Import contains 2001 lines; maximum is 2000. Extra lines were ignored.' &&
		length(r.results) == 1 && r.skipped == 2000, sprintf('%J', [ r.results[0], r.skipped ]));
}

// Router limits that keep one hostile link from holding rpcd for seconds (the desktop has neither).
{
	let label = join('', map(range(40), () => 'a'));
	let host = join('.', map(range(7), () => label)) + '.example';
	let r = parse(`vless://11111111-1111-4111-8111-111111111111@${host}:443?type=tcp#long`);

	check('limits: a host longer than 253 characters is refused',
		!r.ok && r.error == 'Proxy server address is longer than 253 characters.', sprintf('%J', r));

	let idn = join('', map(range(3000), () => 'я'));
	let t0 = clock(true);

	r = parse(`vless://11111111-1111-4111-8111-111111111111@${idn}.example:443?type=tcp#idn`);

	let t1 = clock(true), ms = (t1[0] - t0[0]) * 1000 + (t1[1] - t0[1]) / 1000000;

	// no timing assert: the check is that it is refused before any IDNA mapping of 3000 letters
	check('limits: a host of thousands of letters is refused as no host', !r.ok &&
		r.error == 'VLESS URI must contain host and valid port.', sprintf('%J (%d ms)', r, ms));

	let params = join('&', map(range(129), (i) => `k${i}=v`));

	r = parse(`vless://11111111-1111-4111-8111-111111111111@nl.example.net:443?${params}#many`);
	check('limits: more than 128 query parameters are refused', !r.ok && r.error == 'Proxy link has more than 128 parameters.',
		sprintf('%J', r));

	r = parse(`vless://11111111-1111-4111-8111-111111111111@nl.example.net:443?type=tcp&${join('&', map(range(100), (i) => `k${i}=v`))}#ok`);
	check('limits: 100 parameters still parse', r.ok, sprintf('%J', r));
}

// tunnel-check dials a check endpoint the settings accept in Unicode by its punycode name
check('ascii_host: an IDN check endpoint in punycode', ascii_host('яндекс.рф') == 'xn--d1acpjx3f.xn--p1ai' &&
	ascii_host('YouTube.com') == 'youtube.com' && ascii_host('a b') == null, sprintf('%J', [ ascii_host('яндекс.рф'), ascii_host('a b') ]));

check('import: non-string', !diff(parse_import(null), { results: [], skipped: 1 }), sprintf('%J', parse_import(null)));

{
	let long = 'vless://' + join('', map(range(65537), () => 'a'));

	check('parse: link limit', parse(long).error == 'Proxy link is longer than 65536 characters.', parse(long).error);
	check('parse: non-string', parse(42).error == 'Only vless://, vmess://, trojan://, and hysteria2:// links are supported.', parse(42).error);
	check('outbound: non-string', outbound(null).error == 'Unsupported proxy URI protocol.', outbound(null).error);
}

// ---- Credentials: rejected before rendering, exactly where xray would refuse them -----------

function pct_all(s) {
	let out = '';

	for (let i = 0; i < length(s); i++)
		out += sprintf('%%%02X', ord(s, i));

	return out;
}

function b64(s) {
	return b64enc(s);
}

function repeat(s, n) {
	let out = '';

	for (let i = 0; i < n; i++)
		out += s;

	return out;
}

function vless_outbound(id, extra_user) {
	return {
		protocol: 'vless', tag: 'proxy',
		settings: { vnext: [ { address: 'example.com', port: 443, users: [ { id, encryption: 'none', ...(extra_user ?? {}) } ] } ] }
	};
}

function reality_outbound(pbk, sid) {
	let reality = { serverName: 'www.example.com', fingerprint: 'chrome', shortId: sid };

	if (pbk != null)
		reality.publicKey = pbk;

	return { ...vless_outbound(U), streamSettings: { security: 'reality', realitySettings: reality } };
}

// The router accepts a value exactly when xray does, and never repeats a rejected one.
function check_agreement(name, value, r, ob) {
	let xray_ok = (xray_test(ob) == 0);

	if (r.ok != xray_ok) {
		fail(name, r.ok ? `accepted, xray refuses: ${xray_error()}` : `rejected (${r.error}), xray accepts`);
		return;
	}

	if (!r.ok && value != null && length(value) >= 3 && index(r.error, value) >= 0) {
		fail(name, 'error message repeats the value');
		return;
	}

	pass(name);
}

const IDS = [
	[ 'one character', 'a' ],
	[ '30 characters', repeat('a', 30) ],
	[ '31 characters', repeat('a', 31) ],
	[ '30 bytes of Cyrillic', repeat('\xd1\x8f', 15) ],
	[ '32 bytes of Cyrillic', repeat('\xd1\x8f', 16) ],
	[ 'UUID', U ],
	[ 'UUID upper case', uc(U) ],
	[ 'UUID without dashes', replace(U, /-/g, '') ],
	[ 'UUID with a leading dash', '-' + replace(U, /-/g, '') ],
	[ 'UUID with three dashes', '11111111-1111-4111-81111111111111111' ],
	[ '32 hex digits and junk', replace(U, /-/g, '') + 'zz' ],
	[ '36 characters, not hex', 'g1111111-1111-4111-8111-111111111111' ],
	[ '37 characters', U + '1' ],
	[ 'UUID missing a digit', substr(U, 0, 35) ],
	[ 'empty', '' ]
];

for (let t in IDS) {
	let r = parse(`vless://${pct_all(t[1])}@example.com:443?security=tls#id`);

	check_agreement(`credentials: VLESS id, ${t[0]}`, t[1], r, vless_outbound(t[1]));

	let vm = parse(`vmess://${b64(sprintf('%J', { add: 'example.com', port: 443, id: t[1] }))}`);

	check(`credentials: VMess id, ${t[0]}`, vm.ok == r.ok, vm.error ?? 'accepted');
}

{
	let r = parse('vless://%zz@example.com:443#bad-escape');

	check('credentials: VLESS id with a bad escape', r.error == 'Invalid VLESS id: expected a UUID or up to 30 characters.', r.error);
	check('credentials: VMess without id',
		parse(`vmess://${b64('{"add":"example.com","port":443}')}`).error == 'Invalid VMess id: expected a UUID or up to 30 characters.');
	check('credentials: Trojan without password', parse('trojan://@example.com:443').error == 'Trojan link must contain a password.');
	check('credentials: Trojan with a bad escape', parse('trojan://p%zz@example.com:443').error == 'Invalid Trojan password: expected percent-encoded UTF-8.');
	check('credentials: Hysteria 2 without password', parse('hy2://example.com:443').error == 'Hysteria 2 link must contain a password.');
	check('credentials: Hysteria 2 with an empty password', parse('hy2://@example.com:443').error == 'Hysteria 2 link must contain a password.');
	check('credentials: REALITY without pbk', parse(`vless://${U}@example.com:443?security=reality&sni=a.example`).error == REALITY_KEY_MESSAGE);
}

const PUBLIC_KEYS = [
	[ 'valid', PBK ],
	[ 'other trailing bits', substr(PBK, 0, 42) + 'x' ],
	[ '42 characters', substr(PBK, 0, 42) ],
	[ '44 characters', PBK + 'A' ],
	[ 'padded', PBK + '=' ],
	[ 'standard alphabet', '+' + substr(PBK, 1) ],
	[ 'not base64', 'PUBLICKEY' ]
];

for (let t in PUBLIC_KEYS) {
	let r = parse(`vless://${U}@example.com:443?security=reality&sni=www.example.com&fp=chrome&sid=ab&pbk=${pct_all(t[1])}#pbk`);

	check_agreement(`credentials: REALITY pbk ${t[0]}`, t[1], r, reality_outbound(t[1], 'ab'));
}

const SHORT_IDS = [ '', 'ab', 'AB', '0123456789abcdef', 'abc', '0123456789abcdef01', 'zz' ];

for (let sid in SHORT_IDS) {
	let r = parse(`vless://${U}@example.com:443?security=reality&sni=www.example.com&fp=chrome&pbk=${PBK}&sid=${sid}#sid`);

	check_agreement(`credentials: REALITY sid "${sid}"`, sid, r, reality_outbound(PBK, sid));
}

// ---- VLESS encryption -----------------------------------------------------------------------

{
	let out = `${TMP}.vlessenc`;

	system(`xray vlessenc >${out} 2>&1`);

	let keys = match(readfile(out) ?? '', /"encryption": "(mlkem768x25519plus\.native\.0rtt\.[A-Za-z0-9_-]+)"\n*$/);

	unlink(out);

	let pq = keys ? keys[1] : null;

	check('encryption: xray vlessenc gives an ML-KEM key', pq != null);

	let values = [
		[ 'none', 'none' ],
		[ 'X25519 key', X25519_ENCRYPTION ],
		[ 'xorpub 1rtt', replace(X25519_ENCRYPTION, 'native.0rtt', 'xorpub.1rtt') ],
		[ 'with padding', replace(X25519_ENCRYPTION, '0rtt.', '0rtt.100-111-1111.') ],
		[ 'ML-KEM key', pq ?? X25519_ENCRYPTION ],
		[ 'no key', 'mlkem768x25519plus.native.0rtt.abc' ],
		[ 'empty key', 'mlkem768x25519plus.native.0rtt.' ],
		[ 'short key', substr(X25519_ENCRYPTION, 0, length(X25519_ENCRYPTION) - 1) ],
		[ 'unknown mode', replace(X25519_ENCRYPTION, 'native', 'nativ3') ],
		[ 'garbage', 'garbage' ],
		[ 'empty', '' ]
	];

	for (let t in values) {
		let link = `vless://${U}@example.com:443?security=tls&encryption=${pct_all(t[1])}#enc`;
		let r = outbound(link);

		check_agreement(`encryption: ${t[0]}`, null, r, vless_outbound(U, { encryption: t[1] }));

		if (!r.ok)
			check(`encryption: ${t[0]} still parses, unsupported`, parse(link).ok && !parse(link).profile.supported &&
				parse(link).profile.problem == ENCRYPTION_MESSAGE, sprintf('%J', parse(link)));
	}
}

// ---- Names ----------------------------------------------------------------------------------

const NAMES = [
	[ 'tabs and newlines', '  a\tb\nc  ', 'a b c' ],
	[ 'line and paragraph separators', 'x\xe2\x80\xa8y\xe2\x80\xa9z', 'x y z' ],
	[ 'C1 control and no-break space', '\xc2\x85x\xc2\xa0', 'x' ],
	[ 'NUL and DEL', 'a\u0000b\u007fc', 'a b c' ],
	[ '70 Cyrillic letters', repeat('\xd1\x8f', 70), repeat('\xd1\x8f', 64) ],
	[ 'cut inside spaces', 'a' + repeat(' ', 63) + 'b', 'a' ],
	[ 'broken UTF-8', '\xff', '\xef\xbf\xbd' ],
	[ 'em space only', '\xe2\x80\x83', '' ],
	[ 'plain', 'Plain name', 'Plain name' ]
];

for (let t in NAMES)
	check(`normalize_name: ${t[0]}`, normalize_name(t[1]) == t[2], sprintf('%J', normalize_name(t[1])));

check('normalize_name of a non-string', normalize_name(null) == '');

{
	let r = parse(`vless://${U}@example.com:443#a%09b%0Ac`);

	check('parse: a name is one line', r.profile?.name == 'a b c', sprintf('%J', r.profile?.name));

	r = parse(`vless://${U}@example.com:443#%01`);
	check('parse: a name of control characters falls back', r.profile?.name == 'vless-example.com:443', sprintf('%J', r.profile?.name));
}

// ---- Shape ----------------------------------------------------------------------------------

{
	let r = parse(`hysteria2://pw@example.com:443,20000-30000?insecure=1#hop`);

	check('profile: hop ports and insecure flag', r.profile?.hop_ports == '443,20000-30000' && r.profile?.insecure_without_pin === true,
		sprintf('%J', r.profile));

	let ob = outbound(`vless://${U}@example.com:443?security=tls`).outbound;

	check('outbound: no sockopt, tag proxy', ob.tag == 'proxy' && ob.streamSettings?.sockopt == null, sprintf('%J', ob));
}

// ---- TLS pin (pcs) and name (vcn): a router extension, the desktop reads them for Hysteria 2 only ----

{
	const PIN = '18ce064802a212e16f5a0b1970450f0cd68192b4d6f228e20d27edec3015cebc';
	const PIN_B64 = 'uohFLxsMGjxNfm9aSTgnFrqIRS8bDBo8TX5vWkk4JxY';
	const PIN_B64_HEX = 'ba88452f1b0c1a3c4d7e6f5a49382716ba88452f1b0c1a3c4d7e6f5a49382716';
	let tls_of = (link) => outbound(link).outbound?.streamSettings?.tlsSettings;

	let t = tls_of(`trojan://secret@example.com:443?security=tls&sni=vpn.example.com&pcs=${uc(PIN)}#pinned`);

	check('pcs: a trojan TLS link is pinned (hex, any case)', t?.pinnedPeerCertSha256 == PIN && t?.serverName == 'vpn.example.com', sprintf('%J', t));
	check_xray('pcs: xray accepts the pinned trojan outbound', outbound(`trojan://secret@example.com:443?security=tls&pcs=${PIN}`).outbound);

	t = tls_of(`vless://${U}@example.com:443?security=tls&type=ws&pcs=${PIN_B64},${PIN}&vcn=real.example.com`);
	check('pcs: base64 pins and several of them, vcn as verifyPeerCertByName',
		t?.pinnedPeerCertSha256 == `${PIN_B64_HEX},${PIN}` && t?.verifyPeerCertByName == 'real.example.com', sprintf('%J', t));

	let ob = outbound(`vless://${U}@example.com:443?security=reality&pbk=IFE3KJvjzECR7F4aGhVqOk7p6cEChB-ICu8WbWn_OBk&sni=a.example&pcs=${PIN}`).outbound;
	check('pcs: ignored without TLS (REALITY)', ob?.streamSettings?.tlsSettings == null && ob?.streamSettings?.realitySettings != null, sprintf('%J', ob));

	let r = parse(`trojan://secret@example.com:443?security=tls&pcs=nothex#bad`);
	check('pcs: a malformed pin makes the profile unsupported with its own message',
		r.ok && r.profile.supported === false && r.profile.problem == 'Invalid pcs: expected a SHA-256 certificate hash.' &&
		outbound(`trojan://secret@example.com:443?security=tls&pcs=nothex#bad`).error == 'Invalid pcs: expected a SHA-256 certificate hash.',
		sprintf('%J', r));
}

exit(failures ? 1 : 0);
