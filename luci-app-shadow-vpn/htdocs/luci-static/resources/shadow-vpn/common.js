'use strict';
'require baseclass';
'require rpc';
'require ui';

/* Shared pieces of the Shadow views: rpc calls, safe element helpers, formatting and the stylesheet. */

const CSS = `
.shv{--shv-accent:var(--proton-accent,var(--primary-color-high,var(--brand,#5e9eff)));--shv-ok:var(--proton-success,var(--success-color-high,var(--success,#2e9d5b)));--shv-bad:var(--proton-danger,var(--error-color-high,var(--danger,#d9534f)));--shv-warn:var(--proton-warning,var(--warn-color-high,var(--warning,#e0a030)));--shv-muted:var(--proton-fg-secondary,color-mix(in srgb,currentColor 62%,transparent));--shv-line:var(--proton-border,color-mix(in srgb,currentColor 14%,transparent));--shv-soft:var(--proton-bg-tertiary,color-mix(in srgb,currentColor 5%,transparent));--shv-r:var(--proton-radius,10px)}
.shv-muted{color:var(--shv-muted)}
.shv-mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.92em}
.shv-hero{display:flex;gap:20px;align-items:center;justify-content:space-between;flex-wrap:wrap;padding:6px 2px 14px}
.shv-hero-main{display:flex;gap:16px;align-items:flex-start;min-width:0;flex:1 1 380px}
.shv-dot{width:14px;height:14px;border-radius:50%;margin-top:7px;flex:none;background:var(--shv-c);box-shadow:0 0 0 5px color-mix(in srgb,var(--shv-c) 22%,transparent)}
.shv-dot.pulse{animation:shv-pulse 1.4s ease-in-out infinite}
@keyframes shv-pulse{50%{box-shadow:0 0 0 9px color-mix(in srgb,var(--shv-c) 8%,transparent)}}
.shv-state{font-size:1.5em;font-weight:650;line-height:1.25;color:var(--shv-c)}
.shv-detail{margin-top:4px;line-height:1.5;overflow-wrap:anywhere}
.shv-hero-actions{display:flex;gap:8px;flex-wrap:wrap}
.shv-big{min-width:150px;font-size:1.05em!important;padding:10px 22px!important}
/* summary tiles: three equal ones in a row when each gets 210px, otherwise one per row (never two plus one) */
.shv-grid{display:flex;flex-wrap:wrap;gap:12px}
.shv-grid>*{flex:1 1 calc((654px - 100%) * 999)}
.shv-tile{border:1px solid var(--shv-line);border-radius:var(--shv-r);padding:12px 14px;background:var(--shv-soft);min-width:0}
.shv-tile h5{margin:0 0 6px;font-size:.82em;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--shv-muted)}
.shv-tile .v{font-size:1.06em;font-weight:600;overflow-wrap:anywhere}
.shv-tile .s{margin-top:3px;font-size:.9em;color:var(--shv-muted)}
.shv-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
.shv-seg{display:inline-flex;border:1px solid var(--shv-line);border-radius:var(--shv-r);overflow:hidden}
.shv-seg button{border:0;background:transparent;color:inherit;padding:7px 16px;cursor:pointer;font:inherit}
.shv-seg button.on{background:var(--shv-accent);color:#fff;font-weight:600}
.shv-field{display:flex;flex-direction:column;gap:6px;min-width:0}
.shv-field>label{font-size:.85em;color:var(--shv-muted)}
.shv-pick{display:grid;grid-template-columns:auto minmax(0,1fr);gap:16px;align-items:end}
@media(max-width:700px){.shv-pick{grid-template-columns:1fr}}
.shv-badge{display:inline-flex;align-items:center;gap:5px;padding:2px 8px;border-radius:999px;font-size:.8em;font-weight:600;line-height:1.6;white-space:nowrap;color:var(--shv-c,var(--shv-muted));background:color-mix(in srgb,var(--shv-c,currentColor) 14%,transparent)}
.shv-c-ok{--shv-c:var(--shv-ok)}.shv-c-bad{--shv-c:var(--shv-bad)}.shv-c-warn{--shv-c:var(--shv-warn)}.shv-c-acc{--shv-c:var(--shv-accent)}.shv-c-off{--shv-c:var(--shv-muted)}
.shv-result{display:flex;gap:10px;align-items:baseline;padding:10px 12px;border-radius:var(--shv-r);background:var(--shv-soft);border:1px solid var(--shv-line);overflow-wrap:anywhere}
.shv-result b{color:var(--shv-c)}
.shv-banner{display:flex;gap:12px;align-items:flex-start;justify-content:space-between;flex-wrap:wrap}
.shv-banner p{margin:4px 0 0}
.shv-banner .shv-row{flex-wrap:nowrap}
.shv-table td,.shv-table th{vertical-align:middle}
.shv-table .shv-actions{text-align:right;white-space:nowrap}
.shv-name{font-weight:600;overflow-wrap:anywhere}
.shv-sub{font-size:.88em;color:var(--shv-muted);margin-top:2px;overflow-wrap:anywhere}
.shv-sel{display:inline-block;width:10px;height:10px;border-radius:50%;border:2px solid var(--shv-muted)}
.shv-sel.on{border-color:var(--shv-accent);background:var(--shv-accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--shv-accent) 25%,transparent)}
.shv-star{cursor:pointer;opacity:.35}.shv-star.on{opacity:1;color:var(--shv-warn)}
.shv-toolbar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:12px}
.shv-toolbar .grow{flex:1 1 220px}
.shv-toolbar input[type=search],.shv-toolbar input[type=text],.shv-toolbar select{width:100%;max-width:none}
.shv-table td.shv-grow{width:100%}
.shv-mode{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:12px}
.shv-card{border:1px solid var(--shv-line);border-radius:var(--shv-r);padding:14px 16px;cursor:pointer;background:var(--shv-soft);display:flex;gap:12px;align-items:flex-start}
.shv-card.on{border-color:var(--shv-accent);box-shadow:0 0 0 1px var(--shv-accent) inset}
.shv-card input{margin-top:4px}
.shv-card h4{margin:0 0 4px;font-size:1.02em}
.shv-card p{margin:0;color:var(--shv-muted);line-height:1.45}
.shv-list{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:6px 16px;align-items:center;padding:12px 0;border-bottom:1px solid var(--shv-line)}
.shv-list:last-child{border-bottom:0}
/* phone width: the auto column would take the controls' full width first and leave the title a sliver */
@media(max-width:600px){.shv-list{grid-template-columns:minmax(0,1fr)}.shv-table .shv-actions{white-space:normal}}
.shv-pickrow{display:flex;gap:10px;align-items:center}
.shv-pickrow>select{flex:1 1 auto;min-width:0}
.shv-pickrow>.cbi-button{flex:none}
.shv-switch{display:inline-flex;align-items:center;gap:8px;cursor:pointer;user-select:none}
.shv-switch input{display:none}
.shv-switch i{width:38px;height:22px;border-radius:999px;background:color-mix(in srgb,currentColor 22%,transparent);position:relative;transition:background .15s;flex:none}
.shv-switch i:after{content:"";position:absolute;top:3px;left:3px;width:16px;height:16px;border-radius:50%;background:#fff;transition:left .15s}
.shv-switch input:checked+i{background:var(--shv-accent)}
.shv-switch input:checked+i:after{left:19px}
.shv-switch input:disabled+i{opacity:.5}
.shv-tabs{display:flex;gap:4px;border-bottom:1px solid var(--shv-line);margin-bottom:12px;flex-wrap:wrap}
.shv-tabs a{padding:8px 14px;cursor:pointer;border-bottom:2px solid transparent;color:var(--shv-muted);text-decoration:none}
.shv-tabs a.on{border-color:var(--shv-accent);color:inherit;font-weight:600}
.shv-log{max-height:520px;overflow:auto;padding:12px;border-radius:var(--shv-r);background:var(--shv-soft);border:1px solid var(--shv-line);white-space:pre-wrap;word-break:break-word;line-height:1.55}
.shv-log .w{color:var(--shv-warn)}.shv-log .e{color:var(--shv-bad)}.shv-log .d{color:var(--shv-muted)}
.shv-empty{padding:22px;text-align:center;color:var(--shv-muted);border:1px dashed var(--shv-line);border-radius:var(--shv-r)}
.shv-kv{display:grid;grid-template-columns:max-content minmax(0,1fr);gap:6px 14px}
.shv-kv dt{color:var(--shv-muted)}.shv-kv dd{margin:0;overflow-wrap:anywhere}
.shv-err{color:var(--shv-bad);font-size:.9em;margin-top:6px;overflow-wrap:anywhere}
.shv-err:empty{display:none}
.shv-errors{margin:12px 0 0}
.shv-errors ul{margin:6px 0 0 18px}
`;

