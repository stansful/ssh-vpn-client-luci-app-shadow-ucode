'use strict';
'require view';
'require dom';
'require form';
'require ui';
'require shadow-vpn.common as common';

const el = common.el;
const INSTALL = 'sh <(wget -O - https://raw.githubusercontent.com/stansful/ssh-vpn-client-luci-app-shadow-ucode/HEAD/install.sh)';

function flag(s, name, title, description, dflt) {
	const o = s.option(form.Flag, name, title, description);

	o.default = dflt;
	o.rmempty = false;

	return o;
}

/* The step of the install in progress (update_status.running.stage). */
function stageText(stage) {
	switch (stage) {
	case 'check': return _('Checking the latest release.');
	case 'download': return _('Downloading and verifying the files.');
	case 'install': return _('Installing the packages.');
	case 'finish': return _('Finishing the installation.');
	case 'settle': return _('Waiting for the tunnel to come back.');
	case 'rollback': return _('Putting the previous version back.');
	default: return '';
	}
}

return view.extend({
	load() {
		return Promise.all([
			L.resolveDefault(common.api.status(), {}),
			L.resolveDefault(common.checked(common.api.updateStatus()), null)
		]);
	},

	render(data) {
		const st = data[0];
		const m = new form.Map('shadow-vpn');
		let s, o;

		this.us = data[1];
		this.installing = null;
		// form.Map renders every option again after a Save: the update status is one node that renderWidget
		// hands back each time, so a running install keeps its state and its poll
		this.updateNode = el('div', { style: 'flex:1 1 100%;min-width:0' });
		this.paintUpdate();

		if (this.us && this.us.running)
			this.watchUpdate();

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
		o.value('debug', _('Debug', 'log'));
		o.value('info', _('Detailed'));
		o.value('warning', _('Warnings and errors'));
		o.value('error', _('Errors only'));
		o.default = 'warning';
		o.description = _('Detailed adds what you did in LuCI, restarts and their reasons, and Xray’s info lines: several for every connection through the tunnel (the device’s address and the site’s name), the tunnel switching to its fallback, failed connections to the server. Debug also adds every step Shadow takes. With traffic, both fill the system log within minutes: go back to Warnings and errors once you are done.');

		s = m.section(form.NamedSection, 'main', 'shadow', _('Updates'));

		o = s.option(form.ListValue, 'update', _('Updates'));
		o.value('manual', _('Only when I check'));
		o.value('notify', _('Check daily and show a notice'));
		o.value('auto', _('Install automatically at night'));
		o.default = 'notify';
		o.description = this.updateDescription();

		o = s.option(form.DummyValue, '_update_status');
		o.renderWidget = () => this.updateNode;

		const v = (st && st.versions) || {};

		return m.render().then(node => common.page(_('Settings'), null, [
			node,
			common.section(_('About'), null, [
				el('dl', { class: 'shv-kv' }, [
					el('dt', {}, [ 'Shadow' ]), el('dd', {}, [ common.versionText(v.shadow) ]),
					el('dt', {}, [ 'Xray' ]), el('dd', {}, [ v.xray ? _('%s (from the OpenWrt feed)').format(common.versionText(v.xray)) : '—' ]),
					el('dt', {}, [ 'OpenSSH' ]), el('dd', {}, [ common.versionText(v.openssh) ]),
					el('dt', {}, [ _('Update from the console') ]), el('dd', {}, [ el('span', { class: 'shv-mono' }, [ INSTALL ]) ])
				])
			])
		]));
	},

	/* A form description is markup: the router's clock goes in escaped. */
	updateDescription() {
		const clock = this.us && this.us.clock;
		const text = _('Except in “Only when I check”, the router asks GitHub for the latest Shadow release once a day. An automatic update starts between 03:00 and 06:00 router time, downloads only from the project’s GitHub releases, checks the files against SHA256SUMS, restarts the tunnel for a few seconds and puts the previous version back if the tunnel does not come back.');

		if (!clock)
			return text;

		return text + ' ' + _('Router time now: %s (%s).').format('%h'.format(clock.time), '%h'.format(clock.zone));
	},

	/* Update status */

	paintUpdate() {
		dom.content(this.updateNode, common.nodes([ this.renderUpdate() ]));
	},

	renderUpdate() {
		const u = this.us;
		const btn = (label, cls, handler, disabled) =>
			common.button(label, cls, handler, { type: 'button', disabled: disabled ? '' : null });

		if (!u)
			return el('div', { class: 'shv-row' }, [
				el('span', { class: 'shv-err', style: 'margin:0' }, [ _('Could not read the update status.') ]),
				btn(_('Retry'), null, () => this.refreshUpdate())
			]);

		// an install started here shows as running before the updater has written its run file
		const run = u.running || (this.installing ? { version: this.installing } : null);
		const kv = [];
		const row = (label, value) => kv.push(el('dt', {}, [ label ]), el('dd', {}, [ value ]));
		const out = [];

		row(_('Installed version'), common.versionText(u.installed));

		if (u.latest)
			row(_('Latest release'), [
				u.latest,
				u.published ? ' · ' + common.dateText(u.published) : null,
				u.url ? [ ' · ', el('a', { href: u.url, target: '_blank', rel: 'noopener noreferrer' }, [ _('Release notes') ]) ] : null
			]);
		else
			row(_('Latest release'), (u.checked_age == null) ? _('Not checked yet.', 'update') : '—');

		if (u.checked_age != null)
			row(_('Last check'), [
				common.agoAge(u.checked_age),
				(u.check_ok === false && u.check_error) ? el('div', { class: 'shv-err' }, [ common.tr(u.check_error) ]) : null
			]);

		// a run that found nothing newer changed nothing worth a row
		const last = u.last;

		if (last && !(last.ok && !last.changed))
			row(_('Last update'), [
				last.ok ? common.badge('ok', _('Updated', 'update')) : common.badge('bad', _('Failed', 'update')),
				' ',
				[
					(last.from && last.to) ? '%s → %s'.format(last.from, last.to) : (last.to || last.from),
					(last.age != null) ? common.agoAge(last.age) : null,
					last.auto ? _('automatically') : null,
					last.rolled_back ? _('previous version put back') : null
				].filter(Boolean).join(' · '),
				(!last.ok && last.error) ? el('div', { class: 'shv-err' }, [ common.tr(last.error) ]) : null
			]);

		out.push(el('dl', { class: 'shv-kv' }, kv));

		if (run)
			out.push(el('div', { class: 'shv-result shv-c-acc', style: 'margin-top:10px' }, [
				el('span', { class: 'spinning' }, [ run.version ? _('Installing Shadow %s…').format(run.version) : _('Installing an update…') ]),
				el('span', { class: 'shv-muted' }, [ stageText(run.stage) ])
			]));

		const a = u.auto;

		if (!run && a && a.stopped && a.version == u.latest && u.available)
			out.push(el('p', { class: 'shv-err' }, [
				_('Shadow stopped installing %s automatically after %d failed attempts. Update by hand or wait for the next release.')
					.format(a.version, a.tries)
			]));

		if (u.available && u.console)
			out.push(el('div', { style: 'margin-top:10px' }, [
				el('p', { style: 'margin:0 0 6px' }, [ _('Shadow %s must be installed with the install command from the console.').format(u.latest) ]),
				el('div', { class: 'shv-mono' }, [ INSTALL ])
			]));

		out.push(el('div', { class: 'shv-row', style: 'margin-top:10px' }, [
			btn(_('Check now'), null, () => this.checkUpdate(), !!run),
			(u.available && !u.console && !run)
				? btn(_('Update to %s').format(u.latest), 'cbi-button-apply', () => this.confirmUpdate(u.latest)) : null
		]));

		return out;
	},

	refreshUpdate() {
		return common.checked(common.api.updateStatus()).then(us => {
			this.us = us;
			this.paintUpdate();

			if (us.running)
				this.watchUpdate();
		}).catch(err => common.fail(err));
	},

	checkUpdate() {
		return common.runJob(common.api.updateCheck(), 150000)
			.catch(err => common.fail(err))
			.then(() => this.refreshUpdate());
	},

	confirmUpdate(version) {
		common.modal(_('Update Shadow?'), [
			el('p', {}, [ _('Shadow %s will be downloaded from GitHub and installed. The tunnel restarts for a few seconds and the page reloads.').format(version) ])
		], [
			common.closeButton(_('Cancel')),
			el('button', { class: 'btn cbi-button cbi-button-apply', click: () => {
				ui.hideModal();
				this.installUpdate(version);
			} }, [ _('Update to %s').format(version) ])
		]);
	},

	/* Like common.runJob, but a failed install still says whether it changed the packages: the views on the
	 * router are another version then, so the page reloads in both cases. */
	installUpdate(version) {
		const reload = () => window.setTimeout(() => location.reload(), 2000);
		const before = { installed: this.us ? this.us.installed : null, at: Date.now() };

		this.installing = version;
		this.startedHere = null;
		this.paintUpdate();
		this.watchUpdate();

		return common.checked(common.api.updateInstall())
			.then(res => res.job ? common.waitJob(res.job, 900000) : { state: 'done', result: res })
			.then(job => {
				const r = job.result || {};

				// apk add has no deadline, so the install can outlast the wait: the poll tells how it ends
				if (job.state == 'timeout') {
					this.startedHere = before;
					return common.notify(common.jobError(job));
				}

				if (r.ok === true && r.changed === false)
					return common.notify(_('Shadow is already up to date.'));

				if (r.ok === true && r.changed === true && r.to) {
					common.notify(_('Shadow was updated to %s.').format(r.to));
					return reload();
				}

				common.fail(r.error || _('The action failed. See the log for details.'));

				if (r.changed === true)
					reload();
			})
			.catch(err => common.fail(err))
			.finally(() => {
				// the poll shows the outcome: it outlasts an rpcd that is still restarting
				this.installing = null;
				this.watchUpdate();
			});
	},

	/* The end of an install started on this page that outlasted its wait: the installed version tells whether the
	 * packages changed (then the page reloads, as after any changed version); a failure of this run says why. */
	endedHere(us) {
		const started = this.startedHere;

		if (!started)
			return;

		this.startedHere = null;

		const changed = us.installed != started.installed;
		const last = us.last;
		const mine = last && last.age != null && last.age <= (Date.now() - started.at) / 1000 + 5;

		if (mine && !last.ok)
			common.fail(last.error || _('The action failed. See the log for details.'));
		else if (changed)
			common.notify(_('Shadow was updated to %s.').format(us.installed));

		if (changed)
			window.setTimeout(() => location.reload(), 2000);
	},

	/* One poll while an install runs, every 3 s. rpcd restarts while apk replaces the packages, so a failed
	 * call is only retried; an answer without a running install ends it. The node leaves the page for a
	 * moment while form.Map renders again after a Save, so only a second miss in a row stops the poll. */
	watchUpdate() {
		if (this.watching)
			return;

		let away = 0;

		const tick = () => {
			away = this.updateNode.isConnected ? 0 : away + 1;

			if (away > 1) {
				this.watching = false;
				return;
			}

			common.checked(common.api.updateStatus()).then(us => {
				this.us = us;
				this.paintUpdate();

				if (!us.running && !this.installing) {
					this.watching = false;
					this.endedHere(us);
					return;
				}

				window.setTimeout(tick, 3000);
			}).catch(() => window.setTimeout(tick, 3000));
		};

		this.watching = true;
		window.setTimeout(tick, 3000);
	}
});
