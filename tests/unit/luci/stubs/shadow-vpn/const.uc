'use strict';

// Test stand-in for shadow-vpn.const (CONTRACTS §2); paths point into a scratch root.
export const UCI = 'shadow-vpn';
export const ETC = '/tmp/shv-luci/etc', RUN = '/tmp/shv-luci/run', LOCK = '/tmp/shv-luci/lock';
export const LIBEXEC = '/tmp/shv-luci/libexec';
export const NFT_TABLE = 'shadow_vpn';
export const PORT_TPROXY = 12345, PORT_DNS = 5300, PORT_SSH = 12346, PORT_CHECK = 12347, PORT_METRICS = 12348;
export const LIMITS = { profiles: 1000, rules: 10000, list_domains: 20000, download_bytes: 2097152,
	import_chars: 2097152, import_lines: 2000, link_chars: 65536 };
export const SID_RE = /^[skpr]_[0-9a-f]{12}$/;
export const REPO = 'stansful/ssh-vpn-client-luci-app-shadow-ucode';
export const APK_DB = '/tmp/shv-luci/apk-installed';
export const UPDATE = {
	api: `https://api.github.com/repos/${REPO}/releases`,
	download: `https://github.com/${REPO}/releases/download`,
	asset_api: `https://api.github.com/repos/${REPO}/releases/assets/`,
	page: `https://github.com/${REPO}/releases/`,
	state: `${RUN}/update.json`, run: `${RUN}/update.run.json`, work: `${RUN}/update.work`,
	base_url: `${RUN}/update.base_url`, auto: `${ETC}/update.state`, lock: '/tmp/shv-luci/update.lock',
	interval: 86400, retry: 10800, slack: 600, window: [ 3, 6 ], attempt_gap: 72000, max_tries: 3,
	fetch_ms: 60000, total_ms: 300000, tries: 3, pause: 3, check_ms: 90000, json_max: 262144, file_max: 8388608,
	apk_update_ms: 300000, tunnel_wait: 15, settle: 90, stable: 10, free_kb: 5120, mem_kb: 16384, clock_floor: 1792886400,
	notes_max: 4000
};
