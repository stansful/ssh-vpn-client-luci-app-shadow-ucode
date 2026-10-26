'use strict';

// Ports of the desktop validators (src/shared/validation.ts, src/main/app/ipc-validation.ts) with the
// same English messages, plus the router-only device, MAC and port checks. Every function returns
// { value, ... } or { error }.

// Regex literals are compiled on every evaluation, so the ones used per item live here. Labels are
// matched without {0,61} (costly to compile and run) and their 63-character limit checked apart.
const DOMAIN_LABEL = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/;
const DNS_LABEL = /^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?$/;
const OCTET = /^[0-9]{1,3}$/;
const DIGITS = /^[0-9]+$/;
const HEX_GROUP = /^[0-9a-fA-F]{1,4}$/;
const SSH_SHA256_FINGERPRINT = /^SHA256:[A-Za-z0-9+\/]{43}$/;
const MAC = /^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$/;

export const CHECK_ENDPOINT_FORMAT_MESSAGE = 'Enter host:port without https:// or a path — for example youtube.com:443.';

export const MAX_NAME_LENGTH = 256;
const MAX_HOST_LENGTH = 255;
// The router keeps names and notes shorter than the desktop (UCI is parsed whole on every read): what a
// form saves is what config.load() accepts, in code points (DESIGN §5)
export const ROUTER_NAME_LENGTH = 64, ROUTER_NOTE_LENGTH = 500;
const MIN_KEEPALIVE_SEC = 5;
const MAX_KEEPALIVE_SEC = 3600;

function text(v) {
	return (v == null) ? '' : `${v}`;
}

// Length in code points, so a limit means the same for Cyrillic as on the desktop.
export function cplen(s) {
	let n = 0;

	for (let i = 0; i < length(s); i++)
		if ((ord(s, i) & 0xc0) != 0x80)
			n++;

	return n;
};

export function is_ipv4(v) {
	let octets = split(text(v), '.');

	if (length(octets) != 4)
		return false;

	for (let o in octets)
		if (!match(o, OCTET) || (length(o) > 1 && substr(o, 0, 1) == '0') || +o > 255)
			return false;

	return true;
};

// Groups of a valid IPv6 literal (no dotted tail, no zone), or null.
function ipv6_groups(v) {
	if (v == '' || index(v, ':::') >= 0)
		return null;

	let parts = split(v, '::');

	if (length(parts) > 2)
		return null;

	let left = (parts[0] != '') ? split(parts[0], ':') : [];
	let right = (length(parts) == 2 && parts[1] != '') ? split(parts[1], ':') : [];

	for (let g in [ ...left, ...right ])
		if (!match(g, HEX_GROUP))
			return null;

	let missing = 8 - length(left) - length(right);

	if (length(parts) == 2 ? missing < 1 : missing != 0)
		return null;

	let groups = [];

	for (let g in left) push(groups, hex(g));
	for (let i = 0; i < missing; i++) push(groups, 0);
	for (let g in right) push(groups, hex(g));

	return groups;
}

export function is_ipv6(v) {
	return ipv6_groups(text(v)) != null;
};

function format_ipv6(groups) {
	let best = -1, best_len = 0;

	for (let i = 0; i < 8;) {
		if (groups[i] != 0) {
			i++;
			continue;
		}

		let end = i + 1;

		while (end < 8 && groups[end] == 0)
			end++;

		if (end - i > best_len && end - i >= 2) {
			best = i;
			best_len = end - i;
		}

		i = end;
	}

	let hexes = map(groups, (g) => sprintf('%x', g));

	if (best < 0)
		return join(':', hexes);

	return join(':', slice(hexes, 0, best)) + '::' + join(':', slice(hexes, best + best_len));
}

// Network address of addr/prefix with the host bits cleared, as nft and the desktop store it.
function network(family, addr, prefix) {
	if (family == 4) {
		let o = map(split(addr, '.'), (x) => +x);

		for (let i = 0; i < 4; i++) {
			let bits = prefix - i * 8;
			o[i] &= (bits >= 8) ? 0xff : (bits <= 0) ? 0 : (0xff << (8 - bits)) & 0xff;
		}

		return join('.', o);
	}

	let g = ipv6_groups(addr);

	for (let i = 0; i < 8; i++) {
		let bits = prefix - i * 16;
		g[i] &= (bits >= 16) ? 0xffff : (bits <= 0) ? 0 : (0xffff << (16 - bits)) & 0xffff;
	}

	return format_ipv6(g);
}

