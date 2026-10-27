'use strict';

// Test stand-in for shadow-vpn.config (CONTRACTS §3): enough normalisation for the rpcd plugin tests.
import { cursor } from 'uci';
import { UCI } from 'shadow-vpn.const';

function flag(v, dflt) {
	return (v == null) ? dflt : (v == '1');
}

function sid_ok(sid, prefix) {
	return type(sid) == 'string' && !!match(sid, regexp(`^${prefix}_[0-9a-f]{12}$`));
}

function load(ctx) {
	ctx ??= cursor();

	const m = ctx.get_all(UCI, 'main') ?? {};
	const model = {
		main: {
			enabled: flag(m.enabled, false), autostart: flag(m.autostart, true), kill_switch: flag(m.kill_switch, true),
			check_after_connect: flag(m.check_after_connect, true), tunnel_dns: flag(m.tunnel_dns, true),
			ipv6: flag(m.ipv6, false), dns_redirect: flag(m.dns_redirect, true), router_traffic: flag(m.router_traffic, true),
			transport: (m.transport == 'xray') ? 'xray' : 'ssh',
			ssh_server: sid_ok(m.ssh_server, 's') ? m.ssh_server : null,
			xray_profile: sid_ok(m.xray_profile, 'p') ? m.xray_profile : null,
			mode: (m.mode == 'selected-rules') ? 'selected-rules' : 'proxy-all',
			check_endpoint: m.check_endpoint ?? 'youtube.com:443',
			ssh_udp: (m.ssh_udp == 'direct') ? 'direct' : 'reject',
			lists_refresh: int(m.lists_refresh ?? 24), log_level: m.log_level ?? 'warning',
			update: (m.update in [ 'manual', 'notify', 'auto' ]) ? m.update : 'notify'
		},
		lists: {
			proxy: { enabled: flag(ctx.get(UCI, 'proxy', 'enabled'), false) },
			direct: { enabled: flag(ctx.get(UCI, 'direct', 'enabled'), false) }
		},
		servers: [], keys: [], profiles: [], rules: [], errors: []
	};

	ctx.foreach(UCI, 'ssh_server', s => {
		if (!sid_ok(s['.name'], 's'))
			return;

		push(model.servers, { sid: s['.name'], name: s.name ?? '', host: s.host ?? '', port: int(s.port ?? 22),
			username: s.username ?? '', auth: (s.auth == 'key') ? 'key' : 'password', key: sid_ok(s.key, 'k') ? s.key : null,
			fingerprint: s.fingerprint ?? '', keepalive: int(s.keepalive ?? 15), note: s.note ?? '' });
	});

	ctx.foreach(UCI, 'ssh_key', s => {
		if (sid_ok(s['.name'], 'k'))
			push(model.keys, { sid: s['.name'], name: s.name ?? '', type: s.type ?? 'ed25519', format: s.format ?? 'openssh',
				encrypted: s.encrypted == '1' });
	});

	ctx.foreach(UCI, 'profile', s => {
		if (sid_ok(s['.name'], 'p'))
			push(model.profiles, { sid: s['.name'], name: s.name ?? '', protocol: s.protocol ?? 'vless', host: s.host ?? '',
				port: int(s.port ?? 443), hop_ports: s.hop_ports ?? '', transport: s.transport ?? 'tcp',
				security: s.security ?? 'none', flow: s.flow ?? '', fingerprint: s.fingerprint ?? '',
				pinned: s.pinned == '1', insecure_without_pin: s.insecure_without_pin == '1',
				supported: s.transport != 'unknown' && s.security != 'unknown',
				created: int(s.created ?? 0), updated: int(s.updated ?? 0) });
	});

	ctx.foreach(UCI, 'rule', s => {
		if (s.type in [ 'domain', 'ip', 'device' ] && s.value)
			push(model.rules, { sid: s['.name'], id: s.id ?? '', type: s.type, value: s.value, enabled: s.enabled != '0' });
	});

	return model;
}

function selected(model) {
	const main = model.main;
	const list = (main.transport == 'ssh') ? model.servers : model.profiles;
	const sid = (main.transport == 'ssh') ? main.ssh_server : main.xray_profile;

	for (let item in list)
		if (item.sid == sid)
			return item;

	return null;
}

function targets(model) {
	if (model.main.mode == 'proxy-all')
		return true;

	for (let r in model.rules)
		if (r.enabled)
			return true;

	return model.lists.proxy.enabled;
}

export { load, selected, targets };
