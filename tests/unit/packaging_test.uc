'use strict';
// Packaging checks that run in the lab router image (tests/unit/run.sh packaging): busybox ash
// syntax, install.sh refusals that stop before anything is touched, the backend's package
// metadata, and LuCI's own reader on edge.lmo (what the official po2lmo writes for edge.po;
// tests/unit/packaging/po2lmo_test.sh checks that build/po2lmo.py writes the same bytes).
// The end-to-end install test needs Docker on the host: tests/unit/packaging/install_test.sh.

import { readfile, writefile, mkdir, unlink, popen } from 'fs';

const HERE = sourcepath(0, true);
const SRC = HERE + '/../..';
const FIX = HERE + '/packaging';
const RELEASE = '/etc/openwrt_release';
const FAKEBIN = '/tmp/shv-packaging-fakebin';

let failed = 0;

function check(name, cond, why) {
	if (cond)
		print('ok ', name, '\n');
	else {
		print('not ok ', name, ': ', why ?? 'failed', '\n');
		failed++;
	}
}

function shell_quote(s) {
	return "'" + replace(s, "'", "'\\''") + "'";
}

function run(cmd) {
	const p = popen(cmd + ' 2>&1', 'r');
	const out = p.read('all') ?? '';
	return { rc: p.close(), out };
}

function tail(s) {
	return substr(trim(s), -160);
}

// install.sh with a fake /etc/openwrt_release; the real file is put back before anything else runs
function with_release(text, cmd) {
	const orig = readfile(RELEASE);
	let res;
	writefile(RELEASE, text);
	try {
		res = run(cmd);
	}
	catch (e) {
		res = { rc: -1, out: '' + e };
	}
	writefile(RELEASE, orig);
	return res;
}

function release(version) {
	return sprintf("DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='%s'\nDISTRIB_REVISION='r1'\n", version);
}

const INSTALL = shell_quote(SRC + '/install.sh');
const NOWHERE = 'SHADOW_BASE_URL=http://127.0.0.1:9 ';

for (let f in [ 'install.sh', 'build/mk_apk.sh' ]) {
	const first = split(readfile(SRC + '/' + f) ?? '', '\n')[0];
	check(f + ' starts with a plain #!/bin/sh', first == '#!/bin/sh', 'first line: ' + first);
	const r = run('sh -n ' + shell_quote(SRC + '/' + f));
	check(f + ' passes busybox ash -n', r.rc == 0, tail(r.out));
}

const script = readfile(SRC + '/install.sh');
check('install.sh never disables certificate checks', index(script, 'no-check-certificate') < 0);
check('install.sh takes SHA256SUMS from the latest GitHub release of this repository',
	index(script, 'RELEASE_URL="https://github.com/$REPO/releases/latest/download"') >= 0 &&
	index(script, 'RELEASE_API="https://api.github.com/repos/$REPO/releases/latest"') >= 0 &&
	index(script, 'REPO=stansful/ssh-vpn-client-luci-app-shadow-ucode\n') >= 0);
check('install.sh shows the one-line install command of this repository',
	index(script, 'sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh)') >= 0);

let r = run('sh ' + INSTALL + ' --help');
check('install.sh --help', r.rc == 0 && index(r.out, '--uninstall') >= 0, tail(r.out));
r = run('sh ' + INSTALL + ' --bogus');
check('install.sh rejects an unknown option', r.rc == 2, 'rc=' + r.rc);
r = run('SHADOW_BASE_URL=ftp://example.org sh ' + INSTALL);
check('install.sh rejects a non-http SHADOW_BASE_URL', r.rc != 0 && index(r.out, 'http://') >= 0, tail(r.out));

r = with_release(release('24.10.8'), NOWHERE + 'sh ' + INSTALL);
check('install.sh refuses OpenWrt 24.10 in Russian and English',
	r.rc != 0 && index(r.out, 'OpenWrt 24.10.8') >= 0 &&
	index(r.out, 'Обновите прошивку') >= 0 && index(r.out, 'Upgrade the firmware') >= 0,
	'rc=' + r.rc + ': ' + tail(r.out));

r = with_release(release('23.05.5'), NOWHERE + 'sh ' + INSTALL);
check('install.sh refuses OpenWrt 23.05', r.rc != 0 && index(r.out, 'OpenWrt 23.05.5') >= 0, tail(r.out));

