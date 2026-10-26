'use strict';
'require view';
'require dom';
'require ui';
'require shadow-vpn.common as common';

const el = common.el;

function details(p) {
	return [ common.transportName(p.transport), common.securityName(p.security), common.flowName(p.flow) ]
		.filter(Boolean).join(' · ');
}

function address(p) {
	return common.hostPort(p.host, p.hop_ports || p.port);
}

function unsupportedText(p) {
	return (p.security == 'unknown')
		? _('This profile uses an unsupported security mode.')
		: _('This profile uses an unsupported or unrecognized Xray transport.');
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load() {
		return this.fetch();
	},

	fetch() {
		return Promise.all([
			common.api.profiles(),
			L.resolveDefault(common.api.status(), {})
		]).then(data => {
			this.profiles = data[0].profiles || [];
			this.st = data[1] || {};
		});
	},

	reload() {
		return this.fetch().then(() => this.draw()).catch(err => common.fail(err));
	},

	render() {
		this.search = el('input', { type: 'text', class: 'cbi-input-text',
			placeholder: _('Search: name, protocol, address, transport'), input: () => this.filter() });
		this.tableBox = E('div');
		this.countBox = el('p', { class: 'shv-muted', style: 'margin-top:10px' });
		this.draw();

		return common.page(_('Xray'), _('Xray profiles from share links. A link is a secret: it is stored only on the router and shown only on request.'), [
			common.section(null, null, [
				el('div', { class: 'shv-toolbar' }, [
					el('div', { class: 'grow' }, [ this.search ]),
					common.button(_('Add link'), 'cbi-button-add', () => this.importLinks(false)),
					common.button(_('Import list'), null, () => this.importLinks(true)),
					common.button(_('Delete unpinned'), 'cbi-button-remove', () => this.deleteUnpinned())
				]),
				this.tableBox,
				this.countBox
			])
		]);
	},

	draw() {
		const all = this.profiles;
		const pinned = all.filter(p => p.pinned).length;

		dom.content(this.tableBox, this.renderTable());
		dom.content(this.countBox, [
			N_(all.length, '%d profile', '%d profiles').format(all.length) + ' · ' + _('%d pinned').format(pinned)
		]);
		this.filter();
	},

	filter() {
		const q = this.search.value.trim().toLowerCase();

		this.tableBox.querySelectorAll('tr[data-text]').forEach(tr => {
			tr.style.display = (!q || tr.getAttribute('data-text').indexOf(q) >= 0) ? '' : 'none';
		});
	},

	renderRow(p) {
		const flags = [];

		if (!p.supported)
			flags.push(common.badge('bad', _('not supported'), unsupportedText(p)));

		if (p.insecure_without_pin)
			flags.push(common.badge('warn', 'insecure=1', _('Certificate checks stay on')));

		const star = el('span', {
			class: 'shv-star' + (p.pinned ? ' on' : ''),
			title: p.pinned ? _('Unpin') : _('Pin'),
			click: () => this.togglePin(p)
		}, [ '★' ]);

		const text = [ p.name, common.protocolName(p.protocol), p.host, p.transport, p.security ].join(' ').toLowerCase();
		// the selection stays while the transport is SSH; Select is then what puts the profile into use
		const current = p.selected && this.st.transport == 'xray';

		return el('tr', { class: 'tr', 'data-text': text }, [
			el('td', { class: 'td', style: 'width:28px' }, [
				el('span', { class: 'shv-sel' + (p.selected ? ' on' : ''), title: p.selected ? _('Selected') : null })
			]),
			el('td', { class: 'td' }, [
				el('div', { class: 'shv-name' }, [ star, ' ', p.name ]),
				el('div', { class: 'shv-sub shv-mono' }, [ address(p) ])
			]),
			el('td', { class: 'td' }, [
				el('div', {}, [ common.protocolName(p.protocol) ]),
				el('div', { class: 'shv-sub' }, [ details(p) ])
			]),
			el('td', { class: 'td' }, flags),
			el('td', { class: 'td shv-actions' }, [
				current
					? common.badge('ok', _('selected'))
					: common.button(_('Select'), 'cbi-button-action', () => this.selectProfile(p), { disabled: p.supported ? null : '' }),
				' ',
				common.button('⋯', null, () => this.menu(p), { title: _('More') })
			])
		]);
	},

	renderTable() {
		if (!this.profiles.length)
			return el('div', { class: 'shv-empty' }, [
				_('No profiles. Paste a link from your server:'), ' ',
				el('span', { class: 'shv-mono' }, [ 'vless://' ]), ', ',
				el('span', { class: 'shv-mono' }, [ 'vmess://' ]), ', ',
				el('span', { class: 'shv-mono' }, [ 'trojan://' ]), ' ', _('or'), ' ',
				el('span', { class: 'shv-mono' }, [ 'hysteria2://' ]), '.'
			]);

		return el('table', { class: 'table shv-table' }, [
			el('thead', {}, [ el('tr', { class: 'tr table-titles' }, [ '', _('Profile'), _('Protocol'), '', '' ]
				.map(h => el('th', { class: 'th' }, [ h ]))) ]),
			el('tbody', {}, this.profiles.map(p => this.renderRow(p)))
		]);
	},

	togglePin(p) {
		return common.checked(common.api.profilePin(p.sid, !p.pinned))
			.then(() => this.reload())
			.catch(err => common.fail(err));
	},

	/* Selecting is using: while Shadow runs over SSH it switches the tunnel to Xray, so that is asked first. */
	selectProfile(p) {
		let on = false;

		return L.resolveDefault(common.api.status(), {}).then(st => {
			on = !!(st && st.enabled);

			if (!on || st.transport != 'ssh')
				return true;

			return new Promise(resolve => {
				common.modal(_('Switch to Xray?'), [
					el('p', {}, [ _('Shadow is on over SSH. Using profile “%s” switches the tunnel to Xray and reconnects it.').format(p.name) ])
				], [
					el('button', { class: 'btn cbi-button', click: () => { ui.hideModal(); resolve(false); } }, [ _('Cancel') ]),
					el('button', { class: 'btn cbi-button cbi-button-action', click: () => { ui.hideModal(); resolve(true); } },
						[ _('Switch to Xray') ])
				]);
			});
		}).then(go => {
			if (!go)
				return;

			return common.checked(common.api.select('xray', p.sid)).then(() => {
				common.notify(on
					? _('Switching to profile “%s”: connections through the tunnel will reopen.').format(p.name)
					: _('Profile “%s” selected.').format(p.name));

				return this.reload();
			});
		}).catch(err => common.fail(err));
	},

	importLinks(many) {
		const ta = el('textarea', {
			class: 'cbi-input-textarea shv-mono', rows: many ? 10 : 3, style: 'width:100%',
			placeholder: many ? _('One link per line. Empty lines and lines starting with # are skipped.') : 'vless://…'
		});
		const result = E('div');

		common.modal(many ? _('Import links') : _('New profile'), [ ta, result ], [
			common.closeButton(),
			common.button(many ? _('Import') : _('Add'), 'cbi-button-positive', () => {
				const text = ta.value;

				if (!text.trim())
					return;

				return common.checked(common.api.profilesImport(text, many ? 'import' : 'manual')).then(res => {
					const ok = (res.added || 0) + (res.updated || 0);

					this.reload();

					if (!many && ok && !res.failed) {
						ui.hideModal();
						common.notify(_('Xray profile saved.'));
						return;
					}

					dom.content(result, this.importSummary(res));
				}).catch(err => dom.content(result, el('div', { class: 'alert-message error', style: 'margin-top:12px' }, [ err.message ])));
			})
		]);

		ta.focus();
	},

	importSummary(res) {
		const errors = (res.errors || []).slice(0, 20).map(e =>
			el('div', { class: 'shv-mono' }, [ (e.line != null) ? _('Line %d: %s').format(e.line, common.tr(e.message)) : common.tr(e.message) ]));
		const more = (res.errors || []).length - errors.length;

		return el('div', { class: 'alert-message ' + (res.failed ? 'warning' : 'notice'), style: 'margin-top:12px' }, [
			el('strong', {}, [ _('Added %d, updated %d, skipped %d, failed %d.').format(res.added || 0, res.updated || 0, res.skipped || 0, res.failed || 0) ]),
			errors.length ? el('div', { style: 'margin-top:6px' }, errors) : null,
			(more > 0) ? el('div', { class: 'shv-muted' }, [ _('…and %d more.').format(more) ]) : null
		]);
	},

	menu(p) {
		const name = el('input', { class: 'cbi-input-text', type: 'text', value: p.name, style: 'width:100%' });
		const err = el('div', { class: 'shv-err' });

		common.modal(p.name, [
			el('dl', { class: 'shv-kv' }, [
				el('dt', {}, [ _('Protocol') ]), el('dd', {}, [ common.protocolName(p.protocol) ]),
				el('dt', {}, [ _('Server') ]), el('dd', { class: 'shv-mono' }, [ address(p) ]),
				el('dt', {}, [ _('Transport') ]), el('dd', {}, [ details(p) ]),
				p.created ? el('dt', {}, [ _('Added') ]) : null,
				p.created ? el('dd', {}, [ common.dateText(p.created) ]) : null
			]),
			!p.supported ? el('div', { class: 'alert-message warning' }, [
				unsupportedText(p), ' ', _('The profile is saved, but you cannot connect through it.')
			]) : null,
			p.insecure_without_pin ? el('div', { class: 'alert-message warning' }, [
				el('strong', {}, [ _('Certificate checks stay on') ]),
				el('p', {}, [ _('This profile’s link asks to skip certificate checks (insecure=1), which the bundled Xray can’t do, so the server’s certificate is checked as usual. If the server uses a self-signed certificate, add the link again with its pinSHA256 and remove this one.') ])
			]) : null,
			el('div', { class: 'shv-field', style: 'margin-top:12px' }, [ el('label', {}, [ _('Name') ]), name ]),
			err
		], [
			common.closeButton(_('Cancel')),
			common.button(_('Show link'), null, () => this.showLink(p)),
			common.button(_('Delete'), 'cbi-button-remove', () => this.deleteProfile(p)),
			common.button(_('Save'), 'cbi-button-positive', () =>
				common.checked(common.api.profileRename(p.sid, name.value)).then(() => {
					ui.hideModal();
					common.notify(_('Profile renamed. The link does not change.'));

					return this.reload();
				}).catch(e => { err.textContent = e.message; }))
		]);
	},

	showLink(p) {
		return common.checked(common.api.profileLink(p.sid)).then(res => {
			const ta = el('textarea', { class: 'cbi-input-textarea shv-mono', rows: 4, readonly: '', style: 'width:100%' });

			ta.value = res.link || '';

			common.modal(_('Link “%s”').format(p.name), [
				el('p', {}, [ _('The link gives access to your server. Copy it and close the window.') ]),
				ta
			], [ common.closeButton() ]);

			ta.focus();
			ta.select();
		}).catch(err => common.fail(err));
	},

	deleteProfile(p) {
		return common.checked(common.api.profileDelete(p.sid)).then(() => {
			ui.hideModal();
			common.notify(_('Profile “%s” deleted.').format(p.name));

			return this.reload();
		}).catch(err => common.fail(err));
	},

	deleteUnpinned() {
		const n = this.profiles.filter(p => !p.pinned && !p.selected).length;

		if (!n) {
			common.notify(_('There are no unpinned profiles to delete.'));
			return;
		}

		common.modal(_('Delete unpinned'), [
			el('p', {}, [ N_(n, 'Delete %d unpinned profile? The selected profile is never deleted.',
				'Delete %d unpinned profiles? The selected profile is never deleted.').format(n) ])
		], [
			common.closeButton(_('Cancel')),
			common.button(_('Delete'), 'cbi-button-negative', () =>
				common.checked(common.api.profilesDeleteUnpinned()).then(res => {
					ui.hideModal();
					common.notify(N_(res.deleted || 0, 'Deleted %d unpinned profile.', 'Deleted %d unpinned profiles.').format(res.deleted || 0));

					return this.reload();
				}).catch(err => { ui.hideModal(); common.fail(err); }))
		]);
	}
});
