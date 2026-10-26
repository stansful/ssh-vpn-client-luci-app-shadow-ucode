'use strict';

// Test stand-in for shadow-vpn.links (CONTRACTS §5): vless:// only, enough for import and dedupe tests.
import { md5 } from 'digest';

function normalize_name(s) {
	return substr(trim(replace(s ?? '', /[[:cntrl:]]/g, ' ')), 0, 64);
}

function parse(link) {
	link = trim(link ?? '');

	const m = match(link, /^vless:\/\/([0-9a-f-]{36})@([a-z0-9.-]+):([0-9]+)\?([^#]*)(#(.*))?$/);

	if (!m)
		return { ok: false, error: (substr(link, 0, 8) == 'vless://') ? 'Invalid VLESS URI.' : 'Only vless://, vmess://, trojan://, and hysteria2:// links are supported.' };

	const q = {};

	for (let kv in split(m[4], '&')) {
		const p = split(kv, '=', 2);
		q[p[0]] = p[1] ?? '';
	}

	const transport = (q.type in [ 'tcp', 'ws', 'grpc', 'xhttp' ]) ? q.type : 'unknown';

	return { ok: true, link, profile: {
		name: normalize_name(m[6] ?? '') || `vless-${m[2]}:${m[3]}`, protocol: 'vless', host: m[2], port: int(m[3]), hop_ports: '',
		transport, security: q.security ?? 'none', flow: q.flow ?? '', insecure_without_pin: false,
		supported: transport != 'unknown', fingerprint: 'sha256:' + md5(link), hosts: [ m[2] ]
	} };
}

function parse_import(text) {
	const results = [];
	let skipped = 0, n = 0;

	for (let line in split(text ?? '', '\n')) {
		n++;
		line = trim(line);

		if (line == '' || substr(line, 0, 1) == '#') {
			skipped++;
			continue;
		}

		const r = parse(line);
		push(results, r.ok ? { line: n, ...r } : { line: n, ok: false, error: `Line ${n}: ${r.error}` });
	}

	return { results, skipped };
}

function outbound(link) {
	return { ok: false, error: 'not implemented in the test stub' };
}

export { normalize_name, parse, parse_import, outbound };