// An IP address (no prefix) in canonical form: { family, addr } or null.
export function ip_address(v) {
	let s = lc(trim(text(v)));

	if (is_ipv4(s))
		return { family: 4, addr: network(4, s, 32) };

	if (is_ipv6(s))
		return { family: 6, addr: network(6, s, 128) };

	return null;
};

export function domain_rule(v) {
	let pattern = lc(trim(text(v)));

	if (pattern == '')
		return { error: 'Domain pattern is required.' };

	let wildcard = substr(pattern, 0, 2) == '*.';
	let normalized = wildcard ? substr(pattern, 2) : pattern;

	if (cplen(normalized) > 253)
		return { error: 'Domain pattern is too long.' };

	let labels = split(normalized, '.');

	if (length(labels) < 2)
		return { error: 'Domain pattern must include at least two labels.' };

	for (let label in labels)
		if (length(label) > 63 || !match(label, DOMAIN_LABEL))
			return { error: 'Domain labels may contain letters, numbers, and internal hyphens.' };

	// The router matches *.x as x (apex included): dnsmasq has no subdomains-only form.
	return { value: normalized, wildcard };
};

export function ip_rule(v) {
	let input = trim(text(v));

	if (input == '')
		return { error: 'IP address or CIDR is required.' };

	let parts = split(input, '/');

	if (length(parts) > 2)
		return { error: 'CIDR may contain only one slash.' };

	let family = is_ipv4(parts[0]) ? 4 : is_ipv6(parts[0]) ? 6 : 0;

	if (!family)
		return { error: 'IP address must be valid IPv4 or IPv6.' };

	let max = (family == 4) ? 32 : 128, prefix = max;

	if (length(parts) == 2) {
		let raw = parts[1];

		if (!match(raw, DIGITS))
			return { error: 'CIDR prefix must be a number.' };

		if (length(raw) > 1 && substr(raw, 0, 1) == '0')
			return { error: 'CIDR prefix must not have leading zeros.' };

		prefix = (length(raw) > 3) ? max + 1 : +raw;

		if (prefix > max)
			return { error: `CIDR prefix must be between 0 and ${max}.` };
	}

	let addr = network(family, lc(parts[0]), prefix);

	return { value: input, family, cidr: (prefix == max) ? addr : `${addr}/${prefix}` };
};

// desktop canonicalIpRuleValue: an earlier version's zero-padded prefix ("/08") read as "/8".
export function canonical_ip_rule(v) {
	let m = match(trim(text(v)), /^(.*)\/(0[0-9]+)$/);

	return m ? `${m[1]}/${+m[2]}` : text(v);
};

export function mac(v) {
	let s = lc(trim(text(v)));

	if (!match(s, MAC))
		return null;

	s = replace(s, /-/g, ':');

	// A group address (multicast or broadcast) or all zeros never names one LAN device.
	if (s == '00:00:00:00:00:00' || (hex(substr(s, 0, 2)) & 1))
		return null;

	return s;
};

export function device_rule(v) {
	let input = trim(text(v));

	if (input == '')
		return { error: 'MAC address, IP address or CIDR is required.' };

	let m = mac(input);

	if (m)
		return { value: m, kind: 'mac' };

	let ip = ip_rule(input);

	if (ip.error)
		return (index(input, '/') >= 0 && !match(ip.error, /^IP address/)) ? ip
			: { error: 'Enter a MAC address (aa:bb:cc:dd:ee:ff), an IP address or a CIDR.' };

	return { value: ip.cidr, kind: (ip.family == 4) ? 'ip4' : 'ip6' };
};

