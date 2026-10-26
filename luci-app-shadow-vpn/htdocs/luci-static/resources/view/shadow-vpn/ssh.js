'use strict';
'require view';
'require dom';
'require form';
'require ui';
'require shadow-vpn.common as common';

const el = common.el;

const KEY_TYPES = { ed25519: 'Ed25519', ecdsa: 'ECDSA', rsa: 'RSA' };
const KEY_FORMATS = { openssh: 'OpenSSH', pem: 'PEM', pkcs8: 'PKCS#8' };
const SERVER_FIELDS = [ 'name', 'host', 'port', 'username', 'auth', 'key', 'fingerprint', 'keepalive', 'note' ];
const FP_RE = /^SHA256:[A-Za-z0-9+/]{43}$/;

/* An encrypted PKCS#8 key hides its algorithm ('unknown'); OpenSSH reads it all the same. */
function keyType(t) {
	return KEY_TYPES[t] || ((t == 'unknown') ? _('Type hidden by encryption') : t);
}

function shortFp(fp) {
	return (fp && fp.length > 22) ? fp.slice(0, 22) + '…' : (fp || '');
}

function dayText(epoch) {
	return new Date(epoch * 1000).toLocaleDateString(document.documentElement.getAttribute('lang') || undefined,
		{ day: '2-digit', month: '2-digit' });
}

function errorBox() {
	return el('div', { class: 'alert-message error shv-errors', style: 'display:none' });
}

function showErrors(box, errors, labels) {
	const items = Object.keys(errors || {}).map(k =>
		el('li', {}, [ labels[k] ? labels[k] + ': ' : '', common.tr(errors[k]) ]));

	dom.content(box, [ el('ul', {}, items) ]);
	box.style.display = '';
}

