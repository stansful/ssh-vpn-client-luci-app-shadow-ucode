'use strict';
'require view';
'require dom';
'require poll';
'require shadow-vpn.common as common';

const el = common.el;
const level = common.logLevel;
const LINES = 1000;

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load() {
		return common.api.logs(LINES);
	},

	render(data) {
		this.lines = data.lines || [];
		this.follow = true;
		// Follow keeps the newest line in view until the user scrolls up; it is decided by the user's own
		// scrolling, as a box that is not on the page yet (the first draw) has no height to measure
		this.stick = true;
		this.unavailable = false;
		this.box = el('div', { class: 'shv-log shv-mono', scroll: () => {
			if (this.box.isConnected && this.box.clientHeight)
				this.stick = this.box.scrollHeight - this.box.scrollTop - this.box.clientHeight < 40;
		} });
		this.level = el('select', { class: 'cbi-input-select', change: () => this.draw() }, [
			[ 'all', _('All events') ], [ 'nodebug', _('All but debug') ], [ 'warn', _('Warnings and errors') ],
			[ 'err', _('Errors only') ]
		].map(o => el('option', { value: o[0] }, [ o[1] ])));
		this.search = el('input', { type: 'search', class: 'cbi-input-text', placeholder: _('Filter'), input: () => this.draw() });

		this.draw();
		common.pollVisible(poll, () => this.follow ? this.poll() : Promise.resolve(), 5);

		return common.page(_('Logs'), _('Shadow, Xray and SSH events from the system log. Passwords, keys and links never get here.'), [
			common.section(null, null, [
				el('div', { class: 'shv-toolbar' }, [
					this.level,
					common.button(_('Refresh'), null, () => this.refresh().catch(err => common.fail(err))),
					common.button(_('Download'), null, () => this.save()),
					common.button(_('Clear', 'log'), null, () => this.clear().catch(err => common.fail(err)), {
						title: _('Hide the lines logged so far, here and in every browser. The system log keeps them.')
					}),
					el('div', { class: 'grow' }, [ this.search ]),
					common.toggle(true, on => {
					this.follow = on;

					if (on) {
						this.stick = true;
						return this.poll();
					}
				}, _('Follow', 'log'))
				]),
				this.box
			])
		]);
	},

	refresh() {
		return common.api.logs(LINES).then(res => {
			this.lines = res.lines || [];
			this.unavailable = false;
			this.draw();
		});
	},

	/* The router puts a mark into the log; the page shows only what comes after it. */
	clear() {
		return common.checked(common.api.logsClear()).then(() => {
			this.stick = true;
			return this.refresh();
		});
	},

	/* The 5 s poll: while the router does not answer (a reboot, an rpcd restart) one notification, not one
	 * per poll; the next answer clears the flag. */
	poll() {
		return this.refresh().catch(err => {
			if (!this.unavailable)
				common.fail(err);

			this.unavailable = true;
		});
	},

	shown() {
		const lv = this.level.value;
		const q = this.search.value.trim().toLowerCase();

		return this.lines.filter(l => common.logShown(level(l), lv) && (!q || l.toLowerCase().indexOf(q) >= 0));
	},

	draw() {
		const lines = this.shown();

		dom.content(this.box, lines.length
			? lines.map(l => el('div', { class: level(l) }, [ l ]))
			: [ el('span', { class: 'shv-muted' }, [ _('No log content.') ]) ]);

		if (this.follow && this.stick)
			this.toEnd();
	},

	/* The newest line is the last one; on the first draw the box gets its height only once LuCI has put the
	 * view on the page. */
	toEnd() {
		if (this.box.isConnected) {
			this.box.scrollTop = this.box.scrollHeight;
			return;
		}

		window.requestAnimationFrame(() => {
			if (this.box.isConnected)
				this.box.scrollTop = this.box.scrollHeight;
			else
				window.setTimeout(() => { this.box.scrollTop = this.box.scrollHeight; }, 100);
		});
	},

	save() {
		common.download('shadow-vpn.log', this.shown().join('\n') + '\n');
	}
});
