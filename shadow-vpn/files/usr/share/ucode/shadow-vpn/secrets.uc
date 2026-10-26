'use strict';

import { open, rename, unlink, mkdir, chmod, readfile } from 'fs';
import { ETC, SID_RE, LIMITS } from 'shadow-vpn.const';

// Only servers, keys and profiles own files; rule ids never reach a path.
const PATH_SID = /^[skp]_[0-9a-f]{12}$/;
const KINDS = { password: 'secrets', passphrase: 'secrets', link: 'secrets', key: 'keys' };
const MAX_BYTES = { password: 1024, passphrase: 1024, link: LIMITS.link_chars, key: 65536 };

function valid_sid(sid) {
	return type(sid) == 'string' && match(sid, SID_RE) != null;
}

function path(sid, kind) {
	if (!valid_sid(sid) || !match(sid, PATH_SID) || type(kind) != 'string' || KINDS[kind] == null)
		return null;

	return (kind == 'key') ? `${ETC}/keys/${sid}` : `${ETC}/secrets/${sid}.${kind}`;
}

function read(sid, kind) {
	let p = path(sid, kind);

	return p ? readfile(p) : null;
}

function ensure_dir(dir) {
	mkdir(dir, 0o700);

	return chmod(dir, 0o700) == true;
}

// fs has no fsync; busybox ships the applet (as lists.uc uses it). The overlay is UBIFS: without it a
// power cut shortly after a save can leave the renamed file empty, and with it a committed server that
// points at an empty password, key or link.
function fsync(path) {
	system([ 'fsync', path ]);
}

// One `sync` for a batch of writes made with { sync: false } (an import of many links).
function sync() {
	system([ 'sync' ]);
}

// Written as tmp + fsync + rename with mode 0600 from the first byte, so a reader never sees a partial or
// world-readable secret. opts.sync false leaves the flush to sync().
function write(sid, kind, text, opts) {
	let p = path(sid, kind);

	if (!p || type(text) != 'string' || length(text) > MAX_BYTES[kind] || index(text, '\0') >= 0)
		return false;

	if (!ensure_dir(ETC) || !ensure_dir(`${ETC}/${KINDS[kind]}`))
		return false;

	let tmp = `${p}.tmp`;

	unlink(tmp);

	let f = open(tmp, 'wx', 0o600);

	if (!f)
		return false;

	let ok = f.write(text) == length(text);
	let flush = opts?.sync !== false;

	f.close();

	if (ok && flush)
		fsync(tmp);

	if (!ok || !rename(tmp, p)) {
		unlink(tmp);
		return false;
	}

	if (flush)
		fsync(`${ETC}/${KINDS[kind]}`);

	return true;
}

// Every file of that sid, including the trusted host key of a server.
function remove(sid) {
	for (let kind in KINDS) {
		let p = path(sid, kind);

		if (p)
			unlink(p);
	}

	if (valid_sid(sid) && match(sid, /^s_/))
		unlink(`${ETC}/trusted.${sid}`);
}

/* The dedupe identity of an Xray profile in UCI (CONTRACTS §3). links.uc's fingerprint is an unsalted
 * SHA-256 over the link's fields, the Trojan or Hysteria 2 password included, and UCI is readable by
 * read-only LuCI users and ends up in pasted `uci show` output. UCI gets an HMAC-SHA256 of it under a
 * random key of this router (ETC/fingerprint.key, 0600) instead. */
const FP_KEY = `${ETC}/fingerprint.key`, HEX64 = /^[0-9a-f]{64}$/;
let fp_key = null;

function read_key() {
	let k = trim(readfile(FP_KEY) ?? '');

	return match(k, HEX64) ? hexdec(k) : null;
}

function fingerprint_key() {
	if (fp_key)
		return fp_key;

	fp_key = read_key();

	if (fp_key || !ensure_dir(ETC))
		return fp_key;

	// O_EXCL: of two first users at once one creates the key, the other waits for it and reads it
	let f = open(FP_KEY, 'wx', 0o600);

	if (f) {
		let k = hexenc(readfile('/dev/urandom', 32) ?? '');

		if (match(k, HEX64))
			f.write(k + '\n');

		f.close();
		fsync(FP_KEY);
	}

	for (let i = 0; i < 20 && !(fp_key = read_key()); i++)
		sleep(50);

	return fp_key;
}

function hmac_sha256(key, msg) {
	let digest = require('digest');
	let k = (length(key) > 64) ? hexdec(digest.sha256(key)) : key, ipad = '', opad = '';

	for (let i = 0; i < 64; i++) {
		let b = (i < length(k)) ? ord(k, i) : 0;

		ipad += chr(b ^ 0x36);
		opad += chr(b ^ 0x5c);
	}

	return digest.sha256(opad + hexdec(digest.sha256(ipad + msg)));
}

// 'hmac:<hex>' for a links.uc fingerprint ('sha256:<hex>'); a value that already is one stays as it is.
function profile_identity(fp) {
	if (type(fp) != 'string' || fp == '')
		return null;

	if (substr(fp, 0, 5) == 'hmac:')
		return fp;

	let key = fingerprint_key();

	return key ? 'hmac:' + hmac_sha256(key, fp) : null;
}

export { valid_sid, path, read, write, remove, sync, profile_identity };
