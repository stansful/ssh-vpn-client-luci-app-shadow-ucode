'use strict';

// Test stand-in for shadow-vpn.keys (CONTRACTS §7).
function normalize(text) {
	text = trim(replace(text ?? '', /\r\n?/g, '\n'));

	if (text == '')
		return { error: 'SSH private key is empty.' };

	if (match(text, /^(ssh-(rsa|ed25519)|ecdsa-sha2-)/i))
		return { error: 'SSH private key field contains a public key. Paste the private key contents instead.' };

	const m = match(text, /-----BEGIN (OPENSSH |RSA |DSA |EC |ENCRYPTED )?PRIVATE KEY-----/);

	if (!m)
		return { error: 'SSH private key must start with a PRIVATE KEY PEM/OpenSSH header. Paste the key contents, not a file path.' };

	const kind = trim(m[1] ?? '');
	// like the real module: encrypted PKCS#8 hides its algorithm ('unknown'); 'unknown-alg' fakes a backstop case
	const types = { OPENSSH: 'ed25519', RSA: 'rsa', DSA: 'dsa', EC: 'ecdsa', ENCRYPTED: 'unknown' };

	return { text: text + '\n', type: (index(text, 'unknown-alg') >= 0) ? 'unknown' : (types[kind] ?? 'rsa'), format: (kind == 'OPENSSH') ? 'openssh' : (kind == '' || kind == 'ENCRYPTED') ? 'pkcs8' : 'pem',
		encrypted: kind == 'ENCRYPTED', security_key: index(text, 'sk-ssh') >= 0 };
}

export { normalize };
