'use strict';

// Test stand-in for CONTRACTS §2, used only when the package has no const.uc yet (it comes later on
// the -L path than the package tree).

export const UCI = 'shadow-vpn';
export const ETC = '/etc/shadow-vpn', RUN = '/var/run/shadow-vpn', LOCK = '/var/lock/shadow-vpn.lock';
export const LIBEXEC = '/usr/libexec/shadow-vpn';
export const NFT_TABLE = 'shadow_vpn';
export const MARK_TPROXY = 0x00400000, MARK_XRAY = 0x00800000, RT_TABLE = 106, RT_PRIO = 106;
export const PORT_TPROXY = 12345, PORT_DNS = 5300, PORT_SSH = 12346, PORT_CHECK = 12347, PORT_METRICS = 12348;
export const LIST_URLS = {
	proxy: 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst',
	direct: 'https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-raw.lst'
};
export const LIMITS = { profiles: 1000, rules: 10000, list_domains: 20000, download_bytes: 2097152,
	import_chars: 2097152, import_lines: 10000, link_chars: 65536 };
export const SID_RE = /^[skpr]_[0-9a-f]{12}$/;