// Approximates \p{L}\p{N}_ of the desktop's Unicode label regex: ASCII letters, digits and '_', and
// any non-ASCII code point outside the punctuation, symbol and space blocks.
const NOT_WORD = [
	[ 0x80, 0xa9 ], [ 0xab, 0xb1 ], [ 0xb4, 0xb4 ], [ 0xb6, 0xb8 ], [ 0xbb, 0xbb ], [ 0xbf, 0xbf ],
	[ 0xd7, 0xd7 ], [ 0xf7, 0xf7 ], [ 0x2000, 0x206f ], [ 0x20a0, 0x20cf ], [ 0x2190, 0x23ff ],
	[ 0x2500, 0x27bf ], [ 0x2900, 0x2bff ], [ 0x3000, 0x3004 ], [ 0x3008, 0x301f ], [ 0xd800, 0xdfff ],
	[ 0xfe30, 0xfe4f ], [ 0xff00, 0xff0f ], [ 0xff1a, 0xff20 ], [ 0xff3b, 0xff40 ], [ 0xff5b, 0xff65 ],
	[ 0xfff0, 0xffff ], [ 0x1f000, 0x1faff ]
];

// Code points of a UTF-8 string, or null when it is not valid UTF-8.
function codepoints(s) {
	let out = [];

	for (let i = 0; i < length(s);) {
		let b = ord(s, i), n = (b < 0x80) ? 0 : (b >= 0xf0) ? 3 : (b >= 0xe0) ? 2 : (b >= 0xc2) ? 1 : -1;

		if (n < 0 || i + n >= length(s))
			return null;

		let cp = (n == 0) ? b : b & (0x3f >> n);

		for (let k = 1; k <= n; k++) {
			let c = ord(s, i + k);

			if (c == null || (c & 0xc0) != 0x80)
				return null;

			cp = (cp << 6) | (c & 0x3f);
		}

		push(out, cp);
		i += n + 1;
	}

	return out;
}

function is_word(cp) {
	if (cp < 0x80)
		return (cp >= 0x30 && cp <= 0x39) || (cp >= 0x41 && cp <= 0x5a) || (cp >= 0x61 && cp <= 0x7a) || cp == 0x5f;

	for (let r in NOT_WORD)
		if (cp >= r[0] && cp <= r[1])
			return false;

	return true;
}

function endpoint_label(label) {
	let cps = codepoints(label);

	if (!cps || length(cps) < 1 || length(cps) > 63)
		return false;

	for (let i = 0; i < length(cps); i++) {
		let edge = (i == 0 || i == length(cps) - 1);

		if (!is_word(cps[i]) && (edge || cps[i] != 0x2d))
			return false;
	}

	return true;
}

function endpoint_host(host) {
	if (is_ipv4(host))
		return true;

	let name = (substr(host, -1) == '.') ? substr(host, 0, -1) : host;

	if (name == '' || cplen(name) > 253 || match(name, /^[0-9.]+$/))
		return false;

	for (let label in split(name, '.'))
		if (!endpoint_label(label))
			return false;

	return true;
}

