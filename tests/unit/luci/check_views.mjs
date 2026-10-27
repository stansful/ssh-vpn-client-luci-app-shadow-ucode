// Checks the LuCI views the way luci.js loads them: the 'require' header is scanned with LuCI's own rules,
// the source is compiled with new Function(), and the factory is run against small stand-ins of the LuCI
// classes so a top-level mistake fails here instead of in the browser. Also checks that every _()/N_()
// msgid is in the template catalog.
//
// Usage: node tests/unit/luci/check_views.mjs   (prints ok / not ok lines, exits non-zero on failure)

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.resolve(HERE, '../../../luci-app-shadow-vpn');
const RES = path.join(APP, 'htdocs/luci-static/resources');
const LUCI_CLASSES = new Set([ 'baseclass', 'dom', 'form', 'fs', 'poll', 'request', 'rpc', 'uci', 'ui', 'view', 'validation', 'network' ]);
const VIEWS = [ 'overview', 'ssh', 'xray', 'routing', 'log', 'settings' ];

let failures = 0;

function check(name, cond, why) {
	console.log(cond ? `ok ${name}` : `not ok ${name}: ${why || 'assertion failed'}`);
	if (!cond)
		failures++;
}

// Port of the require scanner in luci.js (compileClass): strings before the first non-require string.
function requires(source) {
	const requirematch = /^require[ \t]+(\S+)(?:[ \t]+as[ \t]+([a-zA-Z_]\S*))?$/;
	const strictmatch = /^use[ \t]+strict$/;
	const deps = [];

	for (let i = 0, off = -1, prev = -1, quote = -1, comment = -1, esc = false; i < source.length; i++) {
		const chr = source.charCodeAt(i);

		if (esc) {
			esc = false;
		}
		else if (comment != -1) {
			if ((comment == 47 && chr == 10) || (comment == 42 && prev == 42 && chr == 47))
				comment = -1;
		}
		else if ((chr == 42 || chr == 47) && prev == 47) {
			comment = chr;
		}
		else if (chr == 92) {
			esc = true;
		}
		else if (chr == quote) {
			const s = source.substring(off, i), m = requirematch.exec(s);

			if (m)
				deps.push({ name: m[1], as: m[2] || m[1].replace(/[^a-zA-Z0-9_]/g, '_') });
			else if (!strictmatch.exec(s))
				break;

			off = -1;
			quote = -1;
		}
		else if (quote == -1 && (chr == 34 || chr == 39)) {
			off = i + 1;
			quote = chr;
		}

		prev = chr;
	}

	return deps;
}

function compile(file) {
	const source = fs.readFileSync(file, 'utf8');
	const deps = requires(source);
	const fn = new Function('window', 'document', 'L', ...deps.map(d => d.as), source);

	return { source, deps, fn };
}

/* Minimal stand-ins: enough for the class factories to run their top level. */

function stubs() {
	const extend = obj => Object.assign(Object.create({ __proto__: null }), obj);
	const any = new Proxy(function() {}, { get: () => any, apply: () => any, construct: () => any });

	globalThis._ = s => s;
	globalThis.N_ = (n, s, p) => (n == 1 ? s : p);
	globalThis.E = () => ({});
	String.prototype.format = function(...a) { let i = 0; return this.replace(/%[sd]/g, () => String(a[i++])); };

	return {
		baseclass: { extend },
		view: { extend },
		rpc: { declare: () => () => Promise.resolve({}) },
		ui: any, dom: any, form: any, poll: any, uci: any, fs: any, request: any, validation: any, network: any
	};
}

function instantiate(file, classes) {
	const { deps, fn } = compile(file);
	const args = deps.map(d => classes[d.name]);

	return fn({}, {}, { url: p => '/' + p, resolveDefault: p => p, env: {} }, ...args);
}

/* Template catalog */