const OBJECT = 'luci.shadow-vpn';

function declare(method, params) {
	return rpc.declare({ object: OBJECT, method: method, params: params || [], expect: { '': {} }, reject: true });
}

const api = {
	status: declare('status'),
	setEnabled: declare('set_enabled', [ 'enabled' ]),
	select: declare('select', [ 'transport', 'sid' ]),
	settingsSet: declare('settings_set', [ 'values' ]),
	servers: declare('servers'),
	serverSave: declare('server_save', [ 'sid', 'values', 'password' ]),
	serverDelete: declare('server_delete', [ 'sid' ]),
	hostkeyPin: declare('hostkey_pin', [ 'sid', 'fingerprint' ]),
	hostkeyForget: declare('hostkey_forget', [ 'sid' ]),
	keys: declare('keys'),
	keySave: declare('key_save', [ 'sid', 'name', 'text', 'passphrase' ]),
	keyDelete: declare('key_delete', [ 'sid' ]),
	keyShow: declare('key_show', [ 'sid' ]),
	profiles: declare('profiles'),
	profilesImport: declare('profiles_import', [ 'text', 'source' ]),
	profileRename: declare('profile_rename', [ 'sid', 'name' ]),
	profilePin: declare('profile_pin', [ 'sid', 'pinned' ]),
	profileDelete: declare('profile_delete', [ 'sid' ]),
	profilesDeleteUnpinned: declare('profiles_delete_unpinned'),
	profileLink: declare('profile_link', [ 'sid' ]),
	lists: declare('lists'),
	listSet: declare('list_set', [ 'kind', 'enabled' ]),
	listRefresh: declare('list_refresh', [ 'kind' ]),
	listView: declare('list_view', [ 'kind' ]),
	rules: declare('rules'),
	ruleAdd: declare('rule_add', [ 'type', 'value' ]),
	ruleSet: declare('rule_set', [ 'sid', 'enabled' ]),
	ruleDelete: declare('rule_delete', [ 'sid' ]),
	rulesImport: declare('rules_import', [ 'text', 'apply' ]),
	rulesExport: declare('rules_export'),
	leases: declare('leases'),
	check: declare('check'),
	jobStatus: declare('job_status', [ 'id' ]),
	logs: declare('logs', [ 'lines' ]),
	logsClear: declare('logs_clear'),
	attentionDismiss: declare('attention_dismiss', [ 'id' ]),
	updateStatus: declare('update_status'),
	updateCheck: declare('update_check'),
	updateInstall: declare('update_install')
};

