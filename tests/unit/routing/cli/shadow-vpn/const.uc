'use strict';

// CLI test stand-in for const.uc: every path under /tmp/shv-routing-cli, the lists served by the test's
// uhttpd. Put first on the module path only by suite.uc when it runs the lists CLI.

const BASE = '/tmp/shv-routing-cli';

export const UCI = 'shadow-vpn';
export const ETC = `${BASE}/etc`, RUN = `${BASE}/run`, LOCK = `${BASE}/lock`;
export const LIBEXEC = `${BASE}/libexec`;
export const NFT_TABLE = 'shadow_vpn';
export const MARK_TPROXY = 0x00400000, MARK_XRAY = 0x00800000, RT_TABLE = 106, RT_PRIO = 106;
export const PORT_TPROXY = 12345, PORT_DNS = 5300, PORT_SSH = 12346, PORT_CHECK = 12347, PORT_METRICS = 12348;
export const LIST_URLS = {
	proxy: 'http://127.0.0.1:18781/proxy.lst',
	direct: 'http://127.0.0.1:18781/direct.lst'
};
export const LIMITS = { profiles: 1000, rules: 10000, list_domains: 20000, download_bytes: 2097152,
	import_chars: 2097152, import_lines: 10000, link_chars: 65536 };
export const SID_RE = /^[skpr]_[0-9a-f]{12}$/;