function potIds() {
	const pot = fs.readFileSync(path.join(APP, 'po/templates/shadow-vpn.pot'), 'utf8');
	const ids = new Set();
	const re = /(?:msgctxt "((?:[^"\\]|\\.)*)"\n)?msgid "((?:[^"\\]|\\.)*)"/g;
	let m;

	while ((m = re.exec(pot)))
		ids.add((m[1] ? m[1].replace(/\\(.)/g, '$1') + '\u0004' : '') + m[2].replace(/\\(.)/g, '$1'));

	return ids;
}

function usedIds(source) {
	const STR = String.raw`'((?:[^'\\]|\\.)*)'`;
	const out = [];
	const unq = s => s.replace(/\\(.)/g, '$1');
	let m;
	const re1 = new RegExp(String.raw`(?<![A-Za-z0-9_.])_\(\s*` + STR + String.raw`\s*(?:,\s*` + STR + String.raw`\s*)?\)`, 'g');
	const re2 = new RegExp(String.raw`(?<![A-Za-z0-9_.])N_\([^,]+,\s*` + STR + String.raw`\s*,\s*` + STR + String.raw`\s*(?:,\s*` + STR + String.raw`\s*)?\)`, 'g');

	while ((m = re1.exec(source)))
		out.push((m[2] != null ? unq(m[2]) + '\u0004' : '') + unq(m[1]));

	while ((m = re2.exec(source)))
		out.push((m[3] != null ? unq(m[3]) + '\u0004' : '') + unq(m[1]));

	return out;
}

const classes = stubs();
const ids = potIds();
const commonFile = path.join(RES, 'shadow-vpn/common.js');

try {
	classes['shadow-vpn.common'] = instantiate(commonFile, classes);
	check('luci views: common.js compiles and builds its class', typeof classes['shadow-vpn.common'].el == 'function');
}
catch (e) {
	check('luci views: common.js compiles and builds its class', false, e.message);
}

for (const v of VIEWS) {
	const file = path.join(RES, `view/shadow-vpn/${v}.js`);

	try {
		const { source, deps } = compile(file);
		const unknown = deps.filter(d => !LUCI_CLASSES.has(d.name) && d.name != 'shadow-vpn.common');

		check(`luci views: ${v}.js compiles like LuCI loads it`, true);
		check(`luci views: ${v}.js requires only known classes`, !unknown.length, unknown.map(d => d.name).join(', '));
		check(`luci views: ${v}.js starts with 'use strict'`, /^'use strict';\n'require /.test(source));

		const view = instantiate(file, classes);

		check(`luci views: ${v}.js yields a view with render()`, typeof view.render == 'function');

		const missing = usedIds(source).filter(id => !ids.has(id));

		check(`luci views: ${v}.js msgids are all in the template`, !missing.length, missing.join(' | '));
	}
	catch (e) {
		check(`luci views: ${v}.js compiles like LuCI loads it`, false, e.message);
	}
}

const commonMissing = usedIds(fs.readFileSync(commonFile, 'utf8')).filter(id => !ids.has(id));
check('luci views: common.js msgids are all in the template', !commonMissing.length, commonMissing.join(' | '));

/* The Log page's level of a logread line: procd logs xray's stdout at daemon.info, so xray's own level counts. */
{
	const level = classes['shadow-vpn.common']?.logLevel;
	const T = 'Tue Oct 27 15:23:50 2026';
	const cases = [
		[ `${T} daemon.info xray-run[28636]: 2026/10/27 12:23:50.442314 [Warning] app/observatory/burst: error ping`, 'w' ],
		[ `${T} daemon.info xray-run[28636]: 2026/10/27 12:37:34.399552 [Error] app/dns: failed to retrieve response`, 'e' ],
		[ `${T} daemon.info xray-run[8212]: 2026/10/27 12:48:09.987899 [Info] infra/conf/serial: Reading config`, '' ],
		[ `${T} daemon.info xray[8212]: 2026/10/27 12:48:09.987899 [Debug] app/dispatcher: taking detour`, 'd' ],
		[ `${T} daemon.info xray-run[8212]: Xray 26.3.27 (Xray, Penetrates Everything.) OpenWrt`, '' ],
		[ `${T} daemon.err xray-run[8212]: panic: runtime error`, 'e' ],
		// a crash loop's reason: no time and no level, on stdout
		[ `${T} daemon.info xray-run[8212]: Failed to start: app/proxyman/inbound: failed to listen TCP on 12345`, 'e' ],
		[ `${T} daemon.info shadow-vpn: Failed to start: not xray's`, '' ],
		[ `${T} daemon.warn shadow-vpn: tunnel gate: accept`, 'w' ],
		[ `${T} daemon.debug shadow-vpn: converge: start`, 'd' ],
		[ `${T} daemon.notice ssh: [previous run] Authenticated to 192.0.2.1 ([192.0.2.1]:22) using "publickey".`, '' ],
		// another daemon's text that looks like xray's keeps its syslog level
		[ `${T} daemon.info shadow-vpn: 2026/10/27 12:23:50.442314 [Error] quoted`, '' ]
	];
	const wrong = typeof level == 'function' ? cases.filter(c => level(c[0]) !== c[1]).map(c => `${c[0]} -> ${level(c[0])}`) : [ 'no logLevel' ];

	check('luci views: the Log page reads xray’s own level and the syslog one', !wrong.length, wrong.join(' | '));

	// the filters: rows all, nodebug, warn, err; columns e, w, d, ''
	const shown = classes['shadow-vpn.common']?.logShown;
	const table = { all: [ 1, 1, 1, 1 ], nodebug: [ 1, 1, 0, 1 ], warn: [ 1, 1, 0, 0 ], err: [ 1, 0, 0, 0 ] };
	const off = typeof shown == 'function' ? Object.entries(table).flatMap(([ lv, row ]) =>
		[ 'e', 'w', 'd', '' ].filter((c, i) => shown(c, lv) !== !!row[i]).map(c => `${lv}/${c || 'info'}`)) : [ 'no logShown' ];

	check('luci views: the Log page filters keep exactly their levels', !off.length, off.join(' | '));
}

/* Backend messages: every sentence the router puts in front of the user (errors, phase messages, attention,
 * tunnel-check details) translates through common.js tr() with the Russian catalog. They are collected from
 * the sources: string literals that read like a sentence, outside log calls; a ${...} or %s stands for a value. */

const SRC_ROOT = path.resolve(HERE, '../../..');
const BACKEND = [
	'shadow-vpn/files/usr/libexec/shadow-vpn/apply', 'shadow-vpn/files/usr/libexec/shadow-vpn/job',
	'shadow-vpn/files/usr/libexec/shadow-vpn/lists', 'shadow-vpn/files/usr/libexec/shadow-vpn/tunnel-check',
	'shadow-vpn/files/usr/share/ucode/shadow-vpn/ssh.uc', 'shadow-vpn/files/usr/share/ucode/shadow-vpn/links.uc',
	'shadow-vpn/files/usr/share/ucode/shadow-vpn/validate.uc', 'shadow-vpn/files/usr/share/ucode/shadow-vpn/keys.uc',
	'shadow-vpn/files/usr/share/ucode/shadow-vpn/lists.uc', 'shadow-vpn/files/usr/share/ucode/shadow-vpn/state.uc',
	'shadow-vpn/files/usr/share/ucode/shadow-vpn/xray.uc', 'shadow-vpn/files/usr/share/ucode/shadow-vpn/update.uc',
	'shadow-vpn/files/usr/libexec/shadow-vpn/update', 'luci-app-shadow-vpn/root/usr/share/rpcd/ucode/luci.shadow-vpn'
];
// texts that never reach the page: the log line of a check (the page words the result itself)
const NOT_SHOWN = [ /^Tunnel check succeeded for / ];

function backendMessages() {
	const out = new Map();

	for (const f of BACKEND) {
		fs.readFileSync(path.join(SRC_ROOT, f), 'utf8').split('\n').forEach((line, i) => {
			if (/^\s*(\/\/|\*|\/\*)/.test(line) || /(state\.log|syslog|logger|warn\(|print\(|die\(|\blog\()/.test(line))
				return;

			const msgish = /(result\(|fail\(|error:|message:|detail:|_MESSAGE =|give_up\()/.test(line);
			const re = /(['`])((?:\\.|(?!\1)[^\\])*)\1/g;
			let m;

			while ((m = re.exec(line))) {
				const s = m[2];

				if (/^[A-Z]/.test(s) && / /.test(s) && s.length >= 12 && (/[.?)%]$/.test(s) || msgish) &&
				    !NOT_SHOWN.some(r => r.test(s)))
					out.set(s, `${path.basename(f)}:${i + 1}`);
			}
		});
	}

	return out;
}

function catalog() {
	const po = fs.readFileSync(path.join(APP, 'po/ru/shadow-vpn.po'), 'utf8');
	const map = new Map();
	const unq = s => s.replace(/\\(.)/g, (a, c) => (c == 'n') ? '\n' : c);
	const re = /(?:msgctxt "((?:[^"\\]|\\.)*)"\n)?msgid "((?:[^"\\]|\\.)*)"\n(?:msgid_plural "(?:[^"\\]|\\.)*"\n)?msgstr(?:\[0\])? "((?:[^"\\]|\\.)*)"/g;
	let m;

	while ((m = re.exec(po)))
		if (m[3])
			map.set((m[1] ? unq(m[1]) + '\u0004' : '') + unq(m[2]), unq(m[3]));

	return map;
}

{
	const ru = catalog(), plain = globalThis._;

	globalThis._ = (s, c) => ru.get((c ? c + '\u0004' : '') + s) || s;

	try {
		const common = instantiate(commonFile, classes);
		const messages = backendMessages();
		const untranslated = [];

		for (const [ s, where ] of messages) {
			const sample = s.replace(/\$\{[^}]*\}/g, '42').replace(/%[sd]/g, '42').replace(/\\(.)/g, '$1');

			if (common.tr(sample) === sample)
				untranslated.push(`${where} ${s}`);
		}

		check(`luci views: all ${messages.size} backend messages have a Russian translation`, messages.size > 150 && !untranslated.length,
			untranslated.join(' | '));
	}
	finally {
		globalThis._ = plain;
	}
}

process.exit(failures ? 1 : 0);
