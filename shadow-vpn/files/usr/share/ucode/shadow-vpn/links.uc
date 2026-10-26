'use strict';

// Share links (vless://, vmess://, trojan://, hysteria2:// and hy2://) to profiles and xray outbounds.
// A port of the desktop's src/core/proxy/{share-link-parser,share-link-fields,hysteria2-link,
// xray-config}.ts with the same normalisation, errors and fingerprint, checked against the
// desktop's own output (tests/unit/vectors/links.json). Links are read the way the desktop reads
// them, so the parts of WHATWG URL, URLSearchParams, decodeURIComponent, Buffer base64, JSON,
// String#trim and String#localeCompare that the result depends on are reproduced here.
//
// On top of the desktop, malformed credentials are rejected before anything is rendered, so
// `xray run -test` never has a reason to print them (DESIGN §5).

import { sha256 } from 'digest';
import { LIMITS } from 'shadow-vpn.const';

const UNSUPPORTED_SCHEME_MESSAGE = 'Only vless://, vmess://, trojan://, and hysteria2:// links are supported.';
const VMESS_JSON_MESSAGE = 'Invalid VMess base64 JSON payload.';
const VMESS_ADDRESS_MESSAGE = 'VMess payload must contain add and valid port.';
const HY2_INVALID_MESSAGE = 'Invalid Hysteria 2 link.';
const HY2_HOST_MESSAGE = 'Hysteria 2 link must contain a server host.';
const HY2_PORTS_MESSAGE = 'Hysteria 2 link has an invalid port list.';
const HY2_OBFS_PASSWORD_MESSAGE = 'Hysteria 2 salamander obfuscation needs obfs-password.';
const HY2_PIN_MESSAGE = 'Invalid Hysteria 2 pinSHA256: expected a SHA-256 certificate hash.';
const TLS_PIN_MESSAGE = 'Invalid pcs: expected a SHA-256 certificate hash.';
const HY2_FINALMASK_MESSAGE = 'Invalid Hysteria 2 fm parameter: expected finalmask JSON.';
const HY2_ECH_MESSAGE = 'Invalid Hysteria 2 ech: expected a base64 ECHConfigList.';
const HY2_PASSWORD_MESSAGE = 'Hysteria 2 link must contain a password.';
const TROJAN_PASSWORD_MESSAGE = 'Trojan link must contain a password.';
const TROJAN_PASSWORD_ENCODING_MESSAGE = 'Invalid Trojan password: expected percent-encoded UTF-8.';
const REALITY_KEY_MESSAGE = 'Invalid REALITY public key (pbk): expected 43 base64url characters.';
const REALITY_SHORT_ID_MESSAGE = 'Invalid REALITY short id (sid): expected up to 8 bytes in hex.';
const MKCP_FINALMASK_MESSAGE = 'Invalid fm parameter: expected finalmask JSON.';
const VLESS_ENCRYPTION_MESSAGE = 'Unsupported VLESS encryption. Ask your provider for a current link.';
// Router limits (not in the desktop): a host no DNS name can have would be dropped by config.load, and
// both it and thousands of parameters cost seconds of the single rpcd process per link.
const HOST_LENGTH_MESSAGE = 'Proxy server address is longer than 253 characters.';
const PARAMS_MESSAGE = 'Proxy link has more than 128 parameters.';
const MAX_QUERY_PARAMS = 128;
const MAX_HOST_INPUT = 4096;              // bytes of a host as written, before IDNA mapping

const OUTBOUND_TAG = 'proxy';
const MAX_PROFILE_NAME = 64;
const MAX_SAFE_INTEGER = 9007199254740991;

const HY2_DEFAULT_PORT = 443;
const HY2_DEFAULT_HOP_INTERVAL = 30;
const HY2_MIN_HOP_INTERVAL = 5;           // xray refuses shorter hop intervals
const HY2_MAX_HOST = 253;
const HY2_MAX_HOP_RANGES = 64;            // xray expands every range port by port
const HY2_MAX_SCALAR = 128;               // longest rate, interval or pin worth reading
const HY2_MIN_BRUTAL_BPS = 65536 * 8;     // xray rejects slower brutal rates
const CONGESTION_CONTROLS = [ 'reno', 'bbr', 'brutal', 'force-brutal' ];

const DECIMAL_BANDWIDTH = { '': 1e6, b: 1, bps: 1, k: 1e3, kb: 1e3, kbps: 1e3, m: 1e6, mb: 1e6, mbps: 1e6,
	g: 1e9, gb: 1e9, gbps: 1e9, t: 1e12, tb: 1e12, tbps: 1e12 };
const BINARY_BANDWIDTH = { '': 1, b: 1, bps: 1, k: 1024, kb: 1024, kbps: 1024, m: 1048576, mb: 1048576,
	mbps: 1048576, g: 1073741824, gb: 1073741824, gbps: 1073741824, t: 1099511627776, tb: 1099511627776,
	tbps: 1099511627776 };

const MKCP_HEADERS = [ 'dns', 'dtls', 'srtp', 'utp', 'wechat', 'wireguard' ];

// Every TLS `fingerprint` xray 26.3.27 accepts (compared without case); any other value makes it
// refuse the whole config, so such a value is left out, as on the desktop.
const XRAY_TLS_FINGERPRINTS = [
	'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq', 'random', 'randomized',
	'randomizednoalpn', 'unsafe', 'hellogolang', 'hellorandomized', 'hellorandomizedalpn',
	'hellorandomizednoalpn', 'hellofirefox_auto', 'hellofirefox_55', 'hellofirefox_56', 'hellofirefox_63',
	'hellofirefox_65', 'hellofirefox_99', 'hellofirefox_102', 'hellofirefox_105', 'hellofirefox_120',
	'hellochrome_auto', 'hellochrome_58', 'hellochrome_62', 'hellochrome_70', 'hellochrome_72',
	'hellochrome_83', 'hellochrome_87', 'hellochrome_96', 'hellochrome_100', 'hellochrome_102',
	'hellochrome_106_shuffle', 'hellochrome_120', 'hellochrome_131', 'hellochrome_100_psk',
	'hellochrome_112_psk_shuf', 'hellochrome_114_padding_psk_shuf', 'hellochrome_115_pq',
	'hellochrome_115_pq_psk', 'hellochrome_120_pq', 'helloios_auto', 'helloios_11_1', 'helloios_12_1',
	'helloios_13', 'helloios_14', 'helloandroid_11_okhttp', 'helloedge_auto', 'helloedge_85',
	'helloedge_106', 'hellosafari_auto', 'hellosafari_16_0', 'hello360_auto', 'hello360_7_5',
	'hello360_11_0', 'helloqq_auto', 'helloqq_11_1'
];

const REPLACEMENT_CHAR = '\xef\xbf\xbd';

// The multi-byte characters String#trim treats as whitespace (U+1680, U+2000-200A, U+2028, U+2029,
// U+202F, U+205F, U+3000, U+FEFF); U+00A0 is checked on its own.
const JS_SPACES_3 = [ '\xe1\x9a\x80', '\xe2\x80\x80', '\xe2\x80\x81', '\xe2\x80\x82', '\xe2\x80\x83',
	'\xe2\x80\x84', '\xe2\x80\x85', '\xe2\x80\x86', '\xe2\x80\x87', '\xe2\x80\x88', '\xe2\x80\x89',
	'\xe2\x80\x8a', '\xe2\x80\xa8', '\xe2\x80\xa9', '\xe2\x80\xaf', '\xe2\x81\x9f', '\xe3\x80\x80',
	'\xef\xbb\xbf' ];

// WHATWG URL percent-encode sets on top of C0 controls and non-ASCII.
const USERINFO_SET = ' "#<>?`{}/:;=@[\\]^|';
const FRAGMENT_SET = ' "<>`';

const B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const B64_VALUE = (() => {
	let v = {};

	for (let i = 0; i < 64; i++)
		v[ord(B64_ALPHABET, i)] = i;

	v[ord('-', 0)] = 62;
	v[ord('_', 0)] = 63;

	return v;
})();

// String#localeCompare (ICU root collation). ASCII: controls are ignorable, then whitespace,
// punctuation, symbols, digits and letters in this order; case only breaks ties (lower first).
const COLLATION_ORDER = "\t\n\x0b\x0c\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789abcdefghijklmnopqrstuvwxyz";
const COLLATION_WEIGHT = (() => {
	let w = {};

	for (let i = 0; i < length(COLLATION_ORDER); i++)
		w[ord(COLLATION_ORDER, i)] = (i + 1) * 100;

	return w;
})();

// Latin-1 and Latin Extended-A letters (U+00C0-U+017F) as ICU sorts them: the base letter (an
// accent or stroke is a secondary difference), two letters for a ligature, "x+" for a letter of
// its own right after x, "*" for the two symbols in the range.
const LATIN_BASES = split(
	'a a a a a a ae c e e e e i i i i d n o o o o o * o u u u u y z+ ss ' +
	'a a a a a a ae c e e e e i i i i d n o o o o o * o u u u u y z+ y ' +
	'a a a a a a c c c c c c c c d d d d e e e e e e e e e e g g g g ' +
	'g g g g h h h h i i i i i i i i i i+ ij ij j j k k q+ l l l l l l l ' +
	'l l l n n n n n n z+ n+ n+ o o o o o o oe oe r r r r r r s s s s s s ' +
	's s t t t t t+ t+ u u u u u u u u u u u u w w y y y z z z z z z s', ' ');