/*
 * E() stringifies nested arrays and sets innerHTML for a lone string child, so every
 * child goes through here: arrays are flattened, empty values dropped and text becomes a text node.
 */
function nodes(children) {
	const out = [];

	(function walk(c) {
		if (Array.isArray(c))
			c.forEach(walk);
		else if (c == null || c === false || c === '')
			return;
		else if (typeof(c) == 'object' && 'nodeType' in c)
			out.push(c);
		else
			out.push(document.createTextNode(String(c)));
	})(children);

	return out;
}

function el(tag, attrs, children) {
	return E(tag, attrs || {}, nodes(children));
}

/*
 * Backend messages are the desktop's English texts; the ones that carry values are matched here.
 * A third element lists the captures that are messages themselves and are translated too.
 */
const PATTERNS = [
	[ /^Reconnect attempt (\d+) failed: (.*)$/, 'Reconnect attempt %s failed: %s', [ 1 ] ],
	[ /^SSH session lost \((.*)\); reconnecting\.$/, 'SSH session lost (%s); reconnecting.', [ 0 ] ],
	[ /^(.*\.) Through the tunnel: (.*)$/, '%s Through the tunnel: %s', [ 0, 1 ] ],
	[ /^Unsupported proxy transport: (.+)\.$/, 'Unsupported proxy transport: %s.' ],
	[ /^Unsupported Hysteria 2 obfuscation: (.+)\. Only salamander works\.$/, 'Unsupported Hysteria 2 obfuscation: %s. Only salamander works.' ],
	[ /^Unsupported Hysteria 2 finalmask type: (.+)\.$/, 'Unsupported Hysteria 2 finalmask type: %s.' ],
	[ /^Unsupported finalmask type for mKCP: (.+)\.$/, 'Unsupported finalmask type for mKCP: %s.' ],
	[ /^Unsupported mKCP header type: (.+)\.$/, 'Unsupported mKCP header type: %s.' ],
	[ /^Invalid (\S+) URI\.$/, 'Invalid %s URI.' ],
	[ /^(\S+) URI must contain host and valid port\.$/, '%s URI must contain host and valid port.' ],
	[ /^Import text is longer than (\d+) characters\.$/, 'Import text is longer than %s characters.' ],
	[ /^Import contains (\d+) lines; maximum is (\d+)\. Extra lines were ignored\.$/, 'Import contains %s lines; maximum is %s. Extra lines were ignored.' ],
	[ /^proxy link is longer than (\d+) bytes\.$/, 'proxy link is longer than %s bytes.' ],
	[ /^Proxy link is longer than (\d+) characters\.$/, 'Proxy link is longer than %s characters.' ],
	[ /^Proxy profile count exceeds the (\d+) profile limit\.$/, 'Proxy profile count exceeds the %s profile limit.' ],
	[ /^CIDR prefix must be between 0 and (\d+)\.$/, 'CIDR prefix must be between 0 and %s.' ],
	[ /^Keepalive must be a whole number of seconds from (\d+) to (\d+)\.$/, 'Keepalive must be a whole number of seconds from %s to %s.' ],
	[ /^Routing rule count exceeds the (\d+) rule limit\.$/, 'Routing rule count exceeds the %s rule limit.' ],
	[ /^Routing import is larger than (\d+) bytes\.$/, 'Routing import is larger than %s bytes.' ],
	[ /^Routing import contains more than (\d+) rules\.$/, 'Routing import contains more than %s rules.' ],
	[ /^Domain proxy list is larger than (\d+) entries\.$/, 'Domain proxy list is larger than %s entries.' ],
	[ /^Routing list download failed \(uclient-fetch exit (\d+)\)\.$/, 'Routing list download failed (uclient-fetch exit %s).' ],
	[ /^(\d+) routing rule\(s\) are invalid and were skipped\.$/, '%s routing rule(s) are invalid and were skipped.' ],
	[ /^(\S+) is too long\.$/, '%s is too long.' ],
	[ /^(\S+) is required\.$/, '%s is required.' ],
	[ /^Connecting to (\S+)\.$/, 'Connecting to %s.' ],
	[ /^Reconnecting to (\S+) \(attempt (\d+)\)\.$/, 'Reconnecting to %s (attempt %s).' ],
	[ /^Starting (\S+) profile (.*)\.$/, 'Starting %s profile %s.' ],
	[ /^Xray rejected the configuration: (.*)$/, 'Xray rejected the configuration: %s' ],
	[ /^SSH TCP connect timeout for (\S+)\.$/, 'SSH TCP connect timeout for %s.' ],
	[ /^SSH keepalive timed out: nothing received from the server for (\d+) s\.$/, 'SSH keepalive timed out: nothing received from the server for %s s.' ],
	[ /^SSH server fingerprint mismatch: expected (\S+), got (\S+) \((\S+)\)\.$/, 'SSH server fingerprint mismatch: expected %s, got %s (%s).' ],
	[ /^SSH server host key does not match the key Shadow trusted on its first connection to (.*): expected (\S+), got (\S+) \((\S+)\)\. /,
		'SSH server host key does not match the key Shadow trusted on its first connection to %s: expected %s, got %s (%s). Shadow stopped so nothing is sent to a server that may be an impostor. If the server’s key was changed on purpose, paste the new fingerprint into the server’s Fingerprint field.' ],
	[ /^SSH authentication failed: Permission denied \((.*)\)\.$/, 'SSH authentication failed: Permission denied (%s).' ],
	[ /^Local SOCKS port (\S+) is already in use\.$/, 'Local SOCKS port %s is already in use.' ],
	[ /^SSH exited: (.*)$/, 'SSH exited: %s' ],
	[ /^In full mode some DNS lookups go to (.+) directly: remove them in Network → DHCP and DNS or turn off DNS through the tunnel in Settings\.$/,
		'In full mode some DNS lookups go to %s directly: remove them in Network → DHCP and DNS or turn off DNS through the tunnel in Settings.' ],
	[ /^In full mode DNS lookups sent to (.+) go through the tunnel, so they fail while it is down\. The VPN server name and the time servers go to (.+) instead\.$/,
		'In full mode DNS lookups sent to %s go through the tunnel, so they fail while it is down. The VPN server name and the time servers go to %s instead.' ],
	[ /^Port (\S+) is already in use by (.+)\.$/, 'Port %s is already in use by %s.' ],
	[ /^The firewall rejected Shadow's rules: (.*)$/, 'The firewall rejected Shadow\'s rules: %s' ],
	[ /^DNS configuration rejected: (.*)$/, 'DNS configuration rejected: %s' ],
	[ /^Could not write Shadow's DNS file into (.+)\.$/, 'Could not write Shadow\'s DNS file into %s.' ],
	[ /^Could not render (\S+)\.$/, 'Could not render %s.' ],
	[ /^Could not write (\S+)\.$/, 'Could not write %s.' ],
	[ /^Cannot write (\S+)\.$/, 'Cannot write %s.' ],
	[ /^Xray runtime was not found at (\S+)\.$/, 'Xray runtime was not found at %s.' ],
	[ /^Invalid (\S+) id: expected a UUID or up to 30 characters\.$/, 'Invalid %s id: expected a UUID or up to 30 characters.' ],
	[ /^Routing (\S+) list refresh returned no domains\.$/, 'Routing %s list refresh returned no domains.' ],
	[ /^Upstream SOCKS5 proxy refused (\S+) with code (\d+)\.$/, 'Upstream SOCKS5 proxy refused %s with code %s.' ],
	[ /^The tunnel opened a connection to (\S+) but nothing came back within \d+ ?s\. Traffic is entering the tunnel and not reaching the server\.$/,
		'The tunnel opened a connection to %s but nothing came back within 12 s. Traffic is entering the tunnel and not reaching the server.' ],
	// first: the hint ends another message, which is translated on its own
	[ /^(.+) The tunnel is down, and Shadow’s kill switch may be what blocks the download\.$/,
		'%s The tunnel is down, and Shadow’s kill switch may be what blocks the download.', [ 0 ] ],
	[ /^Not enough space on the router: (\d+) MB free, (\d+) MB needed\.$/, 'Not enough space on the router: %s MB free, %s MB needed.' ],
	[ /^Not enough free memory: (\d+) MB available, (\d+) MB needed\.$/, 'Not enough free memory: %s MB available, %s MB needed.' ],
	[ /^Could not download (.+) from GitHub\.$/, 'Could not download %s from GitHub.' ],
	[ /^The latest release has no (\S+)\.$/, 'The latest release has no %s.' ],
	[ /^SHA256SUMS has no entry for (\S+)\.$/, 'SHA256SUMS has no entry for %s.' ],
	[ /^The checksum of (.+) does not match SHA256SUMS: the file is damaged or was replaced\.$/,
		'The checksum of %s does not match SHA256SUMS: the file is damaged or was replaced.' ],
	[ /^The size of (.+) does not match the release\.$/, 'The size of %s does not match the release.' ],
	[ /^GitHub lists another checksum for (.+) than SHA256SUMS\.$/, 'GitHub lists another checksum for %s than SHA256SUMS.' ],
	[ /^Shadow (\S+) must be installed with the install command from the console\.$/, 'Shadow %s must be installed with the install command from the console.' ],
	[ /^The package manager could not install the update: (.*)$/, 'The package manager could not install the update: %s' ],
	[ /^The package manager did not install Shadow (\S+)\.$/, 'The package manager did not install Shadow %s.' ],
	[ /^Shadow (\S+) was installed, but the tunnel did not come back within (\d+) s\.$/,
		'Shadow %s was installed, but the tunnel did not come back within %s s.' ],
	[ /^Shadow (\S+) was installed, but the tunnel did not come back, so Shadow (\S+) was put back\.$/,
		'Shadow %s was installed, but the tunnel did not come back, so Shadow %s was put back.' ],
	[ /^Shadow (\S+) was installed, but the tunnel did not come back, and putting Shadow (\S+) back failed: (.*)$/,
		'Shadow %s was installed, but the tunnel did not come back, and putting Shadow %s back failed: %s', [ 2 ] ],
	[ /^The packages of the installed Shadow (\S+) could not be downloaded for a rollback, so it was not updated automatically\.$/,
		'The packages of the installed Shadow %s could not be downloaded for a rollback, so it was not updated automatically.' ],
	[ /^Shadow (\S+) is available\.$/, 'Shadow %s is available.' ],
	[ /^The automatic update to (\S+) failed: (.*)$/, 'The automatic update to %s failed: %s', [ 1 ] ],
	[ /^The automatic update to (\S+) was interrupted\.$/, 'The automatic update to %s was interrupted.' ],
	[ /^Connected to (.+)\.$/, 'Connected to %s.' ]
];

