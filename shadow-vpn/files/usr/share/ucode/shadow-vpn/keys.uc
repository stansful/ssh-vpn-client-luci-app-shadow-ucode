'use strict';

// Private key text as the desktop accepts it (src/core/ssh/private-key.ts), plus what the router
// needs to know before OpenSSH reads the file: the key type, its format and whether it is
// encrypted. OpenSSH 10 loads every accepted format itself, so nothing is decrypted here.

const MSG = {
	empty: 'SSH private key is empty.',
	public: 'SSH private key field contains a public key. Paste the private key contents instead.',
	header: 'SSH private key must start with a PRIVATE KEY PEM/OpenSSH header. Paste the key contents, not a file path.',
	truncated: 'The key looks cut off — its -----END … PRIVATE KEY----- line is missing. Copy the whole file again.',
	unreadable: 'Unable to load SSH private key. Check the key format and passphrase.',
	dsa: 'DSA keys can’t sign in. Use an Ed25519, ECDSA or RSA key.',
	security_key: 'Unable to load SSH private key because it is a security-key (FIDO) key, which signs only with its hardware key. Use an Ed25519, ECDSA or RSA key.'
};

const BEGIN_RE = /^-----BEGIN ((OPENSSH |RSA |DSA |EC |ENCRYPTED )?PRIVATE KEY)-----$/s;
const PUBLIC_RE = /^(ssh-(rsa|ed25519)|ecdsa-sha2-)/i;
const PEM_ENCRYPTED_RE = /^Proc-Type:[ \t]*4,ENCRYPTED/is;
const OPENSSH_MAGIC = 'openssh-key-v1\0';

// DER-encoded algorithm OIDs of a PKCS#8 AlgorithmIdentifier.
const PKCS8_OIDS = [
	[ 'rsa', chr(0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01) ],
	[ 'rsa', chr(0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0a) ],
	[ 'ed25519', chr(0x06, 0x03, 0x2b, 0x65, 0x70) ],
	[ 'ecdsa', chr(0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01) ],
	[ 'dsa', chr(0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x38, 0x04, 0x01) ]
];

// Same normalisation as the desktop: BOM, surrounding whitespace, a key pasted on one line from
// JSON (literal \n), CRLF and CR line ends.
function normalize_text(text) {
	let t = text;

	if (substr(t, 0, 3) == '\xef\xbb\xbf')
		t = substr(t, 3);

	t = trim(t);

	if (index(t, '\n') < 0 && match(t, /\\[rn]/))
		t = replace(replace(replace(t, '\\r\\n', '\n'), '\\n', '\n'), '\\r', '\n');

	return replace(replace(t, '\r\n', '\n'), '\r', '\n');
}

function base64_body(block) {
	let body = '';

	for (let line in split(block, '\n'))
		if (substr(line, 0, 5) != '-----' && index(line, ':') < 0)
			body += line;

	body = replace(body, /[ \t]/g, '');

	return match(body, /^[A-Za-z0-9+\/]+=*$/) ? b64dec(body) : null;
}

function reader(bytes) {
	return { bytes, pos: 0 };
}

function read_u32(r) {
	if (r.pos + 4 > length(r.bytes))
		die('short key data');

	let b = r.bytes, p = r.pos;

	r.pos += 4;

	return (ord(b, p) << 24) | (ord(b, p + 1) << 16) | (ord(b, p + 2) << 8) | ord(b, p + 3);
}

function read_string(r) {
	let n = read_u32(r);

	if (r.pos + n > length(r.bytes))
		die('short key data');

	let s = substr(r.bytes, r.pos, n);

	r.pos += n;

	return s;
}

function algorithm_type(alg) {
	if (alg == 'ssh-ed25519' || alg == 'sk-ssh-ed25519@openssh.com')
		return 'ed25519';

	if (alg == 'ssh-rsa')
		return 'rsa';

	if (match(alg, /^(sk-)?ecdsa-sha2-/))
		return 'ecdsa';

	if (alg == 'ssh-dss')
		return 'dsa';

	return 'unknown';
}

