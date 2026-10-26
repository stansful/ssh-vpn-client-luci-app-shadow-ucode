'use strict';

// Test stand-in for shadow-vpn.secrets (CONTRACTS §4).
import { readfile, open, unlink, mkdir, rename } from 'fs';
import { ETC, SID_RE } from 'shadow-vpn.const';

function valid_sid(sid) {
	return type(sid) == 'string' && !!match(sid, SID_RE);
}

function path(sid, kind) {
	if (!valid_sid(sid))
		return null;

	if (kind == 'key')
		return `${ETC}/keys/${sid}`;

	return (kind in [ 'password', 'passphrase', 'link' ]) ? `${ETC}/secrets/${sid}.${kind}` : null;
}

function read(sid, kind) {
	const p = path(sid, kind);

	return p ? readfile(p) : null;
}

function write(sid, kind, text) {
	const p = path(sid, kind);

	if (!p)
		return false;

	mkdir(ETC, 0o700);
	mkdir(ETC + '/secrets', 0o700);
	mkdir(ETC + '/keys', 0o700);

	const f = open(p + '.tmp', 'w', 0o600);

	if (!f)
		return false;

	f.write(text);
	f.close();

	return !!rename(p + '.tmp', p);
}

function remove(sid) {
	for (let kind in [ 'password', 'passphrase', 'link', 'key' ]) {
		const p = path(sid, kind);

		if (p)
			unlink(p);
	}
}

function sync() {
}

// The real one is a keyed HMAC (secrets.uc); a stand-in that never equals the plain links.uc value.
function profile_identity(fp) {
	if (type(fp) != 'string' || fp == '')
		return null;

	return (substr(fp, 0, 5) == 'hmac:') ? fp : 'hmac:' + replace(fp, /^sha256:/, '');
}

export { valid_sid, path, read, write, remove, sync, profile_identity };
