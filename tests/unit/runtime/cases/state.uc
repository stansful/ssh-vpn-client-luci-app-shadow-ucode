'use strict';

import { access, unlink, rmdir, glob, readfile } from 'fs';
import * as state from 'shadow-vpn.state';
import { ok, eq, done } from 'rt';

// redaction: desktop redactSecrets plus what xray -test echoes for malformed credentials
let r = state.redact;

eq('state/redact: json password', r('bad "password": "s3cr\\"et" here'), 'bad "password":"<redacted>" here');
eq('state/redact: auth', r('{"auth":"hy2-pass"}'), '{"auth":"<redacted>"}');
eq('state/redact: link userinfo', r('dial vless://uuid-here@host:443?x'), 'dial vless://<redacted>@host:443?x');
eq('state/redact: password=', r('x password=hunter2 y'), 'x password=<redacted> y');
eq('state/redact: passphrase:', r('passphrase: abc def'), 'passphrase=<redacted> def');
eq('state/redact: invalid UUID', r('infra/conf: invalid UUID: 1234-not-a-uuid'), 'infra/conf: invalid UUID: <redacted>');
eq('state/redact: REALITY password', r('invalid "password": AAAA'), 'invalid "password": <redacted>');
eq('state/redact: shortId', r('"shortId": "zz-not-hex"'), '"shortId": <redacted>');
eq('state/redact: plain text untouched', r('Configuration OK.'), 'Configuration OK.');

let out = "Xray 26.3.27\nA unified platform\nFailed to start: main: failed to load config files: [/var/run/shadow-vpn/next/xray.json] > infra/conf: failed to build outbound config with tag proxy > infra/conf: invalid UUID: 0000-bad\n";

eq('state/xray_failure: reason without boilerplate, redacted', state.xray_failure(out),
	'infra/conf: failed to build outbound config with tag proxy > infra/conf: invalid UUID: <redacted>');
let long = '';

for (let i = 0; i < 100; i++)
	long += sprintf('%09d|', i);

eq('state/xray_failure: nothing printed', [ state.xray_failure(''), state.xray_failure(null) ], [ null, null ]);
eq('state/xray_failure: else the last line', state.xray_failure('Xray 26.3.27\npanic: bad\n\n'), 'panic: bad');

let cut = state.xray_failure(`Failed to start: ${long}`);

ok('state/xray_failure: long reasons are cut from the front', index(cut, '…') == 0 && substr(cut, -400) == substr(long, -400) &&
	length(cut) == length('…') + 400, cut);
ok('state/job ids: traversal refused', !state.valid_job_id('../x') && !state.valid_job_id('a/b') && state.valid_job_id('1761-000000001'));
eq('state/job_read refuses ../x', state.job_read('../x'), null);

// live: only where /var/run/shadow-vpn does not exist yet (run.sh's container is thrown away)
const RUN = '/var/run/shadow-vpn';

if (!access(RUN)) {
	let s0 = state.read();

	eq('state/read default', s0.phase, 'disconnected');

	let s1 = state.write({ phase: 'connecting', message: 'Starting.', transport: 'xray' });

	ok('state/write stamps since on a phase change', s1.since > 0 && s1.phase == 'connecting');

	let s2 = state.write({ message: 'Still starting.' });

	ok('state/write merges', s2.phase == 'connecting' && s2.transport == 'xray' && s2.since == s1.since && s2.message == 'Still starting.');

	let thrown = false;

	try {
		state.write({ phase: 'bogus' });
	}
	catch (e) {
		thrown = true;
	}

	ok('state/write refuses an unknown phase', thrown && state.read().phase == 'connecting');

	state.attention_add('port_busy', 'Port 12345 is already in use by nginx.');
	state.attention_add('port_busy', 'Port 5300 is already in use by unbound.');
	state.attention_add('list_failed', 'Download failed.', { key: 'proxy' });
	state.attention_add('list_failed', 'Download failed.', { key: 'direct' });

	let list = state.attention_list();

	eq('state/attention: one entry per code (and key)', map(list, (a) => a.id), [ 'port_busy', 'list_failed:proxy', 'list_failed:direct' ]);
	eq('state/attention: a repeat refreshes the text', list[0].message, 'Port 5300 is already in use by unbound.');
	ok('state/attention_dismiss', state.attention_dismiss('port_busy') && !state.attention_dismiss('port_busy'));
	state.attention_clear('list_failed');
	eq('state/attention_clear', state.attention_list(), []);

	state.job_write('1761-000000001', { name: 'converge', state: 'running', started: 1 });

	let j = state.job_write('1761-000000001', { state: 'done', result: { rc: 0 } });

	ok('state/job: finished stamped', j.finished > 0 && j.name == 'converge' && j.result.rc == 0);
	eq('state/job_read', state.job_read('1761-000000001')?.state, 'done');

	for (let f in [ ...(glob(`${RUN}/jobs/*`) ?? []), ...(glob(`${RUN}/*`) ?? []) ])
		unlink(f);

	rmdir(`${RUN}/jobs`);
	rmdir(RUN);
}
else {
	print('ok state/live # skipped: /var/run/shadow-vpn already exists\n');
}

done();
