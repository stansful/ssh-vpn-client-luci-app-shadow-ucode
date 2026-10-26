'use strict';
'require view';
'require form';
'require shadow-vpn.common as common';

const el = common.el;
const INSTALL = 'sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh)';

function flag(s, name, title, description, dflt) {
	const o = s.option(form.Flag, name, title, description);

	o.default = dflt;
	o.rmempty = false;

	return o;
}

return view.extend({
	load() {
		return L.resolveDefault(common.api.status(), {});
	},

	render(st) {
		const m = new form.Map('shadow-vpn');
		let s, o;

		s = m.section(form.NamedSection, 'main', 'shadow', _('When the tunnel is down'));

		o = s.option(form.ListValue, 'kill_switch', _('If the connection to the server is lost'));
		o.value('1', _('Block tunnelled traffic (kill switch)'));
		o.value('0', _('Let it go directly'));
		o.default = '1';
		o.description = _('A dead tunnel is noticed in about 10 seconds. “Block”: sites that go through the tunnel do not open until it is back. “Directly”: they open without the tunnel until it is back.');

		flag(s, 'autostart', _('Turn on when the router boots'),
			_('If Shadow was on, it turns on again after a reboot or a power cut.'), '1');

		s = m.section(form.NamedSection, 'main', 'shadow', _('Traffic'));

		o = s.option(form.ListValue, 'ssh_udp', _('UDP with the SSH tunnel'));
		o.value('reject', _('Reject: QUIC falls back to TCP at once'));
		o.value('direct', _('Let it go directly: only in “All traffic” mode'));
		o.default = 'reject';
		o.description = _('SSH carries only TCP. Calls and games over UDP do not work through the SSH tunnel; Xray carries UDP.');

		flag(s, 'tunnel_dns', _('DNS through the tunnel'),
			_('Addresses of tunnelled sites are resolved through the server (DoH), so the provider neither sees the requests nor alters the answers.'), '1');
		flag(s, 'ipv6', _('IPv6 through the tunnel'),
			_('Off: for tunnelled sites the router returns only IPv4 addresses, so IPv6 does not go around the tunnel.'), '0');
		flag(s, 'dns_redirect', _('Redirect LAN DNS to the router'),
			_('DNS requests from the network go to the router even if a device has its own DNS server, so the lists see every name. LAN servers the router itself uses for DNS (Pi-hole, AdGuard Home) are left alone. Turn it off if you run your own resolver.'), '1');
		flag(s, 'router_traffic', _('Traffic of the router itself'),
			_('The router’s own connections (list updates, packages) to tunnelled sites also go through the tunnel.'), '1');

		s = m.section(form.NamedSection, 'main', 'shadow', _('Logs'));

		o = s.option(form.ListValue, 'log_level', _('Detail'));
		o.value('info', _('Detailed'));
		o.value('warning', _('Warnings and errors'));
		o.value('error', _('Errors only'));
		o.default = 'warning';

		const v = (st && st.versions) || {};

		return m.render().then(node => common.page(_('Settings'), null, [
			node,
			common.section(_('About'), null, [
				el('dl', { class: 'shv-kv' }, [
					el('dt', {}, [ 'Shadow' ]), el('dd', {}, [ common.versionText(v.shadow) ]),
					el('dt', {}, [ 'Xray' ]), el('dd', {}, [ v.xray ? _('%s (from the OpenWrt feed)').format(common.versionText(v.xray)) : '—' ]),
					el('dt', {}, [ 'OpenSSH' ]), el('dd', {}, [ common.versionText(v.openssh) ]),
					el('dt', {}, [ _('Update') ]), el('dd', {}, [ el('span', { class: 'shv-mono' }, [ INSTALL ]) ])
				])
			])
		]));
	}
});