// Patterns used in functions, compiled once: ucode compiles a regex literal on every evaluation.
const NOT_PLAIN_RE = /[^\t\n\r -~]/;
const NON_ASCII_RE = /[^[:print:][:cntrl:]]/;
const SPACES_G = /[[:space:]]+/g;
const PCT_BYTE_G = /%([0-9A-Fa-f][0-9A-Fa-f])/g;
const PCT_ESCAPES_G = /%[0-9A-Fa-f][0-9A-Fa-f]/g;
const PCT_ESCAPE_RE = /%[0-9A-Fa-f][0-9A-Fa-f]/;
const URL_SAFE_RE = /^[A-Za-z0-9._~!$&'()*+,%-]*$/;
const EXP_TEXT_RE = /^([0-9])(\.([0-9]+))?e([+-][0-9]+)$/;
const TRAILING_ZEROS_RE = /0+$/;
const JS_DECIMAL_RE = /^([+-]?)(Infinity|[0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$/;
const JS_HEX_RE = /^0[xX][0-9a-fA-F]+$/;
const JS_OCTAL_RE = /^0[oO][0-7]+$/;
const JS_BINARY_RE = /^0[bB][01]+$/;
const HEX4_RE = /^[0-9A-Fa-f]{4}$/;
const JSON_NUMBER_RE = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/;
const JSON_ESCAPE_RE = /["\\[:cntrl:]]/;
const INDEX_KEY_RE = /^[1-9][0-9]{0,9}$/;
const HEX_DIGITS_RE = /^[0-9A-Fa-f]+$/;
const OCTAL_DIGITS_RE = /^[0-7]+$/;
const DIGITS_RE = /^[0-9]+$/;
const LEADING_ZEROS_RE = /^0+/;
const TAB_NEWLINE_G = /[\t\n\r]/g;
const BAD_DOMAIN_CHAR_RE = /[] #%\/:<>?@[\\^|[:cntrl:]]/;
const BAD_HOST_CHAR_RE = /[] #\/:<>?@[\\^|\t\n\r]/;
const PRINTABLE_ASCII_RE = /^[!-~]+$/;
const PLUS_G = /\+/g;
const SCHEME_RE = /^([A-Za-z][A-Za-z0-9+.-]*):\/\//;
const REALITY_KEY_RE = /^[A-Za-z0-9_-]{43}$/;
const SHORT_ID_RE = /^([0-9A-Fa-f][0-9A-Fa-f]){0,8}$/;
const BASE64URL_RE = /^[A-Za-z0-9_-]+$/;
const OPTIONAL_DIGITS_RE = /^[0-9]*$/;
const COLON_RANGE_G = /([0-9])[[:space:]]*:[[:space:]]*([0-9])/g;
const PORT_ITEM_RE = /^([0-9]{1,5})([[:space:]]*-[[:space:]]*([0-9]{1,5}))?$/;
const SECONDS_RE = /^[0-9]{1,6}$/;
const SECONDS_RANGE_RE = /^([0-9]{1,6})[sS]?-([0-9]{1,6})[sS]?$/;
const HYSTERIA_RATE_RE = /^([0-9]+(\.[0-9]+)?)[[:space:]]*([A-Za-z]*)$/;
const XRAY_RATE_RE = /^([0-9]+(\.[0-9]+)?)[[:space:]]*([a-z]*)$/;
const PADDING_RE = /=+$/;
const BASE64_RE = /^[A-Za-z0-9+\/_-]*$/;
const HEX_SEPARATORS_G = /[:-]/g;
const SHA256_HEX_RE = /^[0-9A-Fa-f]{64}$/;
const VERSION_RE = /([0-9]+)\.([0-9]+)\.([0-9]+)/;
const PORT_DIGITS_RE = /^[0-9]{1,5}$/;

// die() cuts its message at a NUL byte, and messages repeat link text, so the message travels
// beside the exception.
let failure = null;

function fail(message) {
	failure = message;
	die('link error');
}

function caught(e) {
	let message = failure ?? e.message;

	failure = null;

	return message;
}

// ---- Bytes and text -------------------------------------------------------------------------

function has_nul(s) {
	return index(s, '\0') >= 0;
}

// match() stops at a NUL byte, so a value that carries one never matches.
function rx(s, re) {
	return (type(s) == 'string' && !has_nul(s)) ? match(s, re) : null;
}

function plain_ascii(s) {
	return !has_nul(s) && !match(s, NOT_PLAIN_RE);
}

function has_any(s, chars) {
	for (let i = 0; i < length(chars); i++)
		if (index(s, substr(chars, i, 1)) >= 0)
			return true;

	return false;
}

function has_non_ascii(s) {
	for (let piece in split(s, '\0'))
		if (match(piece, NON_ASCII_RE))
			return true;

	return false;
}

// Length of the well-formed UTF-8 sequence at byte i; when it is broken, minus the number of bytes
// the WHATWG decoder replaces with one U+FFFD.
function utf8_seq(s, i) {
	let c = ord(s, i), need = 0, lo = 0x80, hi = 0xbf;

	if (c < 0x80)
		return 1;
	else if (c >= 0xc2 && c <= 0xdf)
		need = 1;
	else if (c >= 0xe0 && c <= 0xef) {
		need = 2;
		if (c == 0xe0) lo = 0xa0;
		else if (c == 0xed) hi = 0x9f;
	}
	else if (c >= 0xf0 && c <= 0xf4) {
		need = 3;
		if (c == 0xf0) lo = 0x90;
		else if (c == 0xf4) hi = 0x8f;
	}
	else
		return -1;

	for (let j = 1; j <= need; j++) {
		let cc = ord(s, i + j);

		if (cc == null || cc < lo || cc > hi)
			return -j;

		lo = 0x80;
		hi = 0xbf;
	}

	return need + 1;
}

function utf8_cp(s, i, len) {
	let c = ord(s, i);

	if (len == 2)
		return ((c & 0x1f) << 6) | (ord(s, i + 1) & 0x3f);
	if (len == 3)
		return ((c & 0x0f) << 12) | ((ord(s, i + 1) & 0x3f) << 6) | (ord(s, i + 2) & 0x3f);
	if (len == 4)
		return ((c & 0x07) << 18) | ((ord(s, i + 1) & 0x3f) << 12) | ((ord(s, i + 2) & 0x3f) << 6) | (ord(s, i + 3) & 0x3f);

	return c;
}

function utf8_valid(s) {
	if (plain_ascii(s))
		return true;

	for (let i = 0, n = length(s); i < n; ) {
		let k = utf8_seq(s, i);

		if (k < 0)
			return false;

		i += k;
	}

	return true;
}

// Broken sequences become U+FFFD, as Buffer#toString('utf8') and URLSearchParams decode them.
function utf8_fix(s) {
	if (plain_ascii(s))
		return s;

	let out = [], start = 0, n = length(s);

	for (let i = 0; i < n; ) {
		let k = utf8_seq(s, i);

		if (k > 0) {
			i += k;
			continue;
		}

		push(out, substr(s, start, i - start), REPLACEMENT_CHAR);
		i -= k;
		start = i;
	}

	if (!length(out))
		return s;

	push(out, substr(s, start));

	return join('', out);
}

// Code points of a well-formed string (null for a broken one).
function code_points(s) {
	let cps = [];

	for (let i = 0, n = length(s); i < n; ) {
		let k = utf8_seq(s, i);

		if (k < 0)
			return null;

		push(cps, utf8_cp(s, i, k));
		i += k;
	}

	return cps;
}

function from_code_points(cps) {
	let out = [];

	for (let c in cps)
		push(out, uchr(c));

	return join('', out);
}

// String#length: UTF-16 code units.
function js_length(s) {
	if (plain_ascii(s))
		return length(s);

	let n = 0;

	for (let i = 0; i < length(s); i++) {
		let c = ord(s, i);

		if ((c & 0xc0) != 0x80)
			n += (c >= 0xf0) ? 2 : 1;
	}

	return n;
}

function js_space_len(s, i) {
	let c = ord(s, i);

	if (c == 0x20 || (c >= 0x09 && c <= 0x0d))
		return 1;
	if (c == 0xc2)
		return (ord(s, i + 1) == 0xa0) ? 2 : 0;
	if (c == 0xe1 || c == 0xe2 || c == 0xe3 || c == 0xef)
		return (index(JS_SPACES_3, substr(s, i, 3)) >= 0) ? 3 : 0;

	return 0;
}

function js_trim_end(s) {
	let e = length(s);

	while (e > 0) {
		if (js_space_len(s, e - 1) == 1)
			e -= 1;
		else if (e >= 2 && js_space_len(s, e - 2) == 2)
			e -= 2;
		else if (e >= 3 && js_space_len(s, e - 3) == 3)
			e -= 3;
		else
			break;
	}

	return substr(s, 0, e);
}

// String#trim, Unicode spaces included.
function js_trim(s) {
	if (type(s) != 'string')
		return '';

	let i = 0, n = length(s), k;

	while (i < n && (k = js_space_len(s, i)) > 0)
		i += k;

	return js_trim_end(substr(s, i));
}

// s.replace(/\s+/g, '').
function remove_js_spaces(s) {
	if (plain_ascii(s))
		return replace(s, SPACES_G, '');

	let out = [];

	for (let i = 0, n = length(s); i < n; ) {
		let k = js_space_len(s, i);

		if (k > 0) {
			i += k;
			continue;
		}

		push(out, substr(s, i, 1));
		i++;
	}

	return join('', out);
}

function has_js_space(s) {
	for (let i = 0; i < length(s); i++)
		if (js_space_len(s, i) > 0)
			return true;

	return false;
}

// String#toLowerCase for the scripts share links use (ASCII, Latin, Greek, Cyrillic, Armenian).
function cp_lower(c) {
	if (c < 0x80)
		return (c >= 0x41 && c <= 0x5a) ? c + 32 : c;
	if ((c >= 0xc0 && c <= 0xde && c != 0xd7) || (c >= 0x391 && c <= 0x3ab && c != 0x3a2) || (c >= 0x410 && c <= 0x42f))
		return c + 32;
	if (c >= 0x400 && c <= 0x40f)
		return c + 80;
	if (c >= 0x531 && c <= 0x556)
		return c + 48;
	if (c >= 0xff21 && c <= 0xff3a)
		return c + 32;
	if (c == 0x178)
		return 0xff;
	if (c == 0x386)
		return 0x3ac;
	if (c >= 0x388 && c <= 0x38a)
		return c + 37;
	if (c == 0x38c)
		return 0x3cc;
	if (c == 0x38e || c == 0x38f)
		return c + 63;
	if (c == 0x4c0)
		return 0x4cf;
	if (((c >= 0x100 && c <= 0x12f) || (c >= 0x132 && c <= 0x137) || (c >= 0x14a && c <= 0x177) ||
	     (c >= 0x460 && c <= 0x481) || (c >= 0x48a && c <= 0x4bf) || (c >= 0x4d0 && c <= 0x52f)) && c % 2 == 0)
		return c + 1;
	if (((c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17e) || (c >= 0x4c1 && c <= 0x4ce)) && c % 2 == 1)
		return c + 1;

	return c;
}

function is_case_ignorable(c) {
	return c == 0x27 || c == 0x2e || c == 0x3a || c == 0x5e || c == 0x60 || c == 0xa8 || c == 0xad || c == 0xaf ||
		c == 0xb4 || c == 0xb7 || c == 0xb8 || (c >= 0x2b0 && c <= 0x36f) || c == 0x374 || c == 0x375 || c == 0x37a ||
		c == 0x384 || c == 0x385 || c == 0x387 || (c >= 0x200b && c <= 0x200f) || c == 0x2018 || c == 0x2019 ||
		c == 0x2024 || c == 0x2027 || c == 0xfeff;
}

function is_cased(c) {
	return (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || (c >= 0xc0 && c <= 0x24f && c != 0xd7 && c != 0xf7) ||
		(c >= 0x370 && c <= 0x52f) || (c >= 0x531 && c <= 0x587);
}

// lc() is ASCII-only and stops at a NUL byte.
function lower(s) {
	if (type(s) != 'string')
		return '';
	if (plain_ascii(s))
		return lc(s);

	let cps = code_points(s);

	if (cps == null)
		return s;

	let out = map(cps, cp_lower);

	// Σ at the end of a word becomes ς (Unicode Final_Sigma: case-ignorable characters such as
	// "." or "'" are skipped when looking for the letters around it).
	for (let i = 0; i < length(cps); i++) {
		if (cps[i] != 0x3a3)
			continue;

		let before = i - 1, after = i + 1;

		while (before >= 0 && is_case_ignorable(cps[before]))
			before--;
		while (after < length(cps) && is_case_ignorable(cps[after]))
			after++;

		if (before >= 0 && is_cased(cps[before]) && !(after < length(cps) && is_cased(cps[after])))
			out[i] = 0x3c2;
	}

	return from_code_points(out);
}

// A value cut for an error message that repeats it (40 UTF-16 units, as the desktop's slice).
function echoed(s) {
	if (js_length(s) <= 40)
		return s;

	let out = [], n = 0;

	for (let c in code_points(s) ?? []) {
		n += (c >= 0x10000) ? 2 : 1;
		if (n > 40)
			break;
		push(out, uchr(c));
	}

	return join('', out) + '\xe2\x80\xa6';
}

// ---- Percent-encoding -----------------------------------------------------------------------

// %XX becomes the byte; anything else stays (URLSearchParams decoding). Inputs are link pieces,
// which carry no NUL byte (checked when the link is read).
function pct_decode(s) {
	if (index(s, '%') < 0)
		return s;

	return replace(s, PCT_BYTE_G, (m, h) => chr(hex(h)));
}

// decodeURIComponent: null where it would throw.
function pct_strict(s) {
	if (index(s, '%') >= 0 && index(replace(s, PCT_ESCAPES_G, ''), '%') >= 0)
		return null;

	let d = pct_decode(s);

	return utf8_valid(d) ? d : null;
}

// decodeURIComponent, or the text itself where that would throw.
function pct_lenient(s) {
	return pct_strict(s) ?? s;
}

function pct_encode(s, set) {
	if (!has_nul(s) && match(s, URL_SAFE_RE))
		return s;

	let out = [];

	for (let i = 0, n = length(s); i < n; i++) {
		let c = ord(s, i), ch = substr(s, i, 1);

		push(out, (c < 0x20 || c > 0x7e || index(set, ch) >= 0) ? sprintf('%%%02X', c) : ch);
	}

	return join('', out);
}

// ---- JavaScript values ----------------------------------------------------------------------

function is_number(v) {
	let t = type(v);

	return t == 'int' || t == 'double';
}

function is_finite(n) {
	return is_number(n) && n - n == 0;
}

function is_js_integer(n) {
	if (!is_finite(n))
		return false;
	if (type(n) == 'int' || n > 1e16 || n < -1e16)
		return true;

	return int(n) == n;
}

// A JS integer as an int, so JSON output has no fractional part.
function to_int(n) {
	return (type(n) == 'double' && is_js_integer(n) && n >= -MAX_SAFE_INTEGER && n <= MAX_SAFE_INTEGER) ? int(n) : n;
}

function zeros(n) {
	let z = '';

	for (let i = 0; i < n; i++)
		z += '0';

	return z;
}

// Number#toString: the shortest digits that read back as n.
function js_number_text(n) {
	if (type(n) == 'int' && n >= -MAX_SAFE_INTEGER && n <= MAX_SAFE_INTEGER)
		return sprintf('%d', n);

	n = n * 1.0;

	if (n != n)
		return 'NaN';
	if (n - n != 0)
		return (n > 0) ? 'Infinity' : '-Infinity';
	if (n == 0)
		return '0';

	let sign = (n < 0) ? '-' : '';
	let m;

	if (n < 0)
		n = -n;

	for (let p = 1; p <= 17; p++) {
		let e = sprintf('%.' + (p - 1) + 'e', n);

		if (+e == n || p == 17) {
			m = match(e, EXP_TEXT_RE);
			break;
		}
	}

	// The first digit is never 0 here, so stripping trailing zeros leaves at least one.
	let digits = replace(m[1] + (m[3] ?? ''), TRAILING_ZEROS_RE, '');
	let k = length(digits), point = int(m[4]) + 1;

	if (k <= point && point <= 21)
		return sign + digits + zeros(point - k);
	if (point > 0 && point <= 21)
		return sign + substr(digits, 0, point) + '.' + substr(digits, point);
	if (point > -6 && point <= 0)
		return sign + '0.' + zeros(-point) + digits;

	let exp = point - 1;
	let mantissa = (k == 1) ? digits : substr(digits, 0, 1) + '.' + substr(digits, 1);

	return sign + mantissa + 'e' + ((exp < 0) ? '-' : '+') + ((exp < 0) ? -exp : exp);
}

// String(v) for JSON values.
function js_string(v) {
	let t = type(v);

	if (t == 'string')
		return v;
	if (t == 'int' || t == 'double')
		return js_number_text(v);
	if (t == 'bool')
		return v ? 'true' : 'false';
	if (t == 'array')
		return join(',', map(v, (x) => (x == null) ? '' : js_string(x)));
	if (t == 'object')
		return '[object Object]';

	return 'null';
}

// Number(text) for a string.
function js_string_number(s) {
	let t = js_trim(s);

	if (t == '')
		return 0;

	let m = rx(t, JS_DECIMAL_RE);

	if (m) {
		if (m[2] == 'Infinity')
			return (m[1] == '-') ? -1e308 * 10 : 1e308 * 10;

		let body = m[2];

		if (substr(body, 0, 1) == '.')
			body = '0' + body;
		// Long integers would saturate as int64; read them as doubles, like JS.
		if (index(body, '.') < 0 && m[3] == null && length(body) > 15)
			body += '.0';

		return +(m[1] + body + (m[3] ?? ''));
	}

	if (rx(t, JS_HEX_RE) || rx(t, JS_OCTAL_RE) || rx(t, JS_BINARY_RE))
		return +lc(t);

	return +'x';
}

// Number(v) for JSON values.
function js_to_number(v) {
	let t = type(v);

	if (t == 'int' || t == 'double')
		return v;
	if (t == 'bool')
		return v ? 1 : 0;
	if (v == null)
		return 0;
	if (t == 'string')
		return js_string_number(v);
	if (t == 'array')
		return js_string_number(js_string(v));

	return +'x';
}

function js_round(x) {
	if (x >= 9007199254740992)
		return x;

	let f = int(x);

	return (x - f >= 0.5) ? f + 1 : f;
}

// ---- JSON -----------------------------------------------------------------------------------

function json_ws(t, i) {
	for (let c = ord(t, i); c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d; c = ord(t, i))
		i++;

	return i;
}

function json_scan_string(t, i) {
	while (true) {
		let c = ord(t, ++i);

		if (c == null || c < 0x20)
			return -1;
		if (c == 0x22)
			return i + 1;
		if (c == 0x5c) {
			let e = substr(t, ++i, 1);

			if (e == 'u') {
				if (!match(substr(t, i + 1, 4), HEX4_RE))
					return -1;
				i += 4;
			}
			else if (e == '' || index('"\\/bfnrt', e) < 0)
				return -1;
		}
	}
}

// Index after the JSON value at i, or -1. Integer literals too long for int64 are noted in `big`.
function json_scan_value(t, i, big) {
	i = json_ws(t, i);

	let c = substr(t, i, 1);

	if (c == '"')
		return json_scan_string(t, i);

	if (c == '{' || c == '[') {
		let close = (c == '{') ? '}' : ']';

		i = json_ws(t, i + 1);

		if (substr(t, i, 1) == close)
			return i + 1;

		while (true) {
			if (c == '{') {
				if (substr(t, i, 1) != '"' || (i = json_scan_string(t, i)) < 0)
					return -1;

				i = json_ws(t, i);

				if (substr(t, i, 1) != ':')
					return -1;

				i++;
			}

			if ((i = json_scan_value(t, i, big)) < 0)
				return -1;

			i = json_ws(t, i);

			let d = substr(t, i, 1);

			if (d == close)
				return i + 1;
			if (d != ',')
				return -1;

			i = json_ws(t, i + 1);
		}
	}

	for (let word in [ 'true', 'false', 'null' ])
		if (substr(t, i, length(word)) == word)
			return i + length(word);

	let m = match(substr(t, i, 4096), JSON_NUMBER_RE);

	if (!m)
		return -1;
	if (m[2] == null && m[3] == null && length(m[1]) > 15)
		push(big, i + length(m[0]));

	return i + length(m[0]);
}

// JSON.parse: json() also takes comments, single quotes, NaN and trailing commas, so the text is
// checked against the JSON grammar first. Throws on bad input.
function json_parse(text) {
	if (type(text) != 'string' || has_nul(text))
		fail('bad JSON');

	let big = [], end = json_scan_value(text, 0, big);

	if (end < 0 || json_ws(text, end) != length(text))
		fail('bad JSON');

	// json() saturates such integers at the int64 limits; JS reads them as doubles.
	if (length(big)) {
		let parts = [], from = 0;

		for (let at in big) {
			push(parts, substr(text, from, at - from), '.0');
			from = at;
		}

		push(parts, substr(text, from));
		text = join('', parts);
	}

	return json(text);
}

function json_quote(s) {
	if (!has_nul(s) && !match(s, JSON_ESCAPE_RE))
		return '"' + s + '"';

	let out = [];

	for (let i = 0, n = length(s); i < n; i++) {
		let c = ord(s, i);

		if (c == 0x22)
			push(out, '\\"');
		else if (c == 0x5c)
			push(out, '\\\\');
		else if (c == 0x08)
			push(out, '\\b');
		else if (c == 0x09)
			push(out, '\\t');
		else if (c == 0x0a)
			push(out, '\\n');
		else if (c == 0x0c)
			push(out, '\\f');
		else if (c == 0x0d)
			push(out, '\\r');
		else if (c < 0x20)
			push(out, sprintf('\\u%04x', c));
		else
			push(out, substr(s, i, 1));
	}

	return '"' + join('', out) + '"';
}

function is_index_key(k) {
	return k == '0' || (rx(k, INDEX_KEY_RE) != null && +k < 4294967295);
}

// Property order of a JS object: array-index keys ascending, then the rest as inserted.
function js_keys(o) {
	let ints = [], rest = [];

	for (let k in o)
		push(is_index_key(k) ? ints : rest, k);

	if (!length(ints))
		return rest;

	return [ ...sort(ints, (a, b) => +a - +b), ...rest ];
}

// JSON.stringify, which the fingerprints hash.
function js_json(v) {
	let t = type(v);

	if (t == 'string')
		return json_quote(v);
	if (t == 'int' || t == 'double')
		return is_finite(v) ? js_number_text(v) : 'null';
	if (t == 'bool')
		return v ? 'true' : 'false';
	if (t == 'array')
		return '[' + join(',', map(v, js_json)) + ']';
	if (t == 'object')
		return '{' + join(',', map(js_keys(v), (k) => json_quote(k) + ':' + js_json(v[k]))) + '}';

	return 'null';
}

// ---- Sorting --------------------------------------------------------------------------------

function letter_weight(token) {
	let w = COLLATION_WEIGHT[ord(token, 0)];

	return (substr(token, 1) == '+') ? [ w + 50 ] : map(split(token, ''), (ch) => COLLATION_WEIGHT[ord(ch, 0)]);
}

// Collation elements of one code point beyond ASCII: [ [primaries], secondary ], or null when it
// is ignorable. ASCII and the common Latin letters, spaces and ignorables sort exactly; other
// symbols sort between "~" and "$", other scripts after Latin, both by code point.
function collation_elements(c) {
	if ((c >= 0x80 && c <= 0x9f && c != 0x85) || c == 0xad || c == 0x34f || (c >= 0x300 && c <= 0x36f) ||
	    (c >= 0x200b && c <= 0x200f) || (c >= 0x2060 && c <= 0x2064) || (c >= 0xfe00 && c <= 0xfe0f) || c == 0xfeff)
		return null;
	if (c == 0x85 || c == 0x2028 || c == 0x2029)
		return [ [ COLLATION_WEIGHT[0x0d] + 50 ], 0 ];
	if (c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) || c == 0x202f || c == 0x205f || c == 0x3000)
		return [ [ COLLATION_WEIGHT[0x20] ], 0 ];
	if (c >= 0xff01 && c <= 0xff5e)
		return [ [ COLLATION_WEIGHT[cp_lower(c - 0xfee0)] ], 0 ];

	if (c >= 0xc0 && c <= 0x17f) {
		let token = LATIN_BASES[c - 0xc0];

		if (token != '*')
			return [ letter_weight(token), (length(token) == 1) ? 1 : 0 ];
	}

	if ((c >= 0xa2 && c <= 0xa5) || (c >= 0x20a0 && c <= 0x20cf))
		return [ [ COLLATION_WEIGHT[0x24] + 1 + c / 100000.0 ], 0 ];
	if ((c >= 0xa1 && c <= 0xbf) || c == 0xd7 || c == 0xf7 || (c >= 0x2010 && c <= 0x2bff) || (c >= 0x3001 && c <= 0x303f) ||
	    (c >= 0x1f000 && c <= 0x1faff))
		return [ [ COLLATION_WEIGHT[0x7e] + 1 + c / 20000.0 ], 0 ];

	// Cyrillic ё and й are е and и with a mark.
	if (c == 0x451 || c == 0x439)
		return [ [ 100000 + c - ((c == 0x451) ? 0x1c : 1) ], 1 ];
	if (c == 0x3c2)
		return [ [ 100000 + 0x3c3 ], 0 ];

	return [ [ 100000 + c ], 0 ];
}

function collation_key(s) {
	let primary = [], secondary = [], tertiary = [];

	for (let c in code_points(s) ?? []) {
		let lower_c = cp_lower(c), elements;

		if (c < 0x80) {
			let w = COLLATION_WEIGHT[lower_c];

			if (w == null)
				continue;

			elements = [ [ w ], 0 ];
		}
		else if ((elements = collation_elements(lower_c)) == null)
			continue;

		for (let w in elements[0]) {
			push(primary, w);
			push(secondary, elements[1]);
			push(tertiary, (lower_c != c) ? 1 : 0);
		}
	}

	return [ primary, secondary, tertiary ];
}

function compare_keys(a, b) {
	for (let level = 0; level < 3; level++) {
		let x = a[level], y = b[level], n = min(length(x), length(y));

		for (let i = 0; i < n; i++)
			if (x[i] != y[i])
				return (x[i] < y[i]) ? -1 : 1;

		if (length(x) != length(y))
			return (length(x) < length(y)) ? -1 : 1;
	}

	return 0;
}

// Array#sort is stable; sort() is not, so ties keep their order through the index.
function stable_sort(items, compare) {
	let decorated = [];

	for (let i = 0; i < length(items); i++)
		push(decorated, [ items[i], i ]);

	sort(decorated, (a, b) => compare(a[0], b[0]) || (a[1] - b[1]));

	return map(decorated, (d) => d[0]);
}

// [[key, value], ...] sorted by key with localeCompare.
function sort_entries(entries) {
	let keyed = map(entries, (e) => [ e, collation_key(e[0]) ]);

	return map(stable_sort(keyed, (a, b) => compare_keys(a[1], b[1])), (k) => k[0]);
}

function strip_null(o) {
	let r = {};

	for (let k in o)
		if (o[k] != null)
			r[k] = o[k];

	return r;
}

function field(o, k) {
	return (type(o) == 'object') ? o[k] : null;
}

// ---- Hosts ----------------------------------------------------------------------------------

function ipv6_text(text) {
	if (index(text, ':') < 0)
		return null;

	let bytes = iptoarr(text);

	if (length(bytes) != 16)
		return null;

	let pieces = [];

	for (let i = 0; i < 16; i += 2)
		push(pieces, bytes[i] * 256 + bytes[i + 1]);

	// WHATWG: compress the first longest run of two or more zero pieces.
	let best = -1, best_len = 1;

	for (let i = 0; i < 8; ) {
		if (pieces[i] != 0) {
			i++;
			continue;
		}

		let j = i;

		while (j < 8 && pieces[j] == 0)
			j++;

		if (j - i > best_len) {
			best = i;
			best_len = j - i;
		}

		i = j;
	}

	let out = '';

	for (let i = 0; i < 8; i++) {
		if (i == best) {
			out += (i == 0) ? '::' : ':';
			i += best_len - 1;
			continue;
		}

		out += sprintf('%x', pieces[i]) + ((i < 7) ? ':' : '');
	}

	return out;
}

function ipv4_number(part) {
	if (part == '')
		return null;

	let radix = 10, digits = part;

	if (lc(substr(part, 0, 2)) == '0x') {
		radix = 16;
		digits = substr(part, 2);
	}
	else if (length(part) > 1 && substr(part, 0, 1) == '0') {
		radix = 8;
		digits = substr(part, 1);
	}

	if (digits == '')
		return 0;

	let re = (radix == 16) ? HEX_DIGITS_RE : ((radix == 8) ? OCTAL_DIGITS_RE : DIGITS_RE);

	if (!rx(digits, re))
		return null;

	digits = replace(digits, LEADING_ZEROS_RE, '');

	// Too large for any address; the caller rejects it.
	if (length(digits) > 12)
		return 1099511627776;

	let n = 0;

	for (let i = 0; i < length(digits); i++)
		n = n * radix + hex(substr(digits, i, 1));

	return n;
}

function host_labels(host) {
	let parts = split(host, '.');

	if (parts[length(parts) - 1] == '' && length(parts) > 1)
		pop(parts);

	return parts;
}

function ends_in_number(host) {
	let parts = split(host, '.');

	if (parts[length(parts) - 1] == '') {
		if (length(parts) == 1)
			return false;
		pop(parts);
	}

	let last = parts[length(parts) - 1];

	return (last != '' && rx(last, DIGITS_RE) != null) || ipv4_number(last) != null;
}

function ipv4_text(host) {
	let parts = host_labels(host), nums = [];

	if (length(parts) > 4)
		return null;

	for (let p in parts) {
		let v = ipv4_number(p);

		if (v == null)
			return null;

		push(nums, v);
	}

	let n = length(nums), addr = nums[n - 1];

	for (let i = 0; i < n - 1; i++) {
		if (nums[i] > 255)
			return null;

		addr += nums[i] * 256 ** (3 - i);
	}

	if (nums[n - 1] >= 256 ** (5 - n))
		return null;

	return sprintf('%d.%d.%d.%d', (addr >> 24) & 255, (addr >> 16) & 255, (addr >> 8) & 255, addr & 255);
}

function puny_adapt(delta, points, first) {
	delta = first ? int(delta / 700) : int(delta / 2);
	delta += int(delta / points);

	let k = 0;

	while (delta > 455) {
		delta = int(delta / 35);
		k += 36;
	}

	return k + int(36 * delta / (delta + 38));
}

function puny_digit(d) {
	return chr((d < 26) ? d + 97 : d + 22);
}

// RFC 3492 Punycode of one label, without the "xn--" prefix.
function puny_encode(cps) {
	let n = 128, delta = 0, bias = 72, out = [], total = length(cps);

	for (let c in cps)
		if (c < 128)
			push(out, chr(c));

	let basic = length(out), handled = basic;

	if (basic > 0)
		push(out, '-');

	while (handled < total) {
		let m = 0x110000;

		for (let c in cps)
			if (c >= n && c < m)
				m = c;

		delta += (m - n) * (handled + 1);
		n = m;

		for (let c in cps) {
			if (c < n)
				delta++;

			if (c == n) {
				let q = delta;

				for (let k = 36; true; k += 36) {
					let t = (k <= bias) ? 1 : ((k >= bias + 26) ? 26 : k - bias);

					if (q < t)
						break;

					push(out, puny_digit(t + (q - t) % (36 - t)));
					q = int((q - t) / (36 - t));
				}

				push(out, puny_digit(q));
				bias = puny_adapt(delta, handled + 1, handled == basic);
				delta = 0;
				handled++;
			}
		}

		delta++;
		n++;
	}

	return join('', out);
}

function puny_value(c) {
	if (c >= 0x30 && c <= 0x39)
		return c - 22;
	if (c >= 0x41 && c <= 0x5a)
		return c - 0x41;
	if (c >= 0x61 && c <= 0x7a)
		return c - 0x61;

	return null;
}

// RFC 3492 decoding of the text after "xn--", as Node's punycode.decode; null when invalid.
function puny_decode(input) {
	let n = 128, i = 0, bias = 72, output = [];
	let basic = rindex(input, '-');

	if (basic < 0)
		basic = 0;

	for (let j = 0; j < basic; j++)
		push(output, ord(input, j));

	for (let pos = (basic > 0) ? basic + 1 : 0; pos < length(input); ) {
		let old_i = i, w = 1;

		for (let k = 36; true; k += 36) {
			let digit = (pos < length(input)) ? puny_value(ord(input, pos++)) : null;

			if (digit == null || i + digit * w > 0x7fffffff)
				return null;

			i += digit * w;

			let t = (k <= bias) ? 1 : ((k >= bias + 26) ? 26 : k - bias);

			if (digit < t)
				break;

			w *= 36 - t;
		}

		let count = length(output) + 1;

		bias = puny_adapt(i - old_i, count, old_i == 0);
		n += int(i / count);
		i %= count;

		if (n > 0x10ffff)
			return null;

		splice(output, i, 0, n);
		i++;
	}

	return output;
}

// UTS #46 mapping for the characters share links carry: lower case, full-width forms and dots,
// default-ignorable characters dropped. Null for a character that makes the name invalid.
function idna_map(c) {
	if (c >= 0xff01 && c <= 0xff5e)
		c -= 0xfee0;
	if (c == 0x3002 || c == 0xff0e || c == 0xff61)
		return [ 0x2e ];
	if (c == 0xad || c == 0x34f || (c >= 0x180b && c <= 0x180d) || c == 0x200b || c == 0x2060 ||
	    (c >= 0xfe00 && c <= 0xfe0f) || c == 0xfeff)
		return [];
	if (c == 0x17f)
		return [ 0x73 ];
	if (c == 0x130)
		return [ 0x69, 0x307 ];
	if (c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) || c == 0x202f || c == 0x205f || c == 0x3000)
		return [ 0x20 ];
	if ((c >= 0x80 && c <= 0x9f) || c == 0x2028 || c == 0x2029 || c == 0xfffd || c == 0xfffe || c == 0xffff)
		return null;

	return [ cp_lower(c) ];
}

// UTS #46 checks a label written as punycode when the name is not plain ASCII: it must decode
// to valid characters, not all of them ASCII.
function punycode_label_valid(label) {
	let cps = puny_decode(from_code_points(slice(label, 4)));
	let wide = false;

	if (cps == null)
		return false;

	for (let c in cps) {
		let m = idna_map(c);

		if (m == null || length(m) != 1 || m[0] != c || c == 0x2e)
			return false;
		if (c >= 0x80)
			wide = true;
	}

	return wide;
}

function domain_to_ascii(domain) {
	if (plain_ascii(domain))
		return lc(domain);

	let cps = code_points(domain);

	if (cps == null)
		return null;

	let labels = [], label = [], broken = false;
	let flush = () => {
		let ascii = true;

		for (let c in label)
			if (c >= 0x80)
				ascii = false;

		if (length(label) >= 4 && from_code_points(slice(label, 0, 4)) == 'xn--' && (!ascii || !punycode_label_valid(label)))
			broken = true;

		push(labels, ascii ? from_code_points(label) : 'xn--' + puny_encode(label));
		label = [];
	};

	for (let c in cps) {
		let mapped = idna_map(c);

		if (mapped == null)
			return null;

		for (let m in mapped) {
			if (m == 0x2e)
				flush();
			else
				push(label, m);
		}
	}

	flush();

	return broken ? null : join('.', labels);
}

// WHATWG host parsing for a special scheme (what `new URL('https://' + host + '/').hostname` gives),
// for a host with no ':' or '@' in it. Null where the URL would not parse.
function special_host(input) {
	if (has_nul(input))
		return null;
	if (has_any(input, '\t\n\r'))
		input = replace(input, TAB_NEWLINE_G, '');

	// A special URL skips slashes and backslashes before the host; the next backslash starts
	// the path.
	while (substr(input, 0, 1) == '\\' || substr(input, 0, 1) == '/')
		input = substr(input, 1);

	let bs = index(input, '\\');

	if (bs >= 0)
		input = substr(input, 0, bs);

	if (input == '')
		return null;

	let ascii = domain_to_ascii(utf8_fix(pct_decode(input)));

	if (ascii == null || ascii == '' || has_nul(ascii) || match(ascii, BAD_DOMAIN_CHAR_RE))
		return null;

	return ends_in_number(ascii) ? ipv4_text(ascii) : ascii;
}

// WHATWG opaque host (vless:// and trojan:// are not special schemes): kept as written,
// non-ASCII percent-encoded.
function opaque_host(text) {
	if (has_nul(text) || match(text, BAD_HOST_CHAR_RE))
		return null;

	return pct_encode(text, '');
}

// Lower case, IPv6 without brackets: the host form fingerprints have always hashed.
function canonical_host(value) {
	let h = js_trim(value);

	if (substr(h, 0, 1) == '[')
		h = substr(h, 1);
	if (substr(h, -1) == ']')
		h = substr(h, 0, length(h) - 1);

	return lower(h);
}

// The address xray dials: the canonical host with an internationalised name in punycode.
function host_to_ascii(value) {
	if (length(value ?? '') > MAX_HOST_INPUT)
		return null;

	let host = canonical_host(value);

	if (!has_non_ascii(host) && index(host, '%') < 0)
		return host;

	// Anything that would end the authority belongs to no host name.
	if (has_js_space(host) || has_any(host, '/?#@:\\[]'))
		return null;

	let ascii = special_host(host);

	return (ascii != null && rx(ascii, PRINTABLE_ASCII_RE) && index(ascii, '%') < 0) ? lc(ascii) : null;
}

// The TLS server name as xray must send it: punycode for an internationalised name, anything
// else as written.
function ascii_server_name(value) {
	let name = js_trim(value ?? '');

	if (name == '')
		return null;
	if (!has_non_ascii(name))
		return name;

	return host_to_ascii(name) ?? name;
}

// ---- Shared link fields ---------------------------------------------------------------------

function param(entries, key) {
	for (let e in entries)
		if (e[0] == key)
			return e[1];

	return null;
}

function form_decode(s) {
	if (index(s, '+') >= 0)
		s = replace(s, PLUS_G, ' ');

	return utf8_fix(pct_decode(s));
}

// UTF-16 code units of a well-formed string.
function utf16_units(s) {
	let units = [];

	for (let c in code_points(s) ?? []) {
		if (c < 0x10000)
			push(units, c);
		else
			push(units, 0xd800 + ((c - 0x10000) >> 10), 0xdc00 + ((c - 0x10000) & 0x3ff));
	}

	return units;
}

function hex_digit(u) {
	if (u >= 0x30 && u <= 0x39)
		return u - 0x30;
	if (u >= 0x41 && u <= 0x46)
		return u - 0x37;
	if (u >= 0x61 && u <= 0x66)
		return u - 0x57;

	return null;
}

// URLSearchParams over raw text, as Node decodes it: a piece with a valid %XX goes through
// decodeURIComponent, and where that throws, through querystring's unescapeBuffer, which keeps
// only the low byte of every other UTF-16 code unit.
function form_decode_raw(s) {
	if (index(s, '+') >= 0)
		s = replace(s, PLUS_G, ' ');

	if (!match(s, PCT_ESCAPE_RE))
		return s;

	let strict = pct_strict(s);

	if (strict != null || plain_ascii(s))
		return strict ?? utf8_fix(pct_decode(s));

	let units = utf16_units(s), out = [], n = length(units);

	for (let i = 0; i < n; i++) {
		let u = units[i];

		if (u == 0x25 && i < n - 2) {
			let hi = hex_digit(units[i + 1]), lo = hex_digit(units[i + 2]);

			if (hi != null && lo != null) {
				push(out, chr(hi * 16 + lo));
				i += 2;
				continue;
			}
		}

		push(out, chr(u & 0xff));
	}

	return utf8_fix(join('', out));
}

// URLSearchParams entries. `decode` is form_decode for a query a WHATWG URL already encoded.
function parse_form(query, decode) {
	let entries = [], pieces = split(query, '&');

	decode ??= form_decode;

	if (length(filter(pieces, (x) => x != '')) > MAX_QUERY_PARAMS)
		fail(PARAMS_MESSAGE);

	for (let piece in pieces) {
		if (piece == '')
			continue;

		let eq = index(piece, '=');

		push(entries, (eq >= 0)
			? [ decode(substr(piece, 0, eq)), decode(substr(piece, eq + 1)) ]
			: [ decode(piece), '' ]);
	}

	return entries;
}

function lowered_entries(entries) {
	return sort_entries(map(entries, (e) => [ lower(e[0]), e[1] ]));
}

function normalize_transport(value) {
	let t = lower(js_trim(value));

	if (t == 'raw')
		return 'tcp';
	if (t == 'kcp')
		return 'mkcp';
	if (index([ 'tcp', 'ws', 'grpc', 'xhttp', 'mkcp', 'hysteria' ], t) >= 0)
		return t;
	if (t == 'httpupgrade' || t == 'http-upgrade' || t == 'http_upgrade')
		return 'httpupgrade';

	return 'unknown';
}

// The outbound builder's reading: h2 and http are kept apart so they get their own message.
function builder_transport(value) {
	let t = lower(js_trim(value));

	if (t == 'raw')
		return 'tcp';
	if (t == 'kcp')
		return 'mkcp';
	if (t == 'h2' || t == 'http2')
		return 'http';
	if (index([ 'tcp', 'ws', 'grpc', 'xhttp', 'http', 'httpupgrade', 'mkcp', 'hysteria' ], t) >= 0)
		return t;
	if (t == 'http-upgrade' || t == 'http_upgrade')
		return 'httpupgrade';

	return 'unknown';
}

function normalize_security(value) {
	let s = lower(js_trim(value));

	if (s == '' || s == '0' || s == 'false' || s == 'none')
		return 'none';
	if (s == 'tls' || s == 'reality')
		return s;

	return 'unknown';
}

// The security of a vless:// or trojan:// link: the parameter, else the legacy tls=1; a trojan://
// link with neither is TLS, as Trojan always is.
function uri_security_text(protocol, entries) {
	let security = param(entries, 'security');

	if (security != null)
		return security;

	let tls = param(entries, 'tls');

	if (tls != null)
		return (tls == '1') ? 'tls' : 'none';

	return (protocol == 'trojan') ? 'tls' : 'none';
}

function vmess_text(v) {
	let t = type(v);

	if (t == 'string')
		return v;

	return (t == 'int' || t == 'double' || t == 'bool') ? js_string(v) : null;
}

function vmess_security_text(v) {
	if (v === true)
		return 'tls';
	if (v === false || v == null)
		return 'none';

	return js_string(v);
}

function fingerprint(canonical) {
	return 'sha256:' + sha256(canonical);
}

function detect_protocol(link) {
	let m = match(link, SCHEME_RE);
	let scheme = m ? lc(m[1]) : '';

	if (scheme == 'vless' || scheme == 'vmess' || scheme == 'trojan')
		return scheme;
	if (scheme == 'hysteria2' || scheme == 'hy2')
		return 'hysteria2';

	return null;
}

// ---- Credentials (router-only checks, DESIGN §5) --------------------------------------------

// What xray's uuid.ParseString accepts: 1 to 30 bytes of any text (hashed into an id), or 32 hex
// digits in the 8-4-4-4-12 groups, each optionally led by a dash (xray ignores what follows).
function xray_id_valid(id) {
	let n = length(id);

	if (n < 32 || n > 36)
		return n >= 1 && n <= 30;

	let pos = 0;

	for (let group in [ 8, 4, 4, 4, 12 ]) {
		if (substr(id, pos, 1) == '-')
			pos++;

		if (!rx(substr(id, pos, group), HEX_DIGITS_RE) || length(substr(id, pos, group)) != group)
			return false;

		pos += group;
	}

	return true;
}

function check_id(label, id) {
	if (type(id) != 'string' || !xray_id_valid(id))
		fail(`Invalid ${label} id: expected a UUID or up to 30 characters.`);
}

function check_reality(entries) {
	if (!rx(param(entries, 'pbk'), REALITY_KEY_RE))
		fail(REALITY_KEY_MESSAGE);

	let sid = param(entries, 'sid');

	if (sid != null && !rx(sid, SHORT_ID_RE))
		fail(REALITY_SHORT_ID_MESSAGE);
}

// xray 26.3 panics on an mlkem768x25519plus value without a key, so only what it can load passes.
function vless_encryption_valid(enc) {
	if (enc == 'none')
		return true;

	let parts = split(enc, '.');

	if (length(parts) < 4 || parts[0] != 'mlkem768x25519plus' ||
	    index([ 'native', 'xorpub', 'random' ], parts[1]) < 0 || index([ '1rtt', '0rtt' ], parts[2]) < 0)
		return false;

	let key = false;

	for (let i = 3; i < length(parts); i++) {
		if (length(parts[i]) < 20)
			continue;
		if (!rx(parts[i], BASE64URL_RE) || (length(parts[i]) != 43 && length(parts[i]) != 1579))
			return false;
		key = true;
	}

	return key;
}

// ---- vless:// and trojan:// -----------------------------------------------------------------

function first_of(s, chars) {
	let at = length(s);

	for (let i = 0; i < length(chars); i++) {
		let p = index(s, substr(chars, i, 1));

		if (p >= 0 && p < at)
			at = p;
	}

	return at;
}

// The parts of a WHATWG URL with a non-special scheme that these links use; null where
// `new URL()` would throw.
function split_url(link) {
	let s = link;

	if (has_any(s, '\t\n\r'))
		s = replace(s, TAB_NEWLINE_G, '');

	while (length(s) && ord(s, length(s) - 1) <= 0x20)
		s = substr(s, 0, length(s) - 1);

	let rest = substr(s, index(s, '://') + 3);
	let end = first_of(rest, '/?#');
	let authority = substr(rest, 0, end), tail = substr(rest, end);
	let hash = index(tail, '#');
	let fragment = (hash >= 0) ? substr(tail, hash + 1) : '';

	if (hash >= 0)
		tail = substr(tail, 0, hash);

	let q = index(tail, '?');
	let at = rindex(authority, '@');
	let userinfo = (at >= 0) ? substr(authority, 0, at) : '';
	let hostport = (at >= 0) ? substr(authority, at + 1) : authority;

	if (at >= 0 && hostport == '')
		return null;

	let colon = -1, bracket = false;

	for (let i = 0; i < length(hostport) && colon < 0; i++) {
		let ch = substr(hostport, i, 1);

		if (ch == '[')
			bracket = true;
		else if (ch == ']')
			bracket = false;
		else if (ch == ':' && !bracket)
			colon = i;
	}

	let host_text = (colon >= 0) ? substr(hostport, 0, colon) : hostport;
	let port_text = (colon >= 0) ? substr(hostport, colon + 1) : '';

	if ((colon >= 0 && host_text == '') || !match(port_text, OPTIONAL_DIGITS_RE))
		return null;

	let port = '';

	if (port_text != '') {
		let digits = replace(port_text, LEADING_ZEROS_RE, '');

		if (length(digits) > 5 || +digits > 65535)
			return null;

		port = sprintf('%d', +digits);
	}

	let host;

	if (substr(host_text, 0, 1) == '[') {
		let v6 = (substr(host_text, -1) == ']') ? ipv6_text(substr(host_text, 1, length(host_text) - 2)) : null;

		if (v6 == null)
			return null;

		host = '[' + v6 + ']';
	}
	else if ((host = opaque_host(host_text)) == null)
		return null;

	let colon_user = index(userinfo, ':');
	let user_raw = (colon_user >= 0) ? substr(userinfo, 0, colon_user) : userinfo;

	return {
		username: pct_encode(user_raw, USERINFO_SET),
		user_raw,
		hostname: host,
		port,
		query: (q >= 0) ? substr(tail, q + 1) : '',
		hash: (fragment != '') ? '#' + pct_encode(fragment, FRAGMENT_SET) : ''
	};
}

function decode_name(hash, fallback) {
	if (hash == '')
		return fallback;

	return js_trim(pct_lenient(substr(hash, 1))) || fallback;
}

function read_uri(link, protocol) {
	let label = uc(protocol);
	let url = has_nul(link) ? null : split_url(link);

	if (url == null)
		fail(`Invalid ${label} URI.`);

	let host = host_to_ascii(url.hostname);
	let port = (url.port == '') ? 0 : +url.port;

	if (!host || port < 1 || port > 65535)
		fail(`${label} URI must contain host and valid port.`);

	let entries = parse_form(url.query);
	let canonical = js_json({
		protocol,
		username: url.username,
		host: canonical_host(url.hostname),
		port,
		params: lowered_entries(entries),
		hash: decode_name(url.hash, '')
	});

	let security = normalize_security(uri_security_text(protocol, entries));
	let secret = pct_strict(url.user_raw);

	if (protocol == 'vless')
		check_id('VLESS', secret);
	else if (secret == null)
		fail(TROJAN_PASSWORD_ENCODING_MESSAGE);
	else if (secret == '')
		fail(TROJAN_PASSWORD_MESSAGE);

	if (security == 'reality')
		check_reality(entries);

	return {
		protocol,
		host,
		port,
		name: decode_name(url.hash, `${protocol}-${host}:${port}`),
		transport: normalize_transport(param(entries, 'type') ?? param(entries, 'net') ?? 'tcp'),
		security,
		flow: js_trim(param(entries, 'flow') ?? ''),
		fingerprint: fingerprint(canonical),
		entries,
		secret
	};
}

// ---- vmess:// -------------------------------------------------------------------------------

// Buffer.from(text, 'base64'): either alphabet, unknown characters skipped, '=' ends the data.
// Node reads each UTF-16 code unit by its low byte, so a non-ASCII character can stand for one.
function b64_node(text) {
	let out = [], acc = 0, bits = 0;

	for (let i = 0, n = length(text); i < n; ) {
		let c = ord(text, i), units;

		if (c < 0x80) {
			units = [ c ];
			i++;
		}
		else {
			let k = utf8_seq(text, i), cp = utf8_cp(text, i, k);

			units = (cp >= 0x10000)
				? [ (0xd800 + ((cp - 0x10000) >> 10)) & 0xff, (0xdc00 + ((cp - 0x10000) & 0x3ff)) & 0xff ]
				: [ cp & 0xff ];
			i += k;
		}

		for (let u in units) {
			if (u == 0x3d)
				return join('', out);

			let v = B64_VALUE[u];

			if (v == null)
				continue;

			acc = ((acc << 6) | v) & 0xffffff;
			bits += 6;

			if (bits >= 8) {
				bits -= 8;
				push(out, chr((acc >> bits) & 0xff));
			}
		}
	}

	return join('', out);
}

function vmess_payload(link) {
	let payload;

	try {
		payload = json_parse(utf8_fix(b64_node(remove_js_spaces(js_trim(substr(link, 8))))));
	}
	catch (e) {
		fail(VMESS_JSON_MESSAGE);
	}

	if (type(payload) != 'object' && type(payload) != 'array')
		fail(VMESS_ADDRESS_MESSAGE);

	return payload;
}

function set_entry(entries, key, value) {
	for (let e in entries)
		if (e[0] == key) {
			e[1] = value;
			return;
		}

	push(entries, [ key, value ]);
}

function read_vmess(link) {
	let payload = vmess_payload(link);
	let canonical_add = canonical_host(js_string(field(payload, 'add') ?? ''));
	let host = host_to_ascii(canonical_add);
	let port = js_to_number(field(payload, 'port'));

	if (!host || !is_js_integer(port) || port < 1 || port > 65535)
		fail(VMESS_ADDRESS_MESSAGE);

	port = to_int(port);

	let fallback = `vmess-${host}:${port}`;
	let transport = normalize_transport(vmess_text(field(payload, 'net')) ?? 'tcp');
	let security = normalize_security(vmess_security_text(field(payload, 'tls')));

	// "vmess:" + JSON of the payload with the normalised fields, keys sorted.
	let entries = map(js_keys(payload), (k) => [ k, payload[k] ]);

	set_entry(entries, 'add', canonical_add);
	set_entry(entries, 'port', port);
	set_entry(entries, 'net', transport);
	set_entry(entries, 'tls', security);

	let sorted = {};

	for (let e in sort_entries(entries))
		sorted[e[0]] = e[1];

	check_id('VMess', vmess_text(field(payload, 'id')));

	return {
		protocol: 'vmess',
		host,
		port,
		name: js_trim(js_string(field(payload, 'ps') ?? fallback)) || fallback,
		transport,
		security,
		flow: js_trim(js_string(field(payload, 'flow') ?? '')),
		fingerprint: fingerprint('vmess:' + js_json(sorted)),
		payload
	};
}

// ---- hysteria2:// and hy2:// ----------------------------------------------------------------

// Trimmed text, or '' when it is too long to be a real value.
function bounded_trim(v) {
	return (type(v) != 'string' || js_length(v) > HY2_MAX_SCALAR) ? '' : js_trim(v);
}

// JS \s also matches the Unicode spaces; the patterns here are ASCII.
function ascii_spaces(s) {
	if (plain_ascii(s))
		return s;

	let out = [];

	for (let i = 0, n = length(s); i < n; ) {
		let k = js_space_len(s, i);

		push(out, (k > 0) ? ' ' : substr(s, i, 1));
		i += (k > 0) ? k : 1;
	}

	return join('', out);
}

function colon_ranges(s) {
	return has_nul(s) ? s : replace(ascii_spaces(s), COLON_RANGE_G, (m, a, b) => a + '-' + b);
}

// "443", "20000-30000" or "443,20000-30000" as [from, to] pairs, in the order written.
function read_port_list(spec) {
	let items = split(spec, ',');

	// Generous for a written list, and it bounds the work before merging.
	if (length(items) > HY2_MAX_HOP_RANGES * 4)
		fail(HY2_PORTS_MESSAGE);

	return map(items, (item) => {
		let m = rx(ascii_spaces(js_trim(item)), PORT_ITEM_RE);

		if (!m)
			fail(HY2_PORTS_MESSAGE);

		let first = +m[1], last = (m[3] != null) ? +m[3] : first;
		let from = min(first, last), to = max(first, last);

		if (from < 1 || to > 65535)
			fail(HY2_PORTS_MESSAGE);

		return [ from, to ];
	});
}

// Sorted, with overlapping and adjacent ranges joined.
function merge_ports(ranges) {
	let merged = [];

	for (let r in stable_sort(ranges, (a, b) => a[0] - b[0])) {
		let last = length(merged) ? merged[length(merged) - 1] : null;

		if (last && r[0] <= last[1] + 1)
			last[1] = max(last[1], r[1]);
		else
			push(merged, [ r[0], r[1] ]);
	}

	if (length(merged) > HY2_MAX_HOP_RANGES)
		fail(HY2_PORTS_MESSAGE);

	return merged;
}

function format_ports(ranges) {
	return join(',', map(ranges, (r) => (r[0] == r[1]) ? `${r[0]}` : `${r[0]}-${r[1]}`));
}

function covers_several(ranges) {
	return length(ranges) > 1 || ranges[0][0] != ranges[0][1];
}

function hop_compact(raw) {
	return remove_js_spaces(bounded_trim((raw == null) ? null : js_string(raw)));
}

function hop_seconds(raw) {
	let text = hop_compact(raw);

	if (substr(text, -1) == 's' || substr(text, -1) == 'S')
		text = substr(text, 0, length(text) - 1);

	return rx(text, SECONDS_RE) ? max(HY2_MIN_HOP_INTERVAL, +text) : null;
}

// Seconds as a number or "min-max"; "30s" reads as 30. At least 5, as xray requires.
function parse_hop_interval(value, max_value) {
	let range = rx(hop_compact(value), SECONDS_RANGE_RE);
	let lo = range ? hop_seconds(range[1]) : hop_seconds(value);
	let hi = range ? hop_seconds(range[2]) : hop_seconds(max_value);

	if (lo == null)
		return null;
	if (hi == null || hi == lo)
		return lo;

	return `${min(lo, hi)}-${max(lo, hi)}`;
}

// Hysteria's notation: a bare number is Mbps and units are decimal. Returns "N bps", or null for
// empty, unreadable or too slow rates (congestion control is then left to BBR).
function parse_bandwidth(value) {
	let m = rx(ascii_spaces(bounded_trim(value)), HYSTERIA_RATE_RE);
	let multiplier = m ? DECIMAL_BANDWIDTH[lc(m[3])] : null;

	if (multiplier == null)
		return null;

	let bits = js_round(js_string_number(m[1]) * multiplier);

	return (bits >= HY2_MIN_BRUTAL_BPS) ? `${js_number_text(bits)} bps` : null;
}

// xray's own notation (binary units, "60 mbps"), as an fm JSON value carries it; kept as written.
function read_xray_bandwidth(value) {
	if (type(value) != 'string')
		return null;

	let m = rx(ascii_spaces(lower(bounded_trim(value))), XRAY_RATE_RE);
	let multiplier = m ? BINARY_BANDWIDTH[m[3]] : null;

	if (multiplier == null)
		return null;

	return (js_string_number(m[1]) * multiplier >= HY2_MIN_BRUTAL_BPS) ? js_trim(value) : null;
}

function read_obfs_password(obfs, password, mask_password) {
	let kind = lower(js_trim(obfs ?? ''));

	if (kind == 'none' || kind == 'plain' || (!kind && !password && mask_password == null))
		return null;
	if (kind && kind != 'salamander')
		fail(`Unsupported Hysteria 2 obfuscation: ${echoed(kind)}. Only salamander works.`);

	// NekoBox and v2rayN treat obfs-password without obfs as salamander.
	let chosen = password || mask_password;

	if (!chosen)
		fail(HY2_OBFS_PASSWORD_MESSAGE);

	return chosen;
}

// The desktop's decodeBase64: standard or url-safe, padding optional; null when it is not base64.
function decode_base64(value) {
	if (has_nul(value))
		return null;

	let data = replace(value, PADDING_RE, '');

	if (!rx(data, BASE64_RE) || length(data) % 4 == 1)
		return null;

	return b64_node(data);
}

// Hex with or without ':'/'-' separators (the openssl form), or base64 as some panels store it.
function normalize_pin(value, message) {
	if (js_length(value) > HY2_MAX_SCALAR)
		fail(message ?? HY2_PIN_MESSAGE);

	let hex_text = has_nul(value) ? value : replace(remove_js_spaces(value), HEX_SEPARATORS_G, '');

	if (rx(hex_text, SHA256_HEX_RE))
		return lc(hex_text);

	let bytes = decode_base64(value);

	if (bytes != null && length(bytes) == 32)
		return hexenc(bytes);

	fail(message ?? HY2_PIN_MESSAGE);
}

function read_pins(values, message) {
	let pins = [];

	for (let v in values) {
		if (v == null)
			continue;

		for (let item in split(v, ',')) {
			let t = js_trim(item);

			if (t == '')
				continue;

			let pin = normalize_pin(t, message);

			if (index(pins, pin) < 0)
				push(pins, pin);
		}
	}

	return pins;
}

// Only the base64 ECHConfigList form: xray also takes a DNS server here and queries it directly,
// outside the tunnel, and a share link must not choose extra hosts to contact.
function read_ech(value) {
	let text = js_trim(value ?? '');

	if (text == '')
		return null;

	let bytes = decode_base64(text);

	if (bytes == null || length(bytes) < 4 || ((ord(bytes, 0) << 8) | ord(bytes, 1)) != length(bytes) - 2)
		fail(HY2_ECH_MESSAGE);

	return text;
}

function parse_flag(value) {
	return index([ '1', 't', 'true', 'yes', 'on' ], lower(js_trim(value ?? ''))) >= 0;
}

function read_mask_ports(value) {
	if (type(value) != 'string' && !is_number(value))
		return null;

	let spec = colon_ranges(js_trim(js_string(value)));

	return (spec != '') ? merge_ports(read_port_list(spec)) : null;
}

function interval_value(value) {
	return (type(value) == 'string' || is_number(value)) ? value : null;
}

function read_integer(value, lo, hi) {
	return (is_js_integer(value) && value >= lo && value <= (hi ?? MAX_SAFE_INTEGER)) ? to_int(value) : null;
}

// What a panel's `fm` (xray finalmask JSON) adds to the link.
function parse_final_mask(value) {
	let hints = { quic: {} };

	if (value == null || js_trim(value) == '')
		return hints;

	let fm;

	try {
		fm = json_parse(value);
	}
	catch (e) {
		fail(HY2_FINALMASK_MESSAGE);
	}

	if (type(fm) != 'object')
		fail(HY2_FINALMASK_MESSAGE);

	if (exists(fm, 'udp')) {
		if (type(fm.udp) != 'array')
			fail(HY2_FINALMASK_MESSAGE);

		for (let mask in fm.udp) {
			if (type(mask) != 'object' || type(mask.type) != 'string')
				fail(HY2_FINALMASK_MESSAGE);

			let kind = lower(mask.type);
			let settings = (type(mask.settings) == 'object') ? mask.settings : {};

			if (kind == 'salamander' && !exists(settings, 'packetSize')) {
				if (hints.obfs_password == null && type(settings.password) == 'string')
					hints.obfs_password = settings.password;
			}
			else if (kind == 'udphop') {
				// Newer xray carries port hopping as a UDP mask; read it the same way.
				if (hints.hop_ports == null)
					hints.hop_ports = read_mask_ports(settings.remotePorts);
				if (hints.hop_interval == null)
					hints.hop_interval = parse_hop_interval(interval_value(settings.interval));
			}
			else
				fail(`Unsupported Hysteria 2 finalmask type: ${(kind == 'salamander') ? 'salamander with packetSize' : echoed(kind)}.`);
		}
	}

	if (exists(fm, 'quicParams')) {
		let quic = fm.quicParams;

		if (type(quic) != 'object')
			fail(HY2_FINALMASK_MESSAGE);

		let congestion = (type(quic.congestion) == 'string') ? lower(js_trim(quic.congestion)) : '';

		hints.congestion = (index(CONGESTION_CONTROLS, congestion) >= 0) ? congestion : null;
		hints.brutal_up = read_xray_bandwidth(quic.brutalUp);
		hints.brutal_down = read_xray_bandwidth(quic.brutalDown);

		if (type(quic.udpHop) == 'object') {
			if (hints.hop_ports == null)
				hints.hop_ports = read_mask_ports(quic.udpHop.ports);
			if (hints.hop_interval == null)
				hints.hop_interval = parse_hop_interval(interval_value(quic.udpHop.interval));
		}

		hints.quic = strip_null({
			initStreamReceiveWindow: read_integer(quic.initStreamReceiveWindow, 16384),
			maxStreamReceiveWindow: read_integer(quic.maxStreamReceiveWindow, 16384),
			initConnectionReceiveWindow: read_integer(quic.initConnectionReceiveWindow, 16384),
			maxConnectionReceiveWindow: read_integer(quic.maxConnectionReceiveWindow, 16384),
			maxIdleTimeout: read_integer(quic.maxIdleTimeout, 4, 120),
			keepAlivePeriod: read_integer(quic.keepAlivePeriod, 2, 60),
			disablePathMTUDiscovery: (quic.disablePathMTUDiscovery === true) ? true : null
		});
	}

	return hints;
}

// First value for any of the keys, keys matched without case.
function first_params(entries) {
	let values = {};

	for (let e in entries) {
		let k = lower(e[0]);

		// Object keys end at a NUL byte; such a key matches none of the names looked up.
		if (!has_nul(k) && !exists(values, k))
			values[k] = e[1];
	}

	return (...keys) => {
		for (let k in keys)
			if (exists(values, k))
				return values[k];

		return null;
	};
}

function hy2_host(raw) {
	if (js_length(raw) > HY2_MAX_HOST)
		fail(HY2_INVALID_MESSAGE);

	let host = (index(raw, ':') >= 0) ? ipv6_text(replace(raw, TAB_NEWLINE_G, '')) : special_host(raw);

	if (host == null)
		fail(HY2_INVALID_MESSAGE);

	return lc(host);
}

// hysteria2://[auth@]host[:ports]/?params#name, split by hand: WHATWG URL rejects port lists.
function read_hy2(link) {
	if (has_nul(link))
		fail(HY2_INVALID_MESSAGE);

	let rest = substr(link, index(link, '://') + 3);
	let cut = first_of(rest, '?#');
	let head = substr(rest, 0, cut), tail = substr(rest, cut), query = '';

	if (substr(tail, 0, 1) == '?') {
		let h = index(tail, '#');

		query = substr(tail, 1, (h >= 0) ? h - 1 : length(tail));
		tail = (h >= 0) ? substr(tail, h) : '';
	}

	let description = index(tail, '?serverDescription=');
	let fragment = (description >= 0) ? substr(tail, 0, description) : tail;

	// The auth may hold "/" or "@" when a panel didn't escape it, so the userinfo ends at the
	// last "@" and the authority at the first "/" after it.
	let at = rindex(head, '@');
	let userinfo = (at >= 0) ? substr(head, 0, at) : '';
	let after = (at >= 0) ? substr(head, at + 1) : head;
	let slash = index(after, '/');
	let authority = (slash >= 0) ? substr(after, 0, slash) : after;
	let raw_host, port_spec;

	if (substr(authority, 0, 1) == '[') {
		let end = index(authority, ']');
		let rest_ = (end >= 0) ? substr(authority, end + 1) : '';

		if (end < 0 || (rest_ != '' && substr(rest_, 0, 1) != ':'))
			fail(HY2_INVALID_MESSAGE);

		raw_host = substr(authority, 1, end - 1);
		port_spec = substr(rest_, 1);
	}
	else {
		let colon = index(authority, ':');

		raw_host = (colon >= 0) ? substr(authority, 0, colon) : authority;
		port_spec = (colon >= 0) ? substr(authority, colon + 1) : '';
	}

	if (raw_host == '')
		fail(HY2_HOST_MESSAGE);

	let host = hy2_host(raw_host);
	let written = (port_spec != '') ? read_port_list(port_spec) : [ [ HY2_DEFAULT_PORT, HY2_DEFAULT_PORT ] ];
	let port = written[0][0];
	let authority_ports = merge_ports(written);

	let entries = parse_form(query, form_decode_raw);
	let p = first_params(entries);
	let fm = parse_final_mask(p('fm'));

	// Explicit link keys win over the panel's fm JSON.
	let mport = js_trim(p('mport', 'mports') ?? '');
	let hop_ranges = (mport != '')
		? merge_ports(read_port_list(colon_ranges(mport)))
		: (covers_several(authority_ports) ? authority_ports : (fm.hop_ports ?? authority_ports));
	let hop_ports = covers_several(hop_ranges) ? format_ports(hop_ranges) : null;
	let hop_interval = (hop_ports == null) ? null
		: (parse_hop_interval(p('hopinterval', 'hop-interval', 'hop_interval', 'mporthopint'), p('hop_interval_max'))
			?? fm.hop_interval ?? HY2_DEFAULT_HOP_INTERVAL);

	let brutal_up = parse_bandwidth(p('up', 'upmbps')) ?? fm.brutal_up;
	let brutal_down = parse_bandwidth(p('down', 'downmbps')) ?? fm.brutal_down;
	// force-brutal without an upload rate makes xray refuse the whole config.
	let congestion = (fm.congestion == 'force-brutal' && !brutal_up) ? null : fm.congestion;

	let name = js_trim(pct_lenient(substr(fragment, 1)));
	let auth = pct_lenient(userinfo);
	let sni = js_trim(p('sni', 'peer') ?? '') || host;
	let obfs_password = read_obfs_password(p('obfs'), p('obfs-password', 'obfspassword', 'obfs_password'), fm.obfs_password);
	let pins = read_pins([ p('pinsha256'), p('pcs') ]);
	let insecure = parse_flag(p('insecure', 'allowinsecure', 'allow_insecure'));
	let vcn = js_trim(p('vcn') ?? '') || null;
	let ech = read_ech(p('ech'));

	if (auth == '')
		fail(HY2_PASSWORD_MESSAGE);

	return {
		protocol: 'hysteria2',
		host,
		port,
		name: name || `hysteria2-${host}:${port}`,
		transport: 'hysteria',
		security: 'tls',
		flow: '',
		hop_ports,
		// With a pin, insecure=1 is fine: the pin is what gets checked.
		insecure_without_pin: insecure && !length(pins),
		fingerprint: fingerprint(js_json({
			protocol: 'hysteria2',
			auth,
			host,
			ports: format_ports(authority_ports),
			params: lowered_entries(entries),
			hash: name
		})),
		auth,
		hop_interval,
		sni,
		obfs_password,
		pins,
		vcn,
		ech,
		congestion,
		brutal_up,
		brutal_down,
		quic: fm.quic
	};
}

// ---- Outbounds ------------------------------------------------------------------------------

// False for an unknown version: the config then takes the shape of the feed's 26.3.27.
function xray_at_least(version, minimum) {
	let m = rx(version ?? '', VERSION_RE);

	if (!m)
		return false;

	for (let i = 0; i < 3; i++)
		if (+m[i + 1] != minimum[i])
			return +m[i + 1] > minimum[i];

	return true;
}

// xray 26.9.9 moved port hopping from quicParams.udpHop to a "udphop" UDP mask.
function uses_udphop_mask(version) {
	return xray_at_least(version, [ 26, 9, 9 ]);
}

// xray 26.6.1 folded the header-* / mkcp-original / mkcp-aes128gcm masks into "mkcp-legacy".
function uses_mkcp_legacy_mask(version) {
	return xray_at_least(version, [ 26, 6, 1 ]);
}

function assert_supported(security, transport) {
	if (security == 'unknown')
		fail('Unsupported proxy security mode.');
	if (transport == 'unknown')
		fail(`Unsupported proxy transport: ${transport}.`);
	// xray loads such a config but its hysteria dialer refuses every connection.
	if (transport == 'hysteria' && security != 'tls')
		fail('The hysteria transport needs security=tls.');
	if (transport == 'http')
		fail('Xray no longer runs the HTTP/2 transport (type=h2 or http). Ask your provider for an XHTTP link.');
}

function tls_fingerprint(value) {
	let name = lower(js_trim(value ?? ''));

	if (name == '')
		return null;

	return (index(XRAY_TLS_FINGERPRINTS, name) >= 0) ? js_trim(value) : null;
}

function xray_network(transport) {
	if (transport == 'tcp')
		return null;

	return (transport == 'mkcp') ? 'kcp' : transport;
}

function parse_csv(value) {
	if (value == null)
		return null;

	let items = filter(map(split(value, ','), js_trim), (item) => item != '');

	return length(items) ? items : null;
}

function parse_int_range(value, lo, hi) {
	let text = js_trim(value ?? '');

	if (!rx(text, PORT_DIGITS_RE))
		return null;

	let n = +text;

	return (n >= lo && n <= hi) ? n : null;
}

function parse_congestion(value) {
	let c = lower(js_trim(value ?? ''));

	// force-brutal also needs an upload rate, which a share link rarely carries.
	return (c == 'reno' || c == 'bbr' || c == 'brutal') ? c : null;
}

// Xray 26 dropped kcpSettings.header and .seed: the obfuscation older mKCP servers apply by
// default has to be asked for with UDP masks. An xray 26 panel describes them in `fm`; an older
// link only has headerType and seed, which map to the header mask then the seed's cipher.
function legacy_mkcp_layers(header_type, host, seed) {
	let kind = lower(js_trim(header_type ?? ''));
	let header = (kind == 'wechat-video') ? 'wechat' : kind;
	let layers = [];

	if (header != '' && header != 'none') {
		if (index(MKCP_HEADERS, header) < 0)
			fail(`Unsupported mKCP header type: ${header_type}.`);

		push(layers, { header, domain: (header == 'dns') ? (js_trim(host ?? '') || null) : null });
	}

	push(layers, { seed: seed ?? '' });

	return layers;
}

function mkcp_fm_layers(value) {
	if (value == null || js_trim(value) == '')
		return null;

	let fm;

	try {
		fm = json_parse(value);
	}
	catch (e) {
		fail(MKCP_FINALMASK_MESSAGE);
	}

	if (type(fm) != 'object' || !exists(fm, 'udp'))
		return null;
	if (type(fm.udp) != 'array')
		fail(MKCP_FINALMASK_MESSAGE);

	return map(fm.udp, (mask) => {
		let kind = (type(mask) == 'object' && type(mask.type) == 'string') ? lower(mask.type) : '';
		let settings = (type(mask) == 'object' && type(mask.settings) == 'object') ? mask.settings : {};
		let text = (k) => (type(settings[k]) == 'string') ? settings[k] : '';

		if (kind == 'mkcp-original')
			return { seed: '' };
		if (kind == 'mkcp-aes128gcm')
			return { seed: text('password') };

		if (kind == 'mkcp-legacy') {
			let header = lower(text('header'));

			if (header == '')
				return { seed: text('value') };
			if (index(MKCP_HEADERS, header) >= 0)
				return { header, domain: (header == 'dns') ? (text('value') || null) : null };
		}

		let header = (substr(kind, 0, 7) == 'header-') ? substr(kind, 7) : '';

		if (index(MKCP_HEADERS, header) >= 0)
			return { header, domain: (header == 'dns') ? (text('domain') || null) : null };

		fail(`Unsupported finalmask type for mKCP: ${kind || '?'}.`);
	});
}

function mkcp_mask(layer, legacy) {
	if (exists(layer, 'seed')) {
		if (legacy)
			return { type: 'mkcp-legacy', settings: { header: '', value: layer.seed } };

		return (layer.seed != '')
			? { type: 'mkcp-aes128gcm', settings: { password: layer.seed } }
			: { type: 'mkcp-original', settings: {} };
	}

	if (legacy)
		return { type: 'mkcp-legacy', settings: { header: layer.header, value: layer.domain ?? '' } };

	return { type: `header-${layer.header}`, settings: (layer.domain != null) ? { domain: layer.domain } : {} };
}

function mkcp_masks(parts) {
	let layers = mkcp_fm_layers(parts.finalmask) ?? legacy_mkcp_layers(parts.type, parts.host, parts.seed);
	let legacy = uses_mkcp_legacy_mask(parts.xray_version);

	return map(layers, (layer) => mkcp_mask(layer, legacy));
}

function stream_settings(parts) {
	let hysteria = (parts.transport == 'hysteria');
	let quic = hysteria ? strip_null({
		congestion: parse_congestion(parts.congestion),
		brutalUp: parse_bandwidth(parts.up),
		brutalDown: parse_bandwidth(parts.down)
	}) : {};
	let masks = (parts.transport == 'mkcp') ? mkcp_masks(parts) : [];
	let fp = js_trim(parts.fingerprint ?? '') || null;
	// v2rayN writes the gRPC mode as `mode` in links and as `type` in VMess JSON.
	let multi = (lower(js_trim(parts.mode ?? '')) == 'multi' || lower(js_trim(parts.type ?? '')) == 'multi');
	let s = {};

	if (xray_network(parts.transport) != null)
		s.network = xray_network(parts.transport);
	if (parts.security != 'none')
		s.security = parts.security;

	if (parts.security == 'tls')
		s.tlsSettings = strip_null({
			// xray's QUIC dialer sends the SNI "hysteria" unless one is set.
			serverName: ascii_server_name(parts.sni) ?? (hysteria ? parts.server_host : null),
			alpn: parse_csv(parts.alpn),
			// uTLS shapes a TCP handshake only, so QUIC transports go without.
			fingerprint: (hysteria || parts.transport == 'mkcp') ? null : tls_fingerprint(fp),
			// xray 26 dropped allowInsecure: a self-signed server is accepted by its pin or name only
			pinnedPeerCertSha256: length(parts.pins ?? []) ? join(',', parts.pins) : null,
			verifyPeerCertByName: parts.vcn
		});

	if (parts.security == 'reality')
		s.realitySettings = strip_null({
			serverName: ascii_server_name(parts.sni),
			publicKey: parts.public_key,
			shortId: parts.short_id,
			spiderX: (parts.spider_x != null && parts.spider_x != '') ? parts.spider_x : null,
			fingerprint: fp
		});

	if (parts.transport == 'ws')
		s.wsSettings = strip_null({ path: parts.path, headers: (parts.host ?? '') != '' ? { Host: parts.host } : null });
	if (parts.transport == 'grpc')
		s.grpcSettings = strip_null({ serviceName: parts.service_name ?? parts.path, multiMode: multi ? true : null });
	if (parts.transport == 'tcp' && (parts.type ?? '') != '')
		s.tcpSettings = { header: { type: parts.type } };
	if (parts.transport == 'xhttp')
		s.xhttpSettings = strip_null({ host: parts.host, path: parts.path, mode: parts.mode });
	if (parts.transport == 'httpupgrade')
		s.httpupgradeSettings = strip_null({ host: parts.host, path: parts.path });
	if (parts.transport == 'mkcp')
		s.kcpSettings = strip_null({ mtu: parse_int_range(parts.mtu, 576, 1460), tti: parse_int_range(parts.tti, 10, 100) });
	if (hysteria)
		s.hysteriaSettings = strip_null({ version: 2, auth: parts.auth });

	if (length(keys(quic)) || length(masks))
		s.finalmask = strip_null({
			udp: length(masks) ? masks : null,
			quicParams: length(keys(quic)) ? quic : null
		});

	return s;
}

function build_uri(rd, opts) {
	let e = rd.entries;
	let p = (k) => param(e, k);
	let security = normalize_security(uri_security_text(rd.protocol, e));
	let transport = builder_transport(p('type') ?? p('net') ?? 'tcp');

	assert_supported(security, transport);

	// Xray 26 share links pin a TLS certificate with pcs and name the one to verify with vcn. The
	// desktop reads them for Hysteria 2 only; the router takes them for every TLS link (DESIGN §7.4).
	let tls = (security == 'tls');

	let stream = stream_settings({
		security, transport, server_host: rd.host, xray_version: opts.xray_version,
		pins: tls ? read_pins([ p('pcs') ], TLS_PIN_MESSAGE) : null, vcn: tls ? (js_trim(p('vcn') ?? '') || null) : null,
		host: p('host'), path: p('path'), type: p('headerType') ?? p('header'), service_name: p('serviceName'),
		sni: p('sni') ?? p('servername'), alpn: p('alpn'), public_key: p('pbk'), short_id: p('sid'),
		spider_x: p('spx'), fingerprint: p('fp'), mode: p('mode'), seed: p('seed'), mtu: p('mtu'),
		tti: p('tti'), finalmask: p('fm'), auth: p('auth'), congestion: p('congestion'),
		up: p('upMbps') ?? p('up'), down: p('downMbps') ?? p('down')
	});

	if (rd.protocol == 'trojan')
		return {
			protocol: 'trojan',
			tag: OUTBOUND_TAG,
			settings: { servers: [ { address: rd.host, port: rd.port, password: rd.secret } ] },
			streamSettings: stream
		};

	let user = { id: rd.secret, encryption: p('encryption') ?? 'none' };

	if (p('flow') != null)
		user.flow = p('flow');
	if (!vless_encryption_valid(user.encryption))
		fail(VLESS_ENCRYPTION_MESSAGE);

	return {
		protocol: 'vless',
		tag: OUTBOUND_TAG,
		settings: { vnext: [ { address: rd.host, port: rd.port, users: [ user ] } ] },
		streamSettings: stream
	};
}

function build_vmess(rd, opts) {
	let payload = (type(rd.payload) == 'object') ? rd.payload : {};
	let text = (k) => vmess_text(payload[k]);
	let host = host_to_ascii(text('add') ?? '');

	if (!host)
		fail(VMESS_ADDRESS_MESSAGE);

	let security = normalize_security(vmess_security_text(payload.tls));
	let transport = builder_transport(text('net') ?? 'tcp');

	assert_supported(security, transport);

	let alter_id = to_int(js_to_number(payload.aid ?? 0));
	let path = text('path');

	return {
		protocol: 'vmess',
		tag: OUTBOUND_TAG,
		settings: {
			vnext: [ {
				address: host,
				port: to_int(js_to_number(payload.port)),
				users: [ { id: text('id'), alterId: is_finite(alter_id) ? alter_id : null, security: text('scy') ?? 'auto' } ]
			} ]
		},
		streamSettings: stream_settings({
			security, transport, server_host: host, xray_version: opts.xray_version,
			host: text('host'), path, type: text('headerType') ?? text('type'), sni: text('sni'),
			alpn: text('alpn'), fingerprint: text('fp'), mode: text('mode'),
			// v2rayN keeps an mKCP seed in "path".
			seed: text('seed') ?? ((transport == 'mkcp') ? path : null)
		})
	};
}

// xray's native Hysteria 2 client: QUIC, so TLS is mandatory and ALPN is h3. insecure=1 has no
// xray equivalent any more (allowInsecure fails the whole config); only a pin accepts a
// self-signed certificate.
function build_hy2(rd, opts) {
	let hop = (rd.hop_ports != null) ? { ports: rd.hop_ports, interval: rd.hop_interval ?? HY2_DEFAULT_HOP_INTERVAL } : null;
	let hop_mask = (hop != null && uses_udphop_mask(opts.xray_version));
	let udp = [];

	// A udphop mask dials its own sockets, so xray requires it first.
	if (hop_mask)
		push(udp, { type: 'udphop', settings: { mode: 'intervallocal,intervalremote', interval: hop.interval, remotePorts: hop.ports } });
	if (rd.obfs_password != null)
		push(udp, { type: 'salamander', settings: { password: rd.obfs_password } });

	let quic = strip_null({
		congestion: rd.congestion,
		brutalUp: rd.brutal_up,
		brutalDown: rd.brutal_down,
		// Always with an explicit interval: xray 26.3 overflows its hop timer without one.
		udpHop: (hop != null && !hop_mask) ? hop : null
	});

	for (let k in rd.quic)
		quic[k] = rd.quic[k];

	let stream = {
		network: 'hysteria',
		security: 'tls',
		hysteriaSettings: { version: 2, auth: rd.auth },
		tlsSettings: strip_null({
			// Required: without it xray's QUIC dialer sends the SNI "hysteria".
			serverName: ascii_server_name(rd.sni),
			alpn: [ 'h3' ],
			pinnedPeerCertSha256: length(rd.pins) ? join(',', rd.pins) : null,
			verifyPeerCertByName: rd.vcn,
			echConfigList: rd.ech
		})
	};

	if (length(udp) || length(keys(quic)))
		stream.finalmask = strip_null({ udp: length(udp) ? udp : null, quicParams: length(keys(quic)) ? quic : null });

	return {
		protocol: 'hysteria',
		tag: OUTBOUND_TAG,
		settings: { version: 2, address: rd.host, port: rd.port },
		streamSettings: stream
	};
}

// ---- Entry points ---------------------------------------------------------------------------

// The link as stored: trimmed, and with broken UTF-8 replaced as a JS string would hold it.
function prepare(link) {
	link = js_trim((type(link) == 'string') ? link : '');

	if (length(link) > LIMITS.link_chars)
		fail(`Proxy link is longer than ${LIMITS.link_chars} characters.`);

	return utf8_fix(link);
}

// The DNS limit for a host name, as Hysteria 2 links already have it (an IP literal passes; labels stay
// as the desktop takes them): config.load() drops a profile whose host is longer than 255, so the import
// must not store one.
function check_host_length(host) {
	if (type(host) == 'string' && index(host, ':') < 0 && length(host) > 253)
		fail(HOST_LENGTH_MESSAGE);
}

function read_link(link) {
	let protocol = detect_protocol(link), rd;

	if (protocol == null)
		fail(UNSUPPORTED_SCHEME_MESSAGE);

	if (protocol == 'vmess')
		rd = read_vmess(link);
	else if (protocol == 'hysteria2')
		rd = read_hy2(link);
	else
		rd = read_uri(link, protocol);

	check_host_length(rd?.host);

	return rd;
}

// A host as an address xray or a SOCKS server can use: an internationalised name in punycode, null when
// it is not a host (tunnel-check, for a check endpoint the settings accept in Unicode).
export function ascii_host(value) {
	if (type(value) != 'string' || value == '')
		return null;

	let host = host_to_ascii(value);

	return (host != null && match(host, /^[A-Za-z0-9._:-]+$/)) ? host : null;
};

function build(rd, opts) {
	if (rd.protocol == 'vmess')
		return build_vmess(rd, opts);
	if (rd.protocol == 'hysteria2')
		return build_hy2(rd, opts);

	return build_uri(rd, opts);
}

// A profile name is one line of display text: control characters and the Unicode line and
// paragraph separators become spaces, and it is cut to 64 code points.
export function normalize_name(s) {
	if (type(s) != 'string')
		return '';

	s = utf8_fix(s);

	if (!plain_ascii(s) || has_any(s, '\t\n\r')) {
		let out = [];

		for (let i = 0, n = length(s); i < n; ) {
			let k = utf8_seq(s, i), cp = utf8_cp(s, i, k);

			push(out, (cp < 0x20 || (cp >= 0x7f && cp <= 0x9f) || cp == 0x2028 || cp == 0x2029) ? ' ' : substr(s, i, k));
			i += k;
		}

		s = join('', out);
	}

	s = js_trim(s);

	let cut = 0, count = 0;

	while (cut < length(s) && count < MAX_PROFILE_NAME) {
		cut += utf8_seq(s, cut);
		count++;
	}

	return js_trim_end(substr(s, 0, cut));
};

function profile_of(rd) {
	let problem = null;

	try {
		build(rd, {});
	}
	catch (e) {
		problem = caught(e);
	}

	let profile = {
		name: normalize_name(rd.name) || `${rd.protocol}-${rd.host}:${rd.port}`,
		protocol: rd.protocol,
		host: rd.host,
		port: rd.port,
		hop_ports: rd.hop_ports ?? '',
		transport: rd.transport,
		security: rd.security,
		flow: rd.flow,
		insecure_without_pin: rd.insecure_without_pin ?? false,
		supported: problem == null,
		fingerprint: rd.fingerprint,
		hosts: [ rd.host ]
	};

	if (problem != null)
		profile.problem = problem;

	return profile;
}

// One share link to a profile. `link` is the trimmed input, the text stored as the secret.
export function parse(link) {
	try {
		let text = prepare(link);

		return { ok: true, profile: profile_of(read_link(text)), link: text };
	}
	catch (e) {
		return { ok: false, error: caught(e) };
	}
};

// Many links, one per line; blank lines and # comments are skipped.
export function parse_import(text) {
	if (type(text) != 'string')
		text = '';

	if (length(text) > LIMITS.import_chars)
		return {
			results: [ { line: 0, ok: false, error: `Import text is longer than ${LIMITS.import_chars} characters.` } ],
			skipped: 0
		};

	let lines = split(text, '\n'), results = [], skipped = 0;

	if (length(lines) > LIMITS.import_lines)
		push(results, { line: 0, ok: false,
			error: `Import contains ${length(lines)} lines; maximum is ${LIMITS.import_lines}. Extra lines were ignored.` });

	for (let i = 0; i < length(lines) && i < LIMITS.import_lines; i++) {
		let raw = lines[i];

		if (substr(raw, -1) == '\r')
			raw = substr(raw, 0, length(raw) - 1);

		let line = js_trim(raw);

		if (line == '' || substr(line, 0, 1) == '#') {
			skipped++;
			continue;
		}

		if (length(line) > LIMITS.link_chars) {
			push(results, { line: i + 1, ok: false, error: `Line ${i + 1}: proxy link is longer than ${LIMITS.link_chars} bytes.` });
			continue;
		}

		let r = parse(line);

		push(results, r.ok
			? { line: i + 1, ok: true, profile: r.profile, link: r.link }
			: { line: i + 1, ok: false, error: `Line ${i + 1}: ${r.error}` });
	}

	return { results, skipped };
};

// The xray outbound (tag "proxy", no sockopt) for a stored link. `opts.xray_version` picks the
// shape where xray releases differ; without it the shape of the feed's 26.3.27 is used.
export function outbound(link, opts) {
	try {
		let text = prepare(link);

		if (detect_protocol(text) == null)
			fail('Unsupported proxy URI protocol.');

		return { ok: true, outbound: build(read_link(text), (type(opts) == 'object') ? opts : {}) };
	}
	catch (e) {
		return { ok: false, error: caught(e) };
	}
};