/* Field names inside "<Field> is required." are translated too. */
const FIELD_WORDS = { Name: 'Name', Host: 'Address', Username: 'User', Note: 'Note', Password: 'Password' };

function tr(message) {
	if (message == null || message === '')
		return '';

	const msg = String(message).trim();
	let m = /^Lines? (\d+): (.*)$/.exec(msg);

	if (m)
		return _('Line %d: %s').format(+m[1], tr(m[2]));

	const own = _(msg);

	if (own !== msg)
		return own;

	for (let i = 0; i < PATTERNS.length; i++) {
		const [ re, id, nested ] = PATTERNS[i];

		m = re.exec(msg);

		if (m) {
			const args = m.slice(1).map((a, n) => (nested && nested.indexOf(n) >= 0) ? tr(a) : (FIELD_WORDS[a] ? _(FIELD_WORDS[a]) : a));

			return _(id).format(...args);
		}
	}

	return msg;
}

function lang() {
	return document.documentElement.getAttribute('lang') || undefined;
}

function durationText(sec) {
	sec = Math.max(0, Math.floor(sec || 0));

	if (sec < 60)
		return _('%d s').format(sec);

	if (sec < 3600)
		return _('%d min').format(Math.floor(sec / 60));

	if (sec < 86400)
		return _('%d h %d min').format(Math.floor(sec / 3600), Math.floor(sec % 3600 / 60));

	return _('%d d %d h').format(Math.floor(sec / 86400), Math.floor(sec % 86400 / 3600));
}

