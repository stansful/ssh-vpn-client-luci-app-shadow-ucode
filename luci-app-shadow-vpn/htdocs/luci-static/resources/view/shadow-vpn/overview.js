'use strict';
'require view';
'require dom';
'require poll';
'require ui';
'require shadow-vpn.common as common';

const el = common.el;

function banner(cls, title, text, actions, id) {
	return el('div', { class: 'alert-message %s shv-banner'.format(cls), 'data-id': id || null }, [
		el('div', {}, [ el('strong', {}, [ title ]), text ? el('p', {}, [ text ]) : null ]),
		el('div', { class: 'shv-row' }, actions)
	]);
}

function pageLink(label, page) {
	return el('a', { class: 'btn cbi-button', href: L.url('admin/services/shadow-vpn/' + page) }, [ label ]);
}

function shortFp(fp) {
	fp = String(fp || '');

	return (fp.length > 22) ? fp.slice(0, 15) + '…' + fp.slice(-5) : fp;
}

/* RFC 1928 reply codes: why the server could not open the check's connection. */
function socksReason(r) {
	switch (r.socks_code) {
	case 1: return _('general server failure');
	case 2: return _('not allowed by the server’s rules');
	case 3: return _('network unreachable');
	case 4: return _('host unreachable');
	case 5: return _('connection refused');
	case 6: return _('timed out');
	case 7: return _('command not supported');
	case 8: return _('address type not supported');
	default: return common.tr(r.detail) || _('connection refused');
	}
}

