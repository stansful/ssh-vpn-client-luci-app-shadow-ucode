'use strict';

import { access, stat, rmdir, unlink, lsdir } from 'fs';
import { valid_sid, path, read, write, remove } from 'shadow-vpn.secrets';
import { ok, eq, done } from 'rt';

const VALID = [ 's_0123456789ab', 'k_0123456789ab', 'p_0123456789ab', 'r_0123456789ab' ];
const INVALID = [ '../x', 's_../x', 's_0123456789a', 's_0123456789abc', 'S_0123456789AB', 'x_0123456789ab',
	's_0123456789ag', 's_0123456789ab/..', ' s_0123456789ab', 's_0123456789ab\n', '', null, 12, [ 's_0123456789ab' ] ];

for (let sid in VALID)
	ok(`secrets/valid_sid ${sid}`, valid_sid(sid) === true);

for (let sid in INVALID)
	ok(`secrets/valid_sid refuses ${sprintf('%J', sid)}`, valid_sid(sid) === false);

eq('secrets/path refuses ../x', path('../x', 'link'), null);
eq('secrets/path refuses traversal in the kind', path('s_0123456789ab', '../../shadow'), null);
eq('secrets/path refuses an unknown kind', path('s_0123456789ab', 'shadow'), null);
eq('secrets/path: rule ids never reach a path', path('r_0123456789ab', 'link'), null);
eq('secrets/path: password', path('s_0123456789ab', 'password'), '/etc/shadow-vpn/secrets/s_0123456789ab.password');
eq('secrets/path: passphrase', path('k_0123456789ab', 'passphrase'), '/etc/shadow-vpn/secrets/k_0123456789ab.passphrase');
eq('secrets/path: link', path('p_0123456789ab', 'link'), '/etc/shadow-vpn/secrets/p_0123456789ab.link');
eq('secrets/path: key', path('k_0123456789ab', 'key'), '/etc/shadow-vpn/keys/k_0123456789ab');
eq('secrets/read refuses ../x', read('../x', 'link'), null);
ok('secrets/write refuses ../x', write('../x', 'link', 'x') === false);
ok('secrets/write refuses a NUL byte', write('p_0123456789ab', 'link', 'a\0b') === false);

// Live round trip in the throwaway container, only where nothing of ours exists yet.
if (!access('/etc/shadow-vpn')) {
	let sid = 'p_00000000feed';

	ok('secrets/write', write(sid, 'link', 'vless://fake-test-link'));
	eq('secrets/read', read(sid, 'link'), 'vless://fake-test-link');
	eq('secrets/file mode 0600', (stat(path(sid, 'link'))?.mode ?? 0) & 0o777, 0o600);
	eq('secrets/dir mode 0700', (stat('/etc/shadow-vpn/secrets')?.mode ?? 0) & 0o777, 0o700);
	eq('secrets/etc mode 0700', (stat('/etc/shadow-vpn')?.mode ?? 0) & 0o777, 0o700);
	ok('secrets/no tmp left behind', !access(`${path(sid, 'link')}.tmp`));
	ok('secrets/overwrite', write(sid, 'link', 'vless://second') && read(sid, 'link') == 'vless://second');
	remove(sid);
	ok('secrets/remove', !access(path(sid, 'link')));

	for (let d in [ '/etc/shadow-vpn/secrets', '/etc/shadow-vpn/keys', '/etc/shadow-vpn' ])
		rmdir(d);
}
else {
	print('ok secrets/live round trip # skipped: /etc/shadow-vpn already exists\n');
}

done();