// The key type sits in the readable public part of the envelope, even for an encrypted key.
function openssh_info(block) {
	let bytes = base64_body(block);

	if (!bytes || substr(bytes, 0, length(OPENSSH_MAGIC)) != OPENSSH_MAGIC)
		return null;

	try {
		let r = reader(bytes);

		r.pos = length(OPENSSH_MAGIC);

		let cipher = read_string(r), kdf = read_string(r);

		read_string(r);

		let count = read_u32(r), encrypted = (cipher != 'none' || kdf != 'none'), alg = null;

		if (count > 0) {
			alg = read_string(reader(read_string(r)));
		}
		else if (!encrypted) {
			// The public section is optional in practice; an unencrypted private block names the
			// type right after its two check integers.
			let priv = reader(read_string(r));

			read_u32(priv);
			read_u32(priv);
			alg = read_string(priv);
		}

		return { type: algorithm_type(alg), encrypted, security_key: substr(alg ?? '', 0, 3) == 'sk-' };
	}
	catch (e) {
		return null;
	}
}

function pkcs8_type(block) {
	let bytes = base64_body(block);

	if (!bytes)
		return 'unknown';

	let head = substr(bytes, 0, 64);

	for (let oid in PKCS8_OIDS)
		if (index(head, oid[1]) >= 0)
			return oid[0];

	return 'unknown';
}

function describe(label, block) {
	switch (label) {
	case 'OPENSSH PRIVATE KEY': {
		let info = openssh_info(block);

		return info ? { format: 'openssh', ...info } : null;
	}

	case 'RSA PRIVATE KEY':
		return { format: 'pem', type: 'rsa', encrypted: !!match(block, PEM_ENCRYPTED_RE), security_key: false };

	case 'EC PRIVATE KEY':
		return { format: 'pem', type: 'ecdsa', encrypted: !!match(block, PEM_ENCRYPTED_RE), security_key: false };

	case 'DSA PRIVATE KEY':
		return { format: 'pem', type: 'dsa', encrypted: !!match(block, PEM_ENCRYPTED_RE), security_key: false };

	case 'ENCRYPTED PRIVATE KEY':
		// The algorithm sits inside the encrypted part.
		return { format: 'pkcs8', type: 'unknown', encrypted: true, security_key: false };

	default: {
		let t = pkcs8_type(block);

		return (t != 'unknown') ? { format: 'pkcs8', type: t, encrypted: false, security_key: false } : null;
	}
	}
}

// normalize(text) -> { text, type, format, encrypted, security_key } | { error }
// `text` is what gets stored: from the BEGIN line to the END line, LF line ends, one final newline.
// `type` is 'unknown' only for encrypted PKCS#8, whose algorithm is inside the encrypted part.
export function normalize(text) {
	if (type(text) != 'string')
		return { error: MSG.empty };

	let t = normalize_text(text);

	if (!length(t))
		return { error: MSG.empty };

	if (match(t, PUBLIC_RE))
		return { error: MSG.public };

	let header = match(t, BEGIN_RE);

	if (!header)
		return { error: MSG.header };

	// Text before the header is dropped: OpenSSH reads an OpenSSH-format key only from its first byte.
	let rest = substr(t, index(t, header[0]));
	let footer = `-----END ${header[1]}-----`;
	let end = index(rest, footer);

	if (end < 0)
		return { error: MSG.truncated };

	let block = substr(rest, 0, end + length(footer));
	let info = describe(header[1], block);

	if (!info)
		return { error: MSG.unreadable };

	if (info.security_key)
		return { error: MSG.security_key };

	if (info.type == 'dsa')
		return { error: MSG.dsa };

	if (info.type == 'unknown' && info.format != 'pkcs8')
		return { error: MSG.unreadable };

	return { text: block + '\n', type: info.type, format: info.format, encrypted: info.encrypted, security_key: false };
};