function showError(box, message) {
	dom.content(box, [ common.tr(message) ]);
	box.style.display = '';
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
			common.api.servers(),
			common.api.keys(),
			L.resolveDefault(common.api.status(), {})
		]).then(data => {
			this.servers = data[0].servers || [];
			this.keys = data[1].keys || [];
			this.st = data[2] || {};
		});
	},

	reload() {
		return this.fetch().then(() => this.draw()).catch(err => common.fail(err));
	},

	render() {
		this.serverBox = E('div');
		this.keyBox = E('div');
		this.draw();

		return common.page(_('SSH'), _('Servers for the SSH tunnel and keys to log in to them. Passwords and keys are stored only on the router and never reach the log.'), [
			common.section(_('Servers'), null, [
				this.serverBox,
				el('div', { class: 'cbi-section-create' }, [
					common.button(_('Add server'), 'cbi-button-add', () => this.editServer(null))
				])
			]),
			common.section(_('Keys'), _('Ed25519, ECDSA and RSA in OpenSSH, PEM or PKCS#8 format, including ones protected with a passphrase.'), [
				this.keyBox,
				el('div', { class: 'cbi-section-create' }, [
					common.button(_('Add key'), 'cbi-button-add', () => this.editKey(null))
				])
			])
		]);
	},

	draw() {
		dom.content(this.serverBox, this.renderServers());
		dom.content(this.keyBox, this.renderKeys());
	},

	/* Servers */

	hostKeyCell(s) {
		const hk = s.hostkey || {};

		if (hk.problem)
			return [ common.badge('bad', _('key changed')),
				el('div', { class: 'shv-sub shv-mono' }, [ _('the server showed %s').format(shortFp(hk.problem.got)) ]) ];

		if (s.fingerprint)
			return [ common.badge('ok', _('✓ pinned')), el('div', { class: 'shv-sub shv-mono' }, [ shortFp(s.fingerprint) ]) ];

		if (hk.trusted)
			return [ common.badge('acc', _('trusted')), el('div', { class: 'shv-sub' }, [
				hk.trusted.type, hk.trusted.at ? ' · ' + _('trusted since %s').format(dayText(hk.trusted.at)) : null
			]) ];

		return [ common.badge('off', _('not checked')), el('div', { class: 'shv-sub' }, [ _('remembered on the first connection') ]) ];
	},

	renderServers() {
		if (!this.servers.length)
			return el('div', { class: 'shv-empty' }, [
				_('No servers yet. Any server you log in to over SSH will do: nothing needs to be installed on it.')
			]);

		const inUse = this.st.enabled && this.st.transport == 'ssh';
		const rows = this.servers.map(s => el('tr', { class: 'tr' }, [
			el('td', { class: 'td' }, [
				el('div', { class: 'shv-name' }, [ s.name, ' ', (s.selected && inUse) ? common.badge('ok', _('in use')) : null ]),
				s.note ? el('div', { class: 'shv-sub' }, [ s.note ]) : null
			]),
			el('td', { class: 'td shv-mono' }, [ '%s@%s'.format(s.username, common.hostPort(s.host, s.port)) ]),
			el('td', { class: 'td' }, (s.auth == 'key')
				? [ _('Key'), el('div', { class: 'shv-sub' }, [ s.key_name || '—' ]) ]
				: [ _('Password') ]),
			el('td', { class: 'td' }, this.hostKeyCell(s)),
			el('td', { class: 'td shv-actions' }, [
				common.button(_('Edit'), 'cbi-button-edit', () => this.editServer(s)), ' ',
				common.button(_('Delete'), 'cbi-button-remove', () => this.deleteServer(s))
			])
		]));

		return el('table', { class: 'table shv-table' }, [
			el('tr', { class: 'tr table-titles' }, [ _('Name'), _('Address'), _('Login'), _('Server key'), '' ]
				.map(h => el('th', { class: 'th' }, [ h ]))),
			rows
		]);
	},

	serverLabels() {
		return {
			name: _('Name'), host: _('Address'), port: _('Port'), username: _('User'), auth: _('Login'), key: _('Key'),
			password: _('Password'), fingerprint: _('Server fingerprint'), keepalive: _('Keep-alive check, s'), note: _('Note')
		};
	},

	editServer(s) {
		const labels = this.serverLabels();
		const data = { srv: {
			name: s ? s.name : '',
			host: s ? s.host : '',
			port: s ? String(s.port) : '22',
			username: s ? s.username : 'root',
			auth: s ? s.auth : 'password',
			key: (s && s.key) || '',
			password: '',
			fingerprint: (s && s.fingerprint) || '',
			keepalive: s ? String(s.keepalive) : '15',
			note: (s && s.note) || ''
		} };
		const m = new form.JSONMap(data);
		const sec = m.section(form.NamedSection, 'srv', 'srv');
		let o;

		// the router's limits (DESIGN §5): what the form saves is what the router shows again
		o = sec.option(form.Value, 'name', labels.name);
		o.placeholder = _('For example, Hetzner, Helsinki');
		o.datatype = 'maxlength(64)';

		o = sec.option(form.Value, 'host', labels.host);
		o.placeholder = _('vpn.example.com or IP');
		o.datatype = 'host';

		o = sec.option(form.Value, 'port', labels.port);
		o.datatype = 'port';

		o = sec.option(form.Value, 'username', labels.username);

		o = sec.option(form.ListValue, 'auth', labels.auth);
		o.value('password', _('With a password'));
		o.value('key', _('With a key'));

		o = sec.option(form.Value, 'password', labels.password);
		o.password = true;
		o.depends('auth', 'password');

		if (s && s.has_password) {
			o.placeholder = _('unchanged');
			o.description = _('Leave empty to keep the saved password.');
		}

		o = sec.option(form.ListValue, 'key', labels.key);
		o.depends('auth', 'key');

		if (!this.keys.length)
			o.value('', _('No keys yet: add one in the Keys section'));

		this.keys.forEach(k => o.value(k.sid, '%s (%s)'.format(k.name, keyType(k.type))));

		o = sec.option(form.Value, 'fingerprint', labels.fingerprint);
		o.placeholder = 'SHA256:…';
		o.description = _('Optional. Empty: Shadow remembers the server key on the first connection and refuses to connect if it changes.');
		o.validate = (id, v) => (!v || FP_RE.test(v.trim()))
			|| _('SSH server fingerprint must use the OpenSSH SHA256:base64 format (43 characters after SHA256:).');

		o = sec.option(form.Value, 'keepalive', labels.keepalive);
		o.datatype = 'and(uinteger,range(5,3600))';
		o.description = _('How often to check that the server answers. A broken connection is noticed after about 3 such intervals.');

		o = sec.option(form.Value, 'note', labels.note);
		o.datatype = 'maxlength(500)';

		const errors = errorBox();

		return m.render().then(node => {
			common.modal(s ? _('Edit server') : _('New server'), [ node, this.hostKeyBlock(s), errors ], [
				common.closeButton(_('Cancel')),
				common.button(_('Save'), 'cbi-button-positive', () => this.saveServer(m, data, s, errors, labels))
			]);
		});
	},

	hostKeyBlock(s) {
		const hk = (s && s.hostkey) || {};
		const seen = hk.seen;
		const forget = hk.trusted
			? common.button(_('Forget trusted key'), null, () => this.forgetHostKey(s))
			: null;

		if (seen && seen.fingerprint != s.fingerprint)
			return el('div', { class: 'alert-message notice' }, [
				el('strong', {}, [ _('The last connection saw this key') ]),
				el('p', { class: 'shv-mono' }, [ seen.type + ' ' + seen.fingerprint ]),
				el('div', {}, [
					common.button(_('Pin this key'), 'cbi-button-action', () => this.pinHostKey(s)), ' ', forget
				])
			]);

		if (forget)
			return el('div', { class: 'alert-message notice' }, [
				el('strong', {}, [ _('Trusted server key') ]),
				el('p', { class: 'shv-mono' }, [ hk.trusted.type + ' ' + hk.trusted.fingerprint ]),
				el('div', {}, [ forget ])
			]);

		return null;
	},

	saveServer(m, data, s, errors, labels) {
		errors.style.display = 'none';

		return m.save(null, true).then(() => {
			const v = data.srv;
			const values = {};

			SERVER_FIELDS.forEach(k => { values[k] = (v[k] != null) ? String(v[k]).trim() : ''; });

			if (values.auth != 'key')
				values.key = '';

			return common.api.serverSave(s ? s.sid : '', values, v.password || '');
		}).then(res => {
			if (res.errors)
				return showErrors(errors, res.errors, labels);

			if (res.error)
				return showError(errors, res.error);

			ui.hideModal();
			common.notify(s ? _('Server saved. Changes apply on the next connection.') : _('Server added.'));

			return this.reload();
		}).catch(err => showError(errors, err.message));
	},

	/* The fingerprint shown goes along: the router pins it only while it is still the key it last saw. */
	pinHostKey(s) {
		const seen = s.hostkey && s.hostkey.seen;

		return common.checked(common.api.hostkeyPin(s.sid, seen ? seen.fingerprint : '')).then(() => {
			ui.hideModal();
			common.notify(_('Key pinned: Shadow will connect only to this server.'));

			return this.reload();
		}).catch(err => common.fail(err));
	},

	forgetHostKey(s) {
		return common.checked(common.api.hostkeyForget(s.sid)).then(() => {
			ui.hideModal();
			common.notify(_('Trusted key forgotten: on the next connection Shadow remembers the new one.'));

			return this.reload();
		}).catch(err => common.fail(err));
	},

	deleteServer(s) {
		common.modal(_('Delete server'), [
			el('p', {}, [ _('Delete server “%s”? Its saved password is deleted too.').format(s.name) ])
		], [
			common.closeButton(_('Cancel')),
			common.button(_('Delete'), 'cbi-button-negative', () =>
				common.checked(common.api.serverDelete(s.sid)).then(() => {
					ui.hideModal();
					common.notify(_('Server “%s” deleted.').format(s.name));

					return this.reload();
				}).catch(err => { ui.hideModal(); common.fail(err); }))
		]);
	},

	/* Keys */

	renderKeys() {
		if (!this.keys.length)
			return el('div', { class: 'shv-empty' }, [ _('No keys. Logging in with a password works too.') ]);

		const rows = this.keys.map(k => el('tr', { class: 'tr' }, [
			el('td', { class: 'td shv-name' }, [ k.name ]),
			el('td', { class: 'td' }, [
				keyType(k.type), ' ',
				el('span', { class: 'shv-muted' }, [ '· ' + (KEY_FORMATS[k.format] || k.format) ]), ' ',
				k.encrypted ? common.badge('acc', _('with passphrase')) : null
			]),
			el('td', { class: 'td' }, [ k.used
				? N_(k.used, '%d server', '%d servers').format(k.used)
				: el('span', { class: 'shv-muted' }, [ _('not used') ]) ]),
			el('td', { class: 'td shv-actions' }, [
				common.button(_('Show'), null, () => this.showKey(k)), ' ',
				common.button(_('Edit'), 'cbi-button-edit', () => this.editKey(k)), ' ',
				common.button(_('Delete'), 'cbi-button-remove', () => this.deleteKey(k), {
					disabled: k.used ? '' : null,
					title: k.used ? _('The key is used by a server') : null
				})
			])
		]));

		return el('table', { class: 'table shv-table' }, [
			el('tr', { class: 'tr table-titles' }, [ _('Name'), _('Type'), _('Used by'), '' ]
				.map(h => el('th', { class: 'th' }, [ h ]))),
			rows
		]);
	},

	editKey(k) {
		const labels = { name: _('Name'), text: _('Private key'), passphrase: _('Key passphrase') };
		const data = { key: { name: k ? k.name : '', text: '', passphrase: '' } };
		const m = new form.JSONMap(data);
		const sec = m.section(form.NamedSection, 'key', 'key');
		let o;

		o = sec.option(form.Value, 'name', labels.name);
		o.datatype = 'maxlength(64)';

		o = sec.option(form.TextValue, 'text', labels.text);
		o.rows = 8;
		o.monospace = true;
		o.placeholder = k ? _('unchanged') : '-----BEGIN OPENSSH PRIVATE KEY-----\n…';
		o.description = _('Paste the contents of the file (for example ~/.ssh/id_ed25519), not the path to it. You can also load the file with the button below.');

		o = sec.option(form.Value, 'passphrase', labels.passphrase);
		o.password = true;
		o.placeholder = (k && k.has_passphrase) ? _('unchanged') : _('if the key is protected with a passphrase');

		const errors = errorBox();
		const file = E('input', { type: 'file', style: 'display:none' });

		return m.render().then(node => {
			file.addEventListener('change', () => {
				if (!file.files.length)
					return;

				common.readFile(file.files[0], 65536).then(text => {
					const ta = node.querySelector('textarea');
					ta.value = text;
					ta.dispatchEvent(new Event('input', { bubbles: true }));
				}).catch(err => showError(errors, err.message));
			});

			common.modal(k ? _('Edit key') : _('New key'), [
				node,
				el('div', {}, [ file, el('button', { class: 'btn cbi-button', click: () => file.click() }, [ _('Load file…') ]) ]),
				errors
			], [
				common.closeButton(_('Cancel')),
				common.button(_('Save'), 'cbi-button-positive', () => this.saveKey(m, data, k, errors, labels))
			]);
		});
	},

	saveKey(m, data, k, errors, labels) {
		errors.style.display = 'none';

		return m.save(null, true).then(() => {
			const v = data.key;

			return common.api.keySave(k ? k.sid : '', String(v.name || '').trim(), v.text || '', v.passphrase || '');
		}).then(res => {
			if (res.errors)
				return showErrors(errors, res.errors, labels);

			if (res.error)
				return showError(errors, res.error);

			const info = res.key || {};
			const parts = [ keyType(info.type), _('%s format').format(KEY_FORMATS[info.format] || info.format) ];

			if (info.encrypted)
				parts.push(_('protected with a passphrase'));

			ui.hideModal();
			common.notify(_('Key saved: %s.').format(parts.join(', ')));

			return this.reload();
		}).catch(err => showError(errors, err.message));
	},

	showKey(k) {
		return common.checked(common.api.keyShow(k.sid)).then(res => {
			const ta = el('textarea', { class: 'cbi-input-textarea shv-mono', rows: 8, readonly: '', style: 'width:100%' });

			ta.value = res.text || '';

			common.modal(_('Key “%s”').format(k.name), [
				el('p', {}, [ _('This is a private key. Copy it and close the window; never show it to anyone.') ]),
				ta
			], [ common.closeButton() ]);

			ta.focus();
			ta.select();
		}).catch(err => common.fail(err));
	},

	deleteKey(k) {
		common.modal(_('Delete key'), [
			el('p', {}, [ _('Delete key “%s”?').format(k.name) ])
		], [
			common.closeButton(_('Cancel')),
			common.button(_('Delete'), 'cbi-button-negative', () =>
				common.checked(common.api.keyDelete(k.sid)).then(() => {
					ui.hideModal();
					common.notify(_('Key “%s” deleted.').format(k.name));

					return this.reload();
				}).catch(err => { ui.hideModal(); common.fail(err); }))
		]);
	}
});