function now() {
	return Math.floor(Date.now() / 1000);
}

function agoText(epoch) {
	return agoAge(now() - (epoch || 0));
}

/* An age in seconds the router worked out (status: age, check.age), free of the browser's clock. */
function agoAge(sec) {
	return (sec < 5) ? _('just now') : _('%s ago').format(durationText(sec));
}

function dateText(epoch) {
	if (!epoch)
		return _('never');

	const d = new Date(epoch * 1000);
	const time = d.toLocaleTimeString(lang(), { hour: '2-digit', minute: '2-digit' });

	if (d.toDateString() == new Date().toDateString())
		return _('today, %s').format(time);

	return '%s, %s'.format(d.toLocaleDateString(lang(), { day: '2-digit', month: '2-digit', year: 'numeric' }), time);
}

function sizeText(kb) {
	return _('%d MB').format(Math.round((kb || 0) / 1024));
}

function hostPort(host, port) {
	return (String(host).indexOf(':') >= 0) ? '[%s]:%s'.format(host, port) : '%s:%s'.format(host, port);
}

const PROTOCOLS = { vless: 'VLESS', vmess: 'VMess', trojan: 'Trojan', hysteria2: 'Hysteria 2' };
const TRANSPORTS = { tcp: 'TCP', ws: 'WS', grpc: 'gRPC', xhttp: 'XHTTP', mkcp: 'mKCP', httpupgrade: 'HTTPUpgrade', hysteria: 'Hysteria' };
const SECURITY = { tls: 'TLS', reality: 'REALITY' };

