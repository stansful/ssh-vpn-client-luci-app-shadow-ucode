'use strict';
'require view';
'require dom';
'require uci';
'require ui';
'require shadow-vpn.common as common';

const el = common.el;
const MANUAL = '*';

const LISTS = {
	proxy: { file: 'Russia/inside-raw.lst', c: 'acc' },
	direct: { file: 'Russia/outside-raw.lst', c: 'off' }
};

function listTitle(kind) {
	return (kind == 'proxy') ? _('Blocked in Russia') : _('Russian services');
}

function listHint(kind) {
	return (kind == 'proxy') ? _('to the tunnel') : _('bypassing the tunnel');
}

function tabTitle(type) {
	return { domain: _('Domains'), ip: _('IP addresses'), device: _('Devices') }[type];
}

function tabHint(type) {
	switch (type) {
	case 'domain': return _('A domain together with all its subdomains. On the router *.example.com includes example.com itself too.');
	case 'ip': return _('An address or a subnet. The rule beats the local network: 10.8.0.0/16 opens the network behind the server.');
	default: return _('All traffic of the device goes through the tunnel, except the local network. This replaces the app rules of the desktop app.');
	}
}

function requiredText(type) {
	switch (type) {
	case 'domain': return common.tr('Domain pattern is required.');
	case 'ip': return common.tr('IP address or CIDR is required.');
	default: return _('Choose a device or enter its MAC or IP address.');
	}
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	tab: 'domain',

	load() {
		return Promise.all([
			common.api.lists(),
			common.api.rules(),
			L.resolveDefault(common.api.leases(), { leases: [] }),
			uci.load('shadow-vpn')
		]);
	},

	render(data) {
		this.lists = data[0] || {};
		this.rules = data[1].rules || [];
		this.leases = data[2].leases || [];
		this.mode = uci.get('shadow-vpn', 'main', 'mode') || 'proxy-all';
		this.ipv6 = uci.get('shadow-vpn', 'main', 'ipv6') == '1';

		this.modeBox = E('div');
		this.listBox = E('div');
		this.ruleBox = E('div');
		this.drawMode();
		this.drawLists();
		this.drawRules();

		return common.page(_('Routing'), _('What goes through the tunnel and what goes directly. Changes apply at once, even while connected.'), [
			common.section(_('Mode', 'routing'), null, [ this.modeBox ]),
			common.section(_('Domain lists'), [
				_('Ready-made lists from'), ' ',
				el('a', { href: 'https://github.com/itdoginfo/allow-domains', target: '_blank', rel: 'noopener' }, [ 'itdoginfo/allow-domains' ]),
				' ', _('instead of hundreds of your own rules. If a “Russian service” is also in the first list, it goes directly.')
			], [
				this.listBox,
				el('div', { class: 'shv-row', style: 'margin-top:10px' }, [
					el('span', { class: 'shv-muted' }, [ _('Refresh:') ]),
					this.renderAutoRefresh()
				])
			]),
			common.section(_('Own rules'), _('Your rules beat the lists: a domain from a rule goes through the tunnel even if it is in “Russian services”.'), [
				this.ruleBox
			])
		]);
	},

	/* As the router decides (config.targets): an enabled list counts before its first download, which
	 * Shadow retries through the tunnel once it runs. */
	hasTargets() {
		return this.rules.some(r => r.enabled) || !!(this.lists.proxy && this.lists.proxy.enabled);
	},

	waitingList() {
		return !!(this.lists.proxy && this.lists.proxy.enabled && !this.lists.proxy.count) && !this.rules.some(r => r.enabled);
	},

	/* Mode */

	drawMode() {
		const card = (key, title, text) => {
			const radio = el('input', { type: 'radio', name: 'shv-mode' });

			radio.checked = (this.mode == key);

			return el('label', { class: 'shv-card' + ((this.mode == key) ? ' on' : ''), click: ev => {
				ev.preventDefault();
				this.setMode(key);
			} }, [ radio, el('div', {}, [ el('h4', {}, [ title ]), el('p', {}, [ text ]) ]) ]);
		};

		dom.content(this.modeBox, el('div', {}, [
			el('div', { class: 'shv-mode' }, [
				card('proxy-all', _('All traffic through the tunnel'),
					_('Except the “Russian services” list, if it is on, and the local network. Sites from your rules also go through the tunnel.')),
				card('selected-rules', _('Selected only'),
					_('Only the lists, domains, IP addresses and devices you chose go through the tunnel. Everything else goes directly.'))
			]),
			(this.mode == 'selected-rules' && !this.hasTargets())
				? el('div', { class: 'alert-message warning', style: 'margin-top:12px' }, [
					_('There is nothing to route through the tunnel now: turn on a list or add a rule, otherwise Shadow will not turn on.')
				])
				: (this.mode == 'selected-rules' && this.waitingList())
				? el('div', { class: 'alert-message notice', style: 'margin-top:12px' }, [
					_('The “Blocked in Russia” list is not downloaded yet. Shadow turns on anyway and downloads it through the tunnel; until then nothing goes through the tunnel.')
				])
				: null
		]));
	},

	setMode(key) {
		if (key == this.mode)
			return;

		return common.checked(common.api.settingsSet({ mode: key })).then(res => {
			if (res.errors)
				throw new Error(common.tr(res.errors.mode));

			this.mode = key;
			this.drawMode();
			this.drawLists();
			common.notify(_('Mode saved.'));
		}).catch(err => common.fail(err));
	},

	/* Lists */

	renderAutoRefresh() {
		const current = uci.get('shadow-vpn', 'main', 'lists_refresh') || '24';
		const options = [ [ '0', _('manually only') ], [ '6', _('every 6 hours') ], [ '24', _('once a day') ], [ '168', _('once a week') ] ];

		if (!options.some(o => o[0] == current))
			options.push([ current, _('every %d hours').format(+current) ]);

		const sel = el('select', { class: 'cbi-input-select', change: () =>
			common.checked(common.api.settingsSet({ lists_refresh: sel.value })).then(res => {
				if (res.errors)
					throw new Error(common.tr(res.errors.lists_refresh));

				common.notify(_('Auto-refresh saved.'));
			}).catch(err => common.fail(err))
		}, options.map(o => el('option', { value: o[0] }, [ o[1] ])));

		sel.value = current;

		return sel;
	},

	drawLists() {
		dom.content(this.listBox, [ this.listRow('proxy'), this.listRow('direct') ]);
	},

	listRow(kind) {
		const l = this.lists[kind] || {};
		const sub = [
			l.count
				? N_(l.count, '%d domain', '%d domains').format(l.count) + ' · ' + _('updated %s').format(common.dateText(l.updated))
				: _('not downloaded yet'),
			' · ',
			el('span', { class: 'shv-mono' }, [ LISTS[kind].file ])
		];

		if (kind == 'proxy' && this.mode == 'proxy-all')
			sub.push(el('div', {}, [ _('In “All traffic” mode this list is not needed: the tunnel gets everything anyway.') ]));

		return el('div', { class: 'shv-list' }, [
			el('div', {}, [
				el('div', { class: 'shv-name' }, [ listTitle(kind), ' ', common.badge(LISTS[kind].c, listHint(kind)) ]),
				el('div', { class: 'shv-sub' }, sub)
			]),
			el('div', { class: 'shv-row' }, [
				common.button(_('View'), null, () => this.viewList(kind)),
				common.button(_('Refresh'), null, () => this.refreshList(kind)),
				common.toggle(l.enabled, on => this.setList(kind, on), _('Use'))
			])
		]);
	},

	reloadLists() {
		return common.api.lists().then(res => {
			this.lists = res || {};
			this.drawLists();
			this.drawMode();
		}).catch(err => common.fail(err));
	},

	setList(kind, on) {
		return common.runJob(common.api.listSet(kind, on), 60000).then(() => {
			common.notify((on ? _('List “%s” is on.') : _('List “%s” is off.')).format(listTitle(kind)));
		}).catch(err => common.fail(err)).finally(() => this.reloadLists());
	},

	refreshList(kind) {
		return common.runJob(common.api.listRefresh(kind), 60000).then(() => this.reloadLists()).then(() => {
			const n = (this.lists[kind] && this.lists[kind].count) || 0;

			common.notify(_('List “%s” updated: %s.').format(listTitle(kind), N_(n, '%d domain', '%d domains').format(n)));
		}).catch(err => common.fail(err));
	},

	viewList(kind) {
		return common.checked(common.api.listView(kind)).then(res => {
			const domains = res.domains || [];
			const box = el('div', { class: 'shv-log shv-mono', style: 'max-height:320px' });
			const search = el('input', { type: 'search', class: 'cbi-input-text', placeholder: _('Find a domain'),
				style: 'width:100%;margin-bottom:8px' });
			const draw = () => {
				const q = search.value.trim().toLowerCase();
				const shown = q ? domains.filter(d => d.indexOf(q) >= 0) : domains;

				box.textContent = shown.length ? shown.join('\n')
					: (domains.length ? _('Nothing found.') : _('List is empty. Refresh it before viewing domains.'));
			};

			search.addEventListener('input', draw);
			draw();

			common.modal(listTitle(kind), [
				el('p', { class: 'shv-muted' }, [ N_(domains.length, '%d domain', '%d domains').format(domains.length) + ' · ' + LISTS[kind].file ]),
				search,
				box
			], [ common.closeButton() ]);
		}).catch(err => common.fail(err));
	},

	/* Rules */

	leaseFor(value) {
		const v = String(value).toUpperCase();

		return this.leases.find(l => l.mac == v || l.ip == value) || null;
	},

	reloadRules() {
		return Promise.all([ common.api.rules(), L.resolveDefault(common.api.leases(), { leases: this.leases }) ]).then(data => {
			this.rules = data[0].rules || [];
			this.leases = data[1].leases || [];
			this.drawRules();
			this.drawMode();
		}).catch(err => common.fail(err));
	},

	ruleInput() {
		if (this.tab != 'device')
			return { node: el('input', { type: 'text', class: 'cbi-input-text', placeholder: (this.tab == 'domain') ? 'youtube.com' : _('149.154.160.0/20 or 2001:db8::/32') }) };

		const manual = el('input', { type: 'text', class: 'cbi-input-text', placeholder: _('MAC or IP address'), style: 'display:none;margin-top:6px' });
		const sel = el('select', { class: 'cbi-input-select', style: 'width:100%', change: () => {
			manual.style.display = (sel.value == MANUAL) ? '' : 'none';

			if (sel.value == MANUAL)
				manual.focus();
		} }, [
			el('option', { value: '' }, [ _('Choose a device on the network…') ]),
			this.leases.map(l => el('option', { value: l.mac }, [ [ l.name || _('unnamed'), l.ip, l.mac ].join(' — ') ])),
			el('option', { value: MANUAL }, [ _('Enter a MAC or IP address…') ])
		]);

		return { node: el('div', {}, [ sel, manual ]), value: () => (sel.value == MANUAL) ? manual.value : sel.value };
	},

	ruleRow(r) {
		let cell;

		if (r.type == 'device') {
			const lease = this.leaseFor(r.value);

			cell = lease
				? [ el('div', { class: 'shv-name' }, [ lease.name || _('unnamed') ]), el('div', { class: 'shv-sub shv-mono' }, [ lease.ip + ' · ' + lease.mac ]) ]
				: [ el('span', { class: 'shv-mono' }, [ r.value ]) ];
		}
		else {
			cell = [ el('span', { class: 'shv-mono' }, [ r.value ]) ];

			if (r.type == 'ip' && r.value.indexOf(':') >= 0 && !this.ipv6)
				cell.push(' ', common.badge('warn', _('IPv6 is off'), _('IPv6 through the tunnel is off in Settings, so this rule does nothing.')));
		}

		return el('tr', { class: 'tr' }, [
			el('td', { class: 'td', style: 'width:60px' }, [
				common.toggle(r.enabled, on => common.checked(common.api.ruleSet(r.sid, on)).then(() => {
					r.enabled = on;
					common.notify(on ? _('Rule enabled.') : _('Rule disabled.'));
					this.drawMode();
				}).catch(err => { common.fail(err); return false; }))
			]),
			el('td', { class: 'td shv-grow' }, cell),
			el('td', { class: 'td shv-actions' }, [
				common.button(_('Delete'), 'cbi-button-remove', () => common.checked(common.api.ruleDelete(r.sid)).then(() => {
					common.notify(_('Rule deleted.'));

					return this.reloadRules();
				}).catch(err => common.fail(err)))
			])
		]);
	},

	drawRules() {
		const t = this.tab;
		const items = this.rules.filter(r => r.type == t);
		const input = this.ruleInput();
		const err = el('div', { class: 'shv-err' });
		const add = () => {
			const value = (input.value ? input.value() : input.node.value).trim();

			if (!value || value == MANUAL) {
				err.textContent = requiredText(t);
				return;
			}

			return common.api.ruleAdd(t, value).then(res => {
				if (res.error) {
					err.textContent = common.tr(res.error);
					return;
				}

				err.textContent = '';
				common.notify(_('Rule added and already works.'));

				return this.reloadRules();
			}).catch(e => { err.textContent = common.tr(e.message); });
		};

		if (!input.value)
			input.node.addEventListener('keydown', ev => { if (ev.key == 'Enter') add(); });

		const tabs = el('div', { class: 'shv-tabs' }, [ 'domain', 'ip', 'device' ].map(k =>
			el('a', { class: (k == t) ? 'on' : '', click: () => { this.tab = k; this.drawRules(); } }, [
				'%s · %d'.format(tabTitle(k), this.rules.filter(r => r.type == k).length)
			])));

		dom.content(this.ruleBox, common.nodes([
			tabs,
			el('p', { class: 'shv-muted', style: 'margin-top:0' }, [ tabHint(t) ]),
			el('div', { class: 'shv-toolbar' }, [
				el('div', { class: 'grow' }, [ input.node ]),
				common.button(_('Add'), 'cbi-button-add', add)
			]),
			err,
			items.length
				? el('table', { class: 'table shv-table' }, items.map(r => this.ruleRow(r)))
				: el('div', { class: 'shv-empty' }, [ _('No rules.') ]),
			el('div', { class: 'shv-row', style: 'margin-top:12px' }, [
				common.button(_('Import…'), null, () => this.importRules()),
				common.button(_('Export'), null, () => this.exportRules()),
				el('span', { class: 'shv-muted' }, [ _('The format is compatible with desktop Shadow.') ])
			])
		]));
	},

	importPreview(res) {
		const s = res.skipped || {};
		const parts = [];
		const other = (s.unsupported || 0) - (s.apps || 0);

		if (s.apps)
			parts.push(N_(s.apps, '%d app rule (on the router, device rules replace them)', '%d app rules (on the router, device rules replace them)').format(s.apps));
		if (other > 0)
			parts.push(N_(other, '%d rule of an unsupported type', '%d rules of an unsupported type').format(other));
		if (s.invalid)
			parts.push(N_(s.invalid, '%d invalid rule', '%d invalid rules').format(s.invalid));
		if (s.duplicates)
			parts.push(N_(s.duplicates, '%d duplicate', '%d duplicates').format(s.duplicates));
		if (s.malformed)
			parts.push(N_(s.malformed, '%d entry that is not a rule', '%d entries that are not rules').format(s.malformed));

		return el('div', { class: 'alert-message notice' }, [
			el('strong', {}, [ N_(res.total, 'The file has %d rule: %d will be loaded.', 'The file has %d rules: %d will be loaded.').format(res.total, res.imported) ]),
			parts.length ? el('p', {}, [ _('Skipped: %s.').format(parts.join(', ')) ]) : null
		]);
	},

	importRules() {
		const file = el('input', { type: 'file', accept: '.json,application/json' });
		const box = E('div');
		let text = null;

		const apply = common.button(_('Replace rules'), 'cbi-button-positive', () =>
			common.checked(common.api.rulesImport(text, true)).then(res => {
				ui.hideModal();
				common.notify(N_(res.imported, 'Imported %d rule.', 'Imported %d rules.').format(res.imported));

				return this.reloadRules();
			}).catch(err => dom.content(box, el('div', { class: 'alert-message error' }, [ err.message ]))),
			{ disabled: '' });

		file.addEventListener('change', () => {
			if (!file.files.length)
				return;

			common.readFile(file.files[0], 2097152).then(t => {
				text = t;

				return common.checked(common.api.rulesImport(t, false));
			}).then(res => {
				dom.content(box, this.importPreview(res));
				apply.disabled = !res.imported;
			}).catch(err => {
				apply.disabled = true;
				dom.content(box, el('div', { class: 'alert-message error' }, [ common.tr(err.message) ]));
			});
		});

		common.modal(_('Import rules'), [
			el('p', {}, [ _('A shadow-routing-rules.json file from desktop Shadow or another router. The import replaces the current rules.') ]),
			file,
			box
		], [ common.closeButton(_('Cancel')), apply ]);
	},

	exportRules() {
		return common.checked(common.api.rulesExport()).then(res => {
			common.download('shadow-routing-rules.json', res.json || '[]\n', 'application/json');
			common.notify(N_(this.rules.length, 'Downloaded shadow-routing-rules.json (%d rule).', 'Downloaded shadow-routing-rules.json (%d rules).').format(this.rules.length));
		}).catch(err => common.fail(err));
	}
});