r = with_release(release('next'), NOWHERE + 'sh ' + INSTALL);
check('install.sh refuses an unknown release', r.rc != 0 && index(r.out, "Cannot tell the OpenWrt version ('next')") >= 0, tail(r.out));

// A clock before the floor that NTP cannot fix stops the installer before any download.
mkdir(FAKEBIN);
writefile(FAKEBIN + '/date', '#!/bin/sh\ncase "$1" in +%s) echo 1600000000 ;; -s) exit 1 ;; *) exec /bin/date "$@" ;; esac\n');
writefile(FAKEBIN + '/ntpd', '#!/bin/sh\nexit 0\n');
run('chmod 755 ' + FAKEBIN + '/date ' + FAKEBIN + '/ntpd');
for (let rel in [ '25.12.6', 'SNAPSHOT', '26.03.0-rc1' ]) {
	r = with_release(release(rel), 'PATH=' + FAKEBIN + ':$PATH ' + NOWHERE + 'sh ' + INSTALL);
	check('install.sh on ' + rel + ' stops at a clock before the floor',
		r.rc != 0 && index(r.out, 'Could not set the clock') >= 0 && index(r.out, 'Downloading') < 0,
		'rc=' + r.rc + ': ' + tail(r.out));
}
unlink(FAKEBIN + '/date');
unlink(FAKEBIN + '/ntpd');

// shadow-vpn/control: the dependencies of DESIGN §4, nothing more
const control = readfile(SRC + '/shadow-vpn/control') ?? '';
const depends = match(control, /(^|\n)Depends: *([^\n]*)/);
const want = 'xray-core openssh-client dnsmasq-full kmod-nft-tproxy kmod-nft-socket ucode ucode-mod-fs ' +
	'ucode-mod-uci ucode-mod-ubus ucode-mod-socket ucode-mod-digest';
check('shadow-vpn depends as DESIGN §4', depends?.[2] == want, 'Depends: ' + depends?.[2]);
check('shadow-vpn ships no /etc/config/shadow-vpn',
	readfile(SRC + '/shadow-vpn/files/etc/config/shadow-vpn') == null);

// LuCI's reader on the official po2lmo output for edge.po
const lmo_dir = '/tmp/shv-packaging-lmo';
mkdir(lmo_dir);
writefile(lmo_dir + '/edge.ru.lmo', readfile(FIX + '/edge.lmo'));
let core;
try {
	core = require('luci.core');
}
catch (e) {
	core = null;
}
if (core) {
	core.load_catalog('ru', lmo_dir);
	core.change_catalog('ru');
	const cases = [
		[ 'plain', core.translate('Overview'), 'Обзор' ],
		[ 'msgctxt', core.translate('Connected', 'Tunnel state'), 'Подключено' ],
		[ 'same msgid without context', core.translate('Connected'), 'Соединено' ],
		[ 'multi-line strings', core.translate('Multi line id'), 'Многострок' ],
		[ 'msgctxt given twice keeps the last', core.translate('Context twice', 'second context'), 'Контекст дважды' ],
		[ 'CRLF lines', core.translate('CRLF line'), 'Строка CRLF' ],
		[ 'plural 1', core.ntranslate(1, '%d domain', '%d domains'), '%d домен' ],
		[ 'plural 3', core.ntranslate(3, '%d domain', '%d domains'), '%d домена' ],
		[ 'plural 5', core.ntranslate(5, '%d domain', '%d domains'), '%d доменов' ],
		[ 'plural with context', core.ntranslate(11, '%d rule', '%d rules', 'rules'), '%d правил' ],
		[ 'an empty plural form falls back to English', core.ntranslate(2, '%d rule', '%d rules', 'rules'), '%d rules' ],
		[ 'untranslated is not stored', core.translate('Untranslated'), null ],
		[ 'msgstr equal to msgid is not stored', core.translate('Same'), null ],
		[ 'obsolete entries are not stored', core.translate('Obsolete'), null ],
	];
	for (let c in cases)
		check('edge.lmo: ' + c[0], c[1] === c[2], sprintf('got %J, want %J', c[1], c[2]));
}
else
	check('luci.core is available', false, 'luci-base missing from the image');
unlink(lmo_dir + '/edge.ru.lmo');

exit(failed ? 1 : 0);