// desktop validateCheckEndpoint
export function endpoint(v) {
	let ep = trim(text(v));

	if (ep == '')
		return { error: 'Endpoint is required. Use host:port.' };

	if (match(ep, /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//) || match(ep, /[\/?#@\\]/))
		return { error: CHECK_ENDPOINT_FORMAT_MESSAGE };

	let host, port, bracketed = match(ep, /^\[([^]]+)\](:(.*))?$/);

	if (bracketed) {
		host = bracketed[1];
		port = bracketed[3];

		if (!is_ipv6(host))
			host = null;
	}
	else {
		let plain = match(ep, /^([^:]+)(:(.*))?$/);

		host = plain?.[1];
		port = plain?.[3];

		if (host != null && !endpoint_host(host))
			host = null;
	}

	if (host == null)
		return { error: 'Endpoint must use host:port, for example youtube.com:443.' };

	if (port == null || !match(port, /^[0-9]{1,5}$/) || +port < 1 || +port > 65535)
		return { error: 'Endpoint must use host:port with a valid TCP port.' };

	return { value: ep, host, port: +port };
};

// desktop validateSshServerFingerprint: empty means trust on first use.
export function fingerprint(v) {
	let fp = trim(text(v));

	if (fp != '' && !match(fp, SSH_SHA256_FINGERPRINT))
		return { error: 'SSH server fingerprint must use the OpenSSH SHA256:base64 format (43 characters after SHA256:).' };

	return { value: fp };
};

function whole_number(v) {
	if (type(v) == 'int')
		return v;

	let s = trim(text(v));

	return match(s, /^[0-9]{1,9}$/) ? +s : null;
}

// The router allows 5..3600 s (DESIGN §5): a dead link is noticed sooner than with the desktop's 60.
export function keepalive(v) {
	let n = whole_number(v);

	if (n == null || n < MIN_KEEPALIVE_SEC || n > MAX_KEEPALIVE_SEC)
		return { error: `Keepalive must be a whole number of seconds from ${MIN_KEEPALIVE_SEC} to ${MAX_KEEPALIVE_SEC}.` };

	return { value: n };
};

export function port(v) {
	let n = whole_number(v);

	if (n == null || n < 1 || n > 65535)
		return { error: 'Enter a port from 1 to 65535.' };

	return { value: n };
};

function required_text(v, label, max) {
	let s = text(v);

	if (cplen(s) > max)
		return { error: `${label} is too long.` };

	s = trim(s);

	if (s == '')
		return { error: `${label} is required.` };

	return { value: s };
}

export function name(v, max) {
	return required_text(v, 'Name', max ?? MAX_NAME_LENGTH);
};

export function host(v) {
	let r = required_text(v, 'Host', MAX_HOST_LENGTH);

	if (r.value != null && match(r.value, /[ \t\r\n\f\v\/\\?#@]/))
		return { error: 'Enter only the server address in Host.' };

	return r;
};

export function username(v) {
	let r = required_text(v, 'Username', MAX_NAME_LENGTH);

	if (r.value != null && match(r.value, /[ \t\r\n\f\v@]/))
		return { error: 'Enter only the user name in Username.' };

	return r;
};

// What a saved server may use: OpenSSH 10 refuses these in the remote user name (readconf.c
// ssh_valid_ruser) before it writes its log, and expands '%'. A server saved before this check keeps
// loading (username above), and its connect stops with "SSH server settings are invalid."
export const USERNAME_REFUSED_MESSAGE = 'Username cannot start with - or contain any of these characters: \' ` " ; & < > | ( ) { } $ \\ %';
const SSH_USER_REFUSED = "'`\";&<>|(){}$\\%";

export function ssh_username(v) {
	let r = username(v);

	if (r.error)
		return r;

	let bad = substr(r.value, 0, 1) == '-';

	for (let i = 0; i < length(SSH_USER_REFUSED) && !bad; i++)
		bad = index(r.value, substr(SSH_USER_REFUSED, i, 1)) >= 0;

	return bad ? { error: USERNAME_REFUSED_MESSAGE } : r;
};


// The SSH server form (desktop parseUpsertSshConfigInput). `key` is a key section id or empty: sign-in
// details may follow later; whether the key exists is checked by the caller, which owns the keys.
export function server(fields) {
	let f = fields ?? {}, values = {}, errors = {};
	let checks = {
		name: () => name(f.name, ROUTER_NAME_LENGTH),
		host: () => host(f.host),
		port: () => port(f.port ?? 22),
		username: () => ssh_username(f.username),
		fingerprint: () => fingerprint(f.fingerprint),
		keepalive: () => keepalive(f.keepalive ?? 15)
	};

	for (let field, check in checks) {
		let r = check();

		if (r.error)
			errors[field] = r.error;
		else
			values[field] = r.value;
	}

	let auth = f.auth ?? 'password';

	if (auth != 'password' && auth != 'key')
		errors.auth = 'Sign-in method must be one of: password, key.';
	else
		values.auth = auth;

	let key = trim(text(f.key));

	if (key != '' && !match(key, /^k_[0-9a-f]{12}$/))
		errors.key = 'The selected SSH key no longer exists. Pick another key.';
	else
		values.key = (auth == 'key' && key != '') ? key : null;

	let note = text(f.note);

	if (cplen(note) > ROUTER_NOTE_LENGTH)
		errors.note = 'Note is too long.';
	else
		values.note = trim(note);

	return length(keys(errors)) ? { errors } : { values };
};

// A name dnsmasq may carry in server=/name/ or nftset=/name/: lowercase labels of letters, digits, '-'
// and '_' (service names). Returns the normalized name or null.
export function dns_name(v) {
	let s = lc(trim(text(v)));

	if (substr(s, -1) == '.')
		s = substr(s, 0, -1);

	if (s == '' || length(s) > 253 || is_ipv4(s))
		return null;

	for (let label in split(s, '.'))
		if (length(label) > 63 || !match(label, DNS_LABEL))
			return null;

	return s;
};

export function ifname(v) {
	let s = text(v);

	return match(s, /^[A-Za-z0-9._-]{1,15}$/) ? s : null;
};
