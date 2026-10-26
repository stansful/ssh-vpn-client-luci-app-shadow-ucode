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
