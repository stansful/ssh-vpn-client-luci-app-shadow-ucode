'use strict';

export const UCI = 'shadow-vpn';
export const ETC = '/etc/shadow-vpn', RUN = '/var/run/shadow-vpn', LOCK = '/var/lock/shadow-vpn.lock';
export const LIBEXEC = '/usr/libexec/shadow-vpn';
export const NFT_TABLE = 'shadow_vpn';
export const MARK_TPROXY = 0x00400000, MARK_XRAY = 0x00800000, RT_TABLE = 106, RT_PRIO = 106;
export const PORT_TPROXY = 12345, PORT_DNS = 5300, PORT_SSH = 12346, PORT_CHECK = 12347, PORT_METRICS = 12348;

// Two failed probes in a row mark the tunnel dead. xray spreads `sampling` probes at random over
// interval x sampling, so a drop is noticed in about 10 s (7 s when the server refuses at once),
// 23 s at worst. Keep DESIGN.md 6.7 and 14 in sync when tuning.
export const OBSERVATORY = { destination: 'http://www.gstatic.com/generate_204', interval: '5s', sampling: 2, timeout: '3s' };
export const XRAY_DOWN_FALLBACK_SEC = 10;   // fallback mode: gate=accept after xray has been down this long

export const LIST_URLS = {
	proxy: 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst',
	direct: 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-raw.lst'
};
// import_lines: what the profile cap can use (updates included); profiles_import parses inside rpcd,
// which serves nothing else meanwhile (about 1 s per 200 links on an A53)
export const LIMITS = { profiles: 1000, rules: 10000, list_domains: 20000, download_bytes: 2097152,
	import_chars: 2097152, import_lines: 2000, link_chars: 65536 };
export const SID_RE = /^[skpr]_[0-9a-f]{12}$/;   // s_ server, k_ key, p_ profile, r_ rule

// Updates from GitHub releases (DESIGN.md 11). Routers keep installing later releases with the updater of
// whatever version they run, so REPO, both URL shapes and the state files stay compatible forever.
export const REPO = 'stansful/ssh-vpn-client-luci-app-shadow-ucode';
export const APK_DB = '/lib/apk/db/installed';        // rpcd versions() and update.uc read it
export const UPDATE = {
	api: `https://api.github.com/repos/${REPO}/releases`,      // + '/latest' or '/tags/<tag>'
	download: `https://github.com/${REPO}/releases/download`,  // + '/<tag>/<file>': pinned to the checked release
	asset_api: `https://api.github.com/repos/${REPO}/releases/assets/`, // asset url = this + digits
	page: `https://github.com/${REPO}/releases/`,              // html_url kept only with this prefix
	state: `${RUN}/update.json`,          // tmpfs: last check, last install result, banner
	run: `${RUN}/update.run.json`,        // tmpfs: the install in progress
	work: `${RUN}/update.work`,           // tmpfs work dir (0700), removed before and after
	base_url: `${RUN}/update.base_url`,   // tmpfs test hook (lab): used when env SHADOW_BASE_URL is unset
	auto: `${ETC}/update.state`,          // flash: automatic attempts (survive reboots), written only on change
	lock: '/var/lock/shadow-vpn-update.lock',
	interval: 86400, retry: 10800, slack: 600,   // due: re-check after interval (ok) / retry (failed), minus slack
	window: [ 3, 6 ],                     // automatic installs start at local hours 3, 4, 5
	attempt_gap: 72000, max_tries: 3,     // one automatic attempt per version per night, at most 3 per version
	fetch_ms: 60000, total_ms: 300000, tries: 3, pause: 3, check_ms: 90000, // per attempt / all downloads / check budget
	json_max: 262144, file_max: 8388608,
	apk_update_ms: 300000,
	tunnel_wait: 15, settle: 90,          // seconds: first tunnel verdict (install.sh TUNNEL_WAIT) / tunnel back after install
	stable: 10,                           // seconds the tunnel must stay back (consecutive polls) within settle
	free_kb: 5120, mem_kb: 16384,         // install.sh NEED_FREE_UPGRADE_KB / NEED_MEM_UPGRADE_KB
	clock_floor: 1792886400,              // install.sh CLOCK_FLOOR
	notes_max: 4000
};

export const LOG_TAG = 'shadow-vpn';
export const XRAY_BIN = '/usr/bin/xray';
export const XRAY_ENV = { GOGC: '50', GOMEMLIMIT: '48MiB' };
export const DOH_SERVER = 'https://1.1.1.1/dns-query';
export const CHECK_TIMEOUT_MS = 12000;
export const CHECK_ENDPOINT = 'youtube.com:443';

// Targets xray must never dial for a sniffed name that turned out to be an address literal.
export const PRIVATE_NETS = [ '0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8', '169.254.0.0/16',
	'172.16.0.0/12', '192.168.0.0/16', '::1/128', 'fc00::/7', 'fe80::/10' ];

export const DNSMASQ_CONF = 'shadow-vpn.conf';           // inside the instance confdir, read at start only
export const DNSMASQ_SERVERS_OLD = '.shadow-vpn.servers'; // the servers-file of earlier builds, removed on sight
