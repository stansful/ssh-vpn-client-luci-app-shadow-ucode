'use strict';

// Test stand-in for shadow-vpn.validate (CONTRACTS §6) with the desktop messages the tests rely on.
const LABEL = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

function domain_rule(v) {
	let p = lc(trim(v ?? ''));

	if (p == '')
		return { error: 'Domain pattern is required.' };

	const labels = split((substr(p, 0, 2) == '*.') ? substr(p, 2) : p, '.');

	if (length(labels) < 2)
		return { error: 'Domain pattern must include at least two labels.' };

	for (let l in labels)
		if (!match(l, LABEL))
			return { error: 'Domain labels may contain letters, numbers, and internal hyphens.' };

	return { value: p };
}

function ip_rule(v) {
	const p = trim(v ?? '');

	if (p == '')
		return { error: 'IP address or CIDR is required.' };

	if (match(p, /^([0-9]{1,3}\.){3}[0-9]{1,3}(\/([0-9]|[12][0-9]|3[0-2]))?$/))
		return { value: p, family: 4 };

	if (match(p, /^[0-9a-fA-F:]+(\/[0-9]{1,3})?$/) && index(p, ':') >= 0)
		return { value: lc(p), family: 6 };

	return { error: 'IP address must be valid IPv4 or IPv6.' };
}

function device_rule(v) {
	const p = trim(v ?? '');

	if (match(p, /^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/))
		return { value: uc(p), kind: 'mac' };

	const ip = ip_rule(p);

	return ip.error ? { error: 'Enter a MAC address or an IP address.' } : { value: ip.value, kind: (ip.family == 4) ? 'ip4' : 'ip6' };
}

function endpoint(v) {
	const p = trim(v ?? '');

	if (p == '')
		return { error: 'Endpoint is required. Use host:port.' };

	return match(p, /^[a-z0-9.-]+:[0-9]{1,5}$/) ? { value: p } : { error: 'Endpoint must use host:port, for example youtube.com:443.' };
}

function name(v, max) {
	const p = trim(v ?? '');

	if (p == '')
		return { error: 'Name is required.' };

	return (length(p) > (max ?? 256)) ? { error: 'Name is too long.' } : { value: p };
}

function server(f) {
	const errors = {};
	const values = { ...f };

	for (let k in [ 'name', 'host', 'username' ])
		if (trim(f[k] ?? '') == '')
			errors[k] = ((k == 'host') ? 'Host' : (k == 'username') ? 'Username' : 'Name') + ' is required.';

	const port = int(f.port ?? '');

	if (!match(f.port ?? '', /^[0-9]+$/) || port < 1 || port > 65535)
		errors.port = 'Enter a port from 1 to 65535.';

	if ((f.fingerprint ?? '') != '' && !match(f.fingerprint, /^SHA256:[A-Za-z0-9+\/]{43}$/))
		errors.fingerprint = 'SSH server fingerprint must use the OpenSSH SHA256:base64 format (43 characters after SHA256:).';

	values.port = port;
	values.keepalive = int(f.keepalive || 15);

	return length(errors) ? { errors } : { values };
}

function host(v) {
	const p = trim(`${v ?? ''}`);

	if (p == '')
		return { error: 'Host is required.' };

	return (length(p) > 255) ? { error: 'Host is too long.' } : { value: p };
}

function port(v) {
	const n = int(v ?? 0);

	return (n >= 1 && n <= 65535) ? { value: n } : { error: 'Enter a port from 1 to 65535.' };
}

const ROUTER_NAME_LENGTH = 64, ROUTER_NOTE_LENGTH = 500;

export { domain_rule, ip_rule, device_rule, endpoint, name, server, host, port, ROUTER_NAME_LENGTH, ROUTER_NOTE_LENGTH };