function protocolName(p) {
	return PROTOCOLS[p] || String(p || '').toUpperCase();
}

function transportName(t) {
	return (t == 'unknown') ? _('unknown') : (TRANSPORTS[t] || t || '');
}

function securityName(s) {
	if (s == 'none' || !s)
		return _('none', 'security');

	return (s == 'unknown') ? _('unknown') : (SECURITY[s] || s);
}

function flowName(f) {
	return (f || '').replace(/^xtls-rprx-/, '');
}

function versionText(v) {
	return v ? String(v).replace(/-r\d+$/, '').replace(/_p/, 'p') : '—';
}

function download(name, text, type) {
	const a = E('a', {
		href: URL.createObjectURL(new Blob([ text ], { type: type || 'text/plain' })),
		download: name,
		style: 'display:none'
	});

	document.body.appendChild(a);
	a.click();
	window.setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function readFile(file, max) {
	return new Promise((resolve, reject) => {
		if (file.size > max)
			return reject(new Error(_('The file is larger than %d KB.').format(Math.floor(max / 1024))));

		const r = new FileReader();
		r.onload = () => resolve(r.result);
		r.onerror = () => reject(r.error || new Error(_('Unable to read the file.')));
		r.readAsText(file);
	});
}

/*
 * The level of a logread line on the Log page: 'e', 'w', 'd' (debug) or '' (the rest). procd logs an
 * instance's stdout at daemon.info, so for xray the level is its own [Warning]/[Error]/... after the time, and
 * its "Failed to start: <reason>" (no time, no level; the reason of a crash loop) is an error.
 */
const LOG_LINE = /^\S+ \S+ +\d+ [\d:]+ \d+ [a-z0-9]+\.([a-z]+) ([^:\[ ]+)(?:\[\d+\])?: (?:\d{4}\/\d\d\/\d\d [\d:.]+ \[([A-Za-z]+)\] |(Failed to start: ))?/;

function logLevel(line) {
	const m = LOG_LINE.exec(line);
	const x = m && (m[2] == 'xray' || m[2] == 'xray-run');
	const p = !m ? 'info' : (x && m[4]) ? 'error' : (x && m[3]) ? m[3].toLowerCase() : m[1];

	if (p == 'error' || p == 'err' || p == 'crit' || p == 'alert' || p == 'emerg')
		return 'e';

	return (p == 'warn' || p == 'warning') ? 'w' : (p == 'debug') ? 'd' : '';
}

/* Whether a line of level c (logLevel) passes the Log page's filter lv: all, nodebug, warn, err. */
function logShown(c, lv) {
	return (lv == 'err') ? c == 'e' : (lv == 'warn') ? (c == 'e' || c == 'w') : (lv == 'nodebug') ? c != 'd' : true;
}

return baseclass.extend({
	api: api,
	el: el,
	nodes: nodes,
	tr: tr,
	now: now,
	durationText: durationText,
	agoText: agoText,
	agoAge: agoAge,
	dateText: dateText,
	sizeText: sizeText,
	hostPort: hostPort,
	protocolName: protocolName,
	transportName: transportName,
	securityName: securityName,
	flowName: flowName,
	versionText: versionText,
	download: download,
	readFile: readFile,
	logLevel: logLevel,
	logShown: logShown,

	style() {
		return E('style', {}, [ CSS ]);
	},

	page(title, desc, children) {
		return el('div', { class: 'shv' }, [
			this.style(),
			el('h2', { name: 'content' }, [ title ]),
			desc ? el('div', { class: 'cbi-map-descr' }, [ desc ]) : null,
			children
		]);
	},

	section(title, desc, children) {
		return el('div', { class: 'cbi-section' }, [
			title ? el('h3', {}, [ title ]) : null,
			desc ? el('div', { class: 'cbi-section-descr' }, [ desc ]) : null,
			el('div', { class: 'cbi-section-node' }, [ children ])
		]);
	},

	badge(c, text, title) {
		return el('span', { class: 'shv-badge shv-c-%s'.format(c), title: title || null }, [ text ]);
	},

	toggle(checked, onchange, label) {
		const input = E('input', { type: 'checkbox' });

		input.checked = !!checked;
		input.addEventListener('change', () => {
			input.disabled = true;
			Promise.resolve(onchange(input.checked)).then(ok => {
				if (ok === false)
					input.checked = !input.checked;
			}).finally(() => { input.disabled = false; });
		});

		return el('label', { class: 'shv-switch' }, [ input, E('i'), label ? el('span', {}, [ label ]) : null ]);
	},

	button(label, cls, handler, attrs) {
		return el('button', Object.assign({
			class: 'btn cbi-button' + (cls ? ' ' + cls : ''),
			click: ui.createHandlerFn(this, handler)
		}, attrs || {}), [ label ]);
	},

	modal(title, body, buttons) {
		const row = [];

		(buttons || []).forEach((b, i) => {
			if (i)
				row.push(' ');
			row.push(b);
		});

		return ui.showModal([ title ], nodes([ body, el('div', { class: 'right', style: 'margin-top:14px' }, row) ]));
	},

	closeButton(label) {
		return el('button', { class: 'btn cbi-button', click: ui.hideModal }, [ label || _('Close') ]);
	},

	notify(text, cls) {
		ui.addNotification(null, el('p', {}, [ text ]), cls || 'info');
	},

	fail(err) {
		const msg = (err && err.message) ? err.message : String(err);
		ui.addNotification(null, el('p', {}, [ tr(msg) ]), 'error');
	},

	/* A reply with { error } becomes a rejected promise with the translated message. */
	checked(promise) {
		return Promise.resolve(promise).then(res => {
			if (res && res.error)
				throw new Error(tr(res.error));

			return res;
		});
	},

	/* Polls job_status until the job leaves "running"; a job that never reports resolves as "timeout". */
	waitJob(id, timeoutMs) {
		const started = Date.now();
		const limit = timeoutMs || 120000;

		return new Promise(resolve => {
			const step = () => {
				api.jobStatus(id).then(job => {
					if (job && job.state && job.state != 'running')
						return resolve(job);

					if (Date.now() - started > limit)
						return resolve({ id: id, state: 'timeout', result: {} });

					window.setTimeout(step, 1000);
				}).catch(() => {
					if (Date.now() - started > limit)
						return resolve({ id: id, state: 'timeout', result: {} });

					window.setTimeout(step, 2000);
				});
			};

			window.setTimeout(step, 700);
		});
	},

	jobError(job) {
		if (!job || job.state == 'done')
			return null;

		if (job.state == 'timeout')
			return _('The action is still running in the background. Check the status in a moment.');

		const r = job.result || {};

		return tr(r.error || r.message) || _('The action failed. See the log for details.');
	},

	/* Starts a job-returning call, waits for it and rejects with the job's error. */
	runJob(promise, timeoutMs) {
		return this.checked(promise).then(res => {
			if (!res.job)
				return { state: 'done', result: res };

			return this.waitJob(res.job, timeoutMs).then(job => {
				const err = this.jobError(job);

				if (err)
					throw new Error(err);

				return job;
			});
		});
	},

	/* Calls fn on every LuCI poll tick while the browser tab is visible, and once when it becomes visible again. */
	pollVisible(poll, fn, interval) {
		poll.add(() => document.hidden ? Promise.resolve() : fn(), interval || 5);
		document.addEventListener('visibilitychange', () => {
			if (!document.hidden)
				fn();
		});
	}
});