function attentionTitle(a) {
	switch (a.code) {
	case 'nothing_to_route': return _('Nothing to route through the tunnel');
	case 'ssh_fatal': return _('SSH connection stopped');
	case 'xray_config': return _('Xray rejected the profile');
	case 'port_busy': return _('A port Shadow needs is busy');
	case 'dns_rejected': return _('DNS configuration rejected');
	case 'list_failed': return _('A domain list could not be updated');
	case 'rules_invalid': return _('Some rules were skipped');
	case 'dns_upstream_leak': return _('DNS lookups bypass the tunnel');
	case 'dns_bootstrap': return _('Some DNS servers depend on the tunnel');
	case 'nft_rejected': return _('The firewall rejected Shadow’s rules');
	case 'update_available': return _('Update available');
	case 'update_failed': return _('Automatic update failed');
	default: return _('Attention');
	}
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load() {
		return Promise.all([
			common.api.status(),
			L.resolveDefault(common.api.servers(), { servers: [] }),
			L.resolveDefault(common.api.profiles(), { profiles: [] })
		]);
	},

	render(data) {
		this.st = data[0] || {};
		this.servers = data[1].servers || [];
		this.profiles = data[2].profiles || [];
		this.pending = null;
		this.checking = false;
		this.boxes = { banners: E('div'), hero: E('div'), pick: E('div'), check: E('div'), tiles: E('div') };

		this.update();
		common.pollVisible(poll, () => this.refresh(), 5);

		return common.page(_('Shadow'), _('A tunnel through your own server over SSH or Xray, for every device on the network.'), [
			this.boxes.banners,
			common.section(null, null, [ this.boxes.hero, this.boxes.pick ]),
			common.section(_('Tunnel check'),
				_('Opens a connection through the server and waits for the answer, so you can see that the tunnel really works and is not just connected.'),
				[ this.boxes.check ]),
			common.section(_('Summary'), null, [ this.boxes.tiles ])
		]);
	},

	refresh() {
		return common.api.status().then(st => {
			this.st = st || {};
			this.update();
		}).catch(() => {});
	},

	update() {
		this.paint('banners', this.renderBanners());
		this.paint('hero', this.renderHero());
		this.paint('check', this.renderCheck());
		this.paint('tiles', this.renderTiles());
		this.renderPicker();
	},

	/* Replaces a box only when its markup changed, so a poll never swaps a button under the pointer. */
	paint(name, content) {
		const tmp = E('div', {}, common.nodes([ content ]));

		this.painted = this.painted || {};

		if (this.painted[name] === tmp.innerHTML)
			return;

		this.painted[name] = tmp.innerHTML;
		dom.content(this.boxes[name], Array.from(tmp.childNodes));
	},

	/* Hero: state, target and the main button. */

	via() {
		const t = this.st.target;

		if (!t)
			return '';

		return (t.kind == 'xray')
			? [ 'Xray', t.name, common.protocolName(t.protocol) + ' · ' + t.addr ].join(' · ')
			: [ 'SSH', t.name, t.addr ].join(' · ');
	},

	/* The tunnel is down while the processes run; the reason ssh-run classified stays visible. */
	downInfo() {
		const st = this.st;
		const seen = st.tunnel ? st.tunnel.last_seen_age : null;
		const parts = [
			(st.xray_running === false) ? _('Xray is restarting.')
				: (seen != null) ? _('The server has not answered for %s.').format(common.durationText(seen)) : _('The server does not answer.'),
			st.kill_switch ? _('Tunnelled sites are blocked until the tunnel is back.') : _('Tunnelled sites go directly until the tunnel is back.')
		];

		if (st.phase == 'reconnecting' && st.message)
			parts.push(common.tr(st.message));

		if (st.attempt)
			parts.push(_('Shadow keeps reconnecting (attempt %d).').format(st.attempt));

		return { c: 'warn', pulse: true, title: st.kill_switch ? _('No tunnel') : _('Direct', 'state'), detail: parts.join(' ') };
	},

	heroInfo() {
		const st = this.st;
		const down = st.tunnel && st.tunnel.alive === false;

		if (this.pending == 'on')
			return { c: 'acc', pulse: true, title: _('Connecting…'), detail: this.via() };

		if (this.pending == 'off')
			return { c: 'off', pulse: true, title: _('Turning off…'), detail: '' };

		if (!st.enabled)
			return { c: 'off', title: _('Off', 'state'), detail: _('Traffic goes directly.') };

		switch (st.phase) {
		case 'connecting':
			return { c: 'acc', pulse: true, title: _('Connecting…'), detail: this.via() };

		case 'connected':
			if (down)
				return this.downInfo();

			return { c: 'ok', title: _('Connected', 'state'),
				detail: [ this.via(), (st.age != null) ? common.durationText(st.age) : null ].filter(Boolean).join(' · ') };

		case 'reconnecting':
			if (down)
				return this.downInfo();

			return { c: 'warn', pulse: true, title: _('Reconnecting'), detail: [
				_('The connection to the server was lost %s ago. Attempt %d.').format(common.durationText(st.age || 0), st.attempt || 1),
				common.tr(st.message)
			].filter(Boolean).join(' ') };

		case 'error':
			if (st.hostkey)
				return { c: 'bad', title: _('Server key changed'),
					detail: _('Expected %s, the server showed %s (%s). This may be someone impersonating the server, so Shadow does not connect.')
						.format(shortFp(st.hostkey.expected), shortFp(st.hostkey.got), st.hostkey.type) };

			return { c: 'bad', title: _('Error'),
				detail: [ common.tr(st.message), _('Retries stopped: fix the problem and connect again.') ].filter(Boolean).join(' ') };

		default:
			return { c: 'warn', title: _('Not connected', 'state'),
				detail: common.tr(st.message) || _('Shadow is on but not running. See the messages above.') };
		}
	},

	renderHero() {
		const st = this.st;
		const info = this.heroInfo();
		const actions = [];

		if (!st.enabled) {
			actions.push(common.button(_('Turn on'), 'cbi-button-positive shv-big', () => this.setEnabled(true),
				{ disabled: this.pending ? '' : null }));
		}
		else {
			if (st.phase == 'error' && !this.pending)
				actions.push(common.button(_('Connect again'), 'cbi-button-action shv-big', () => this.setEnabled(true)));

			actions.push(common.button(_('Turn off'), 'cbi-button-negative shv-big', () => this.setEnabled(false),
				{ disabled: this.pending ? '' : null }));
		}

		return el('div', { class: 'shv-hero shv-c-%s'.format(info.c) }, [
			el('div', { class: 'shv-hero-main' }, [
				el('span', { class: 'shv-dot' + (info.pulse ? ' pulse' : '') }),
				el('div', {}, [
					el('div', { class: 'shv-state' }, [ info.title ]),
					el('div', { class: 'shv-detail shv-muted' }, [ info.detail ])
				])
			]),
			el('div', { class: 'shv-hero-actions' }, actions)
		]);
	},

	setEnabled(on) {
		this.pending = on ? 'on' : 'off';
		this.update();

		return common.runJob(common.api.setEnabled(on), 90000)
			.catch(err => common.fail(err))
			.finally(() => {
				this.pending = null;
				return this.refresh();
			});
	},

	/* Transport switch and server/profile picker; rebuilt only when the choice changes. */

	renderPicker() {
		const st = this.st;
		const sel = st.selected || {};
		const t = st.transport || 'ssh';
		const key = [ t, sel.ssh_server, sel.xray_profile, this.servers.length, this.profiles.length ].join('|');

		// Not while the user has the list open: a poll would close it under the pointer.
		const focused = document.activeElement;

		if (key == this.pickKey || (focused && focused.tagName == 'SELECT' && this.boxes.pick.contains(focused)))
			return;

		this.pickKey = key;

		const items = (t == 'ssh')
			? this.servers.map(s => [ s.sid, '%s — %s@%s'.format(s.name, s.username, common.hostPort(s.host, s.port)) ])
			: this.profiles.filter(p => p.supported).map(p => [ p.sid, '%s%s — %s, %s'.format(p.pinned ? '★ ' : '', p.name,
				common.protocolName(p.protocol), common.hostPort(p.host, p.hop_ports || p.port)) ]);

		let picker;

		if (items.length) {
			picker = el('select', { class: 'cbi-input-select', style: 'width:100%', change: ev => this.pick(ev.target.value) },
				items.map(i => el('option', { value: i[0] }, [ i[1] ])));
			picker.value = (t == 'ssh') ? (sel.ssh_server || '') : (sel.xray_profile || '');
		}
		else {
			picker = el('div', { class: 'shv-muted', style: 'flex:1' },
				[ (t == 'ssh') ? _('No SSH servers yet.') : _('No Xray profiles yet.') ]);
		}

		const seg = el('div', { class: 'shv-seg' }, [ 'ssh', 'xray' ].map(x =>
			el('button', { class: (x == t) ? 'on' : '', click: () => this.setTransport(x) }, [ (x == 'ssh') ? 'SSH' : 'Xray' ])));

		dom.content(this.boxes.pick, el('div', { class: 'shv-pick' }, [
			el('div', { class: 'shv-field' }, [ el('label', {}, [ _('Transport') ]), seg ]),
			el('div', { class: 'shv-field' }, [
				el('label', {}, [ (t == 'ssh') ? _('SSH server') : _('Xray profile') ]),
				el('div', { class: 'shv-pickrow' }, [
					picker,
					pageLink(items.length ? _('Edit') : _('Add'), t)
				])
			])
		]));
	},

	setTransport(t) {
		const st = this.st;

		if (t == st.transport)
			return;

		const sel = st.selected || {};
		const sid = ((t == 'ssh') ? sel.ssh_server : sel.xray_profile) || '';

		// the router refuses a switch to a transport with nothing usable selected while Shadow is on
		return common.checked(common.api.select(t, sid)).then(() => {
			if (st.enabled)
				common.notify(_('Switching the transport: connections through the tunnel will reopen.'));

			return this.refresh();
		}).catch(err => common.fail(err));
	},

	pick(sid) {
		const on = this.st.enabled;

		return common.checked(common.api.select(this.st.transport, sid)).then(() => {
			common.notify(on
				? _('Switching to the selected server: connections through the tunnel will reopen.')
				: _('Server selected. It will be used when you turn Shadow on.'));

			return this.refresh();
		}).catch(err => {
			common.fail(err);
			this.pickKey = null;
			return this.refresh();
		});
	},

	/* Tunnel check */

	checkText(r, ep) {
		const e = r.endpoint || ep;
		const ms = (r.ms != null) ? _('%d ms').format(r.ms) : null;
		const secs = (r.ms != null) ? _('%s s').format((r.ms / 1000).toFixed(1)) : null;

		switch (r.outcome) {
		case 'tls':
			return [ _('%s answered the TLS handshake in').format(e), ' ', el('strong', {}, [ ms ]) ];
		case 'tls-alert':
			return [ _('%s answered with a TLS alert: the tunnel carries data, but the endpoint refused the probe handshake.').format(e), ms ? ' — ' + ms : null ];
		case 'http':
			// detail: the status line, e.g. "HTTP/1.1 301 Moved Permanently"
			return [ _('%s answered: %s').format(e, r.detail || 'HTTP'), ms ? ' — ' + ms : null ];
		case 'bytes':
			return [ _('%s answered with data that is not TLS: the tunnel carries data, but something other than the endpoint may be answering.').format(e), ms ? ' — ' + ms : null ];
		case 'silent':
			return [ _('%s sent nothing: the tunnel opened the connection, but it could not be verified end to end.').format(e) ];
		case 'refused':
			return [ _('The server could not open %s (%s)').format(e, socksReason(r)), secs ? ' — ' + secs : null ];
		case 'timeout':
			return [ _('The tunnel opened a connection to %s but nothing came back within 12 s. Traffic is entering the tunnel and not reaching the server.').format(e) ];
		case 'local':
			return [ _('The check could not start through the local Xray: %s').format(common.tr(r.detail) || '?') ];
		default:
			return [ common.tr(r.detail) || _('The check failed.') ];
		}
	},

	renderCheck() {
		const st = this.st;
		const ep = st.check_endpoint || 'youtube.com:443';
		const connected = !!(st.enabled && st.active && st.phase == 'connected');
		const box = (c, children) => el('div', { class: 'shv-result shv-c-' + c }, children);
		let result;

		if (this.checking) {
			result = box('acc', [ el('span', { class: 'spinning' }, [ _('Checking %s through the tunnel…').format(ep) ]) ]);
		}
		else if (!connected) {
			result = box('off', [ el('span', { class: 'shv-muted' }, [ _('The check is available when the tunnel is connected.') ]) ]);
		}
		else if (!st.check) {
			result = box('off', [ el('span', { class: 'shv-muted' }, [ _('Not checked yet.') ]) ]);
		}
		else {
			const r = st.check;
			const ago = (r.age != null) ? common.agoAge(r.age) : (r.at ? common.agoText(r.at) : null);
			const when = ago ? el('span', { class: 'shv-muted' }, [ ' · ', ago ]) : null;
			const hint = (!r.ok && st.target && st.target.protocol == 'hysteria2')
				? ' ' + _('Hysteria 2 runs over UDP (QUIC): the network may block UDP to the server or its ports, or the link’s password (auth), certificate pin (pinSHA256) or obfs password may be wrong.')
				: null;
			const c = !r.ok ? 'bad' : (r.outcome == 'silent' ? 'warn' : 'ok');

			result = box(c, [ el('b', {}, [ r.ok ? '✓' : '✕' ]), el('span', {}, [ this.checkText(r, ep), hint, when ]) ]);
		}

		return el('div', {}, [
			el('div', { class: 'shv-row', style: 'margin-bottom:10px' }, [
				el('span', {}, [ _('Address:'), ' ', el('span', { class: 'shv-mono' }, [ ep ]) ]),
				common.button(_('Edit'), null, () => this.editEndpoint(ep)),
				common.button(_('Check'), 'cbi-button-action', () => this.runCheck(),
					{ disabled: (!connected || this.checking) ? '' : null })
			]),
			result
		]);
	},

	/* A check that ran shows its outcome in the result box, a failed one too; only a check that could not
	 * run or never finished raises a notification. */
	runCheck() {
		this.checking = true;
		this.update();

		return common.checked(common.api.check())
			.then(res => res.job ? common.waitJob(res.job, 30000) : null)
			.then(job => {
				if (job && job.state != 'done' && !(job.result && job.result.outcome))
					common.fail(common.jobError(job));
			})
			.catch(err => common.fail(err))
			.finally(() => {
				this.checking = false;
				return this.refresh();
			});
	},

	editEndpoint(ep) {
		const input = el('input', { class: 'cbi-input-text', type: 'text', value: ep, style: 'width:100%' });
		const err = el('div', { class: 'shv-err' });

		common.modal(_('Check address'), [
			el('p', {}, [ _('Site and port separated by a colon, without https:// or a path. On ports 443 and 8443 Shadow starts a TLS handshake, on 80 and 8080 it sends an HTTP request.') ]),
			input,
			err
		], [
			common.closeButton(_('Cancel')),
			common.button(_('Save'), 'cbi-button-positive', () =>
				common.api.settingsSet({ check_endpoint: input.value.trim() }).then(res => {
					if (res.errors || res.error) {
						err.textContent = common.tr((res.errors && res.errors.check_endpoint) || res.error);
						return;
					}

					ui.hideModal();
					common.notify(_('Check address saved.'));

					return this.refresh();
				}).catch(e => { err.textContent = common.tr(e.message); }))
		]);

		input.focus();
	},

	/* Banners */

	attentionBanner(a) {
		const actions = [];

		switch (a.code) {
		case 'nothing_to_route':
		case 'list_failed':
		case 'rules_invalid':
			actions.push(pageLink(_('Routing'), 'routing'));
			break;

		case 'ssh_fatal':
			actions.push(pageLink(_('Open SSH'), 'ssh'));
			break;

		case 'xray_config':
			actions.push(pageLink(_('Open Xray'), 'xray'));
			break;

		case 'dns_upstream_leak':
			actions.push(el('a', { class: 'btn cbi-button', href: L.url('admin/network/dhcp') }, [ _('DHCP and DNS') ]), ' ',
				pageLink(_('Settings'), 'settings'));
			break;

		case 'dns_bootstrap':
			actions.push(el('a', { class: 'btn cbi-button', href: L.url('admin/network/dhcp') }, [ _('DHCP and DNS') ]));
			break;

		case 'update_available':
		case 'update_failed':
			actions.push(pageLink(_('Settings'), 'settings'));
			break;
		}

		actions.push(common.button(_('Dismiss'), null, () =>
			common.api.attentionDismiss(a.id).then(() => this.refresh()).catch(err => common.fail(err))));

		const cls = (a.code in { ssh_fatal: 1, xray_config: 1, port_busy: 1, dns_rejected: 1, nft_rejected: 1 }) ? 'error'
			: (a.code == 'update_available') ? 'info' : 'warning';

		return banner(cls, attentionTitle(a), common.tr(a.message), actions, a.id);
	},

	renderBanners() {
		const st = this.st;
		const out = [];
		const codes = {};

		(st.attention || []).forEach(a => { codes[a.code] = true; });

		if (st.hostkey)
			out.push(banner('error', _('Server fingerprint did not match'),
				_('If you reinstalled the server, open it on the SSH tab and press “Pin this key”. Otherwise do not connect: someone may be impersonating the server.'),
				[ pageLink(_('Open server'), 'ssh') ]));

		if (st.mode == 'selected-rules' && st.routing && !st.routing.targets && !codes.nothing_to_route)
			out.push(banner('warning', _('Nothing to route through the tunnel'),
				_('In “Selected only” mode no list, rule or device is enabled, so Shadow will not turn on.'),
				[ pageLink(_('Routing'), 'routing') ]));

		(st.attention || []).forEach(a => out.push(this.attentionBanner(a)));

		return common.nodes(out);
	},

	/* Summary tiles */

	renderTiles() {
		const st = this.st;
		const r = st.routing || {};
		const split = (st.mode == 'selected-rules');
		const m = st.memory || {};
		const rc = r.rules || {};
		const tile = (h, v, s) => el('div', { class: 'shv-tile' }, [
			el('h5', {}, [ h ]), el('div', { class: 'v' }, [ v ]), el('div', { class: 's' }, [ s ])
		]);

		const own = [];

		if (rc.domain)
			own.push(N_(rc.domain, '%d domain', '%d domains').format(rc.domain));
		if (rc.ip)
			own.push(N_(rc.ip, '%d IP', '%d IPs').format(rc.ip));
		if (rc.device)
			own.push(N_(rc.device, '%d device', '%d devices').format(rc.device));

		let routeSub;

		if (split) {
			const n = (r.proxy && r.proxy.count) || 0;
			routeSub = (r.proxy && r.proxy.enabled)
				? _('“%s”: %s').format(_('Blocked in Russia'), N_(n, '%d domain', '%d domains').format(n))
				: _('only your rules and devices');
		}
		else {
			routeSub = (r.direct && r.direct.enabled)
				? _('except “%s” and the local network').format(_('Russian services'))
				: _('except the local network');
		}

		const used = [];

		if (m.xray_kb)
			used.push('xray ' + common.sizeText(m.xray_kb));
		if (m.ssh_kb)
			used.push('ssh ' + common.sizeText(m.ssh_kb));

		return el('div', {}, [
			el('div', { class: 'shv-grid' }, [
				tile(_('Routing'), split ? _('Selected only') : _('All traffic'), routeSub),
				tile(_('Own rules'), own.length ? own.join(' · ') : _('none'),
					el('a', { href: L.url('admin/services/shadow-vpn/routing') }, [ _('Configure →') ])),
				tile(_('Memory'), used.length ? used.join(' · ') : common.sizeText(0),
					_('free %s of %s').format(common.sizeText(m.free_kb), common.sizeText(m.total_kb)))
			]),
			split ? el('p', { class: 'shv-muted', style: 'margin:10px 0 0' }, [
				_('Browsers with their own secure DNS (DoH) bypass split routing: turn it off in the browser for listed sites to go through the tunnel.')
			]) : null
		]);
	}
});
