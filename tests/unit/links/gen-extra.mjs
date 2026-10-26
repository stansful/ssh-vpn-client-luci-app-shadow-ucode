// Extra parity vectors for links_test.uc, computed by the desktop app's own code (read-only).
// DESKTOP_SRC is a checkout of https://github.com/stansful/ssh-vpn-client-electron; the committed
// tests/unit/links/extra.json is the source of truth for the tests. Run from this repository's root:
//   DESKTOP_SRC=../ssh-vpn-client-electron node --import ./tests/unit/vectors/register.mjs \
//     tests/unit/links/gen-extra.mjs > tests/unit/links/extra.json
// Every link here has well-formed credentials, so the router must agree with the desktop exactly.
import { createHash } from "node:crypto";
import { desktopModule } from "../vectors/desktop.mjs";
const P = desktopModule("src/core/proxy/");
const { parseProxyShareLink, parseProxyShareLinks } = await import(P + "share-link-parser.ts");
const { buildOutbound } = await import(P + "xray-config.ts");

const U = "11111111-1111-4111-8111-111111111111";
const U2 = "22222222-2222-4222-8222-222222222222";
const PBK = "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw";
const PIN = "ba88452f1b0c1a3c4d7e6f5a49382716ba88452f1b0c1a3c4d7e6f5a49382716";
const pinB64Url = Buffer.from(PIN, "hex").toString("base64url");
const vm = (o) => `vmess://${Buffer.from(JSON.stringify(o), "utf8").toString("base64")}`;
const vmRaw = (text) => `vmess://${Buffer.from(text, "utf8").toString("base64")}`;
const fmq = (o) => encodeURIComponent(JSON.stringify(o));
const NEW = "26.9.30";

// [link, { xray: false } when xray itself refuses the desktop's outbound]
const cases = [
  // Query keys: case, duplicates, punctuation order (localeCompare), plus and percent decoding.
  [`vless://${U}@EXAMPLE.com:443?Type=ws&type=grpc&sni=a&SNI=b&a_b=1&a-b=2&a.b=3&a~b=4&a1=5&_x=6&-x=7&.x=8&ab=9&aB=10#Keys`],
  [`vless://${U}@example.com:443?a+b=c+d&%41=%42&%zz=%4&e=%E2%82%AC&f=%C3%28&g&=h&&i==j#plus`],
  [`vless://${U}@example.com:443?security=TLS&type=RAW&headerType=http&alpn=%20h2%20,,http/1.1&fp=CHROME#upper`],
  [`vless://${U}@example.com:443?tls=1&net=ws&host=cdn.example.com&path=%2Fp%3Fq%3D1#legacy-tls`],
  [`vless://${U}@example.com:443?type=&security=tls#empty-type`],
  [`vless://${U}@example.com:443?type=grpc&security=tls&mode=MULTI&serviceName=s#multi`],
  [`vless://${U}@example.com:443?type=http_upgrade&host=h.example&path=%2Fu#hu`],
  [`vless://${U}@example.com:443?type=xhttp&security=reality&sni=www.example.com&pbk=${PBK}&sid=&spx=%2F&fp=firefox#reality-empty-sid`],
  [`vless://${U}@example.com:443?type=tcp&security=reality&pbk=${PBK}&sid=0123456789abcdef&flow=xtls-rprx-vision-udp443#reality-no-sni`],
  [`vless://${U}@example.com:443?type=hysteria&security=tls&auth=pw&up=100%20mbps&down=1.5gbps&congestion=Brutal#vless-hy`],
  [`vless://${U}@example.com:443?type=ws&security=tls&sni=%D0%9F%D0%A0%D0%98%D0%9C%D0%95%D0%A0.%D0%A0%D0%A4#idn-sni-upper`],
  [`vless://${U}@example.com:443?type=kcp&headerType=SRTP&seed=&mtu=%201350&tti=20#kcp-srtp`],
  [`vless://${U}@example.com:443?type=kcp&fm=${fmq({ udp: [{ type: "header-dns", settings: { domain: "d.example" } }, { type: "mkcp-original" }] })}#kcp-fm-dns`],
  [`vless://${U}@example.com:443?type=kcp&fm=${fmq({ udp: [] })}&headerType=utp#kcp-fm-empty`],
  [`vless://${U}@example.com:443?type=kcp&fm=${fmq({ quicParams: {} })}&headerType=dtls&seed=x#kcp-fm-no-udp`],
  [`vless://${U}@example.com:443?type=kcp&fm=%7Bbad#kcp-fm-bad`],
  [`vless://${U}@example.com:443?type=kcp&fm=${fmq({ udp: [{ type: "mkcp-legacy", settings: { header: "bogus" } }] })}#kcp-fm-legacy-bogus`],
  // Userinfo, fragment and host encodings that the fingerprint hashes.
  ["trojan://pa ss\"<>`{}|^;=[]\\@host.example:443#enc-user"],
  ["trojan://пароль@host.example:443#nonascii-pass"],
  ["trojan://a@b@host.example:443#at-in-pass"],
  ["trojan://p%41ss@host.example:443?security=none#pct-pass"],
  [`vless://${U}@example.com:443#Привет мир "q" <x> \`b\``],
  [`vless://${U}@example.com:443#100%`],
  [`vless://${U}@example.com:443#%F0%9F%98%80%20emoji%20`],
  [`vless://${U}@example.com:443#%C3%A9t%C3%A9`],
  [`vless://${U}@example.com:443#a%20b%zz`],
  [`vless://${U}@example.com:443#   `],
  [`vless://${U}@ПРИМЕР.РФ:443?security=tls#idn-upper`],
  [`vless://${U}@xn--e1afmkfd.xn--p1ai:443#punycode`],
  ["trojan://s@straße.de:443#sharp-s"],
  ["trojan://s@Ελλάδα.gr:443#greek"],
  ["trojan://s@例子。中国:443#cjk-dot"],
  ["trojan://s@ex%41mple.com:443#pct-host"],
  ["trojan://s@%D0%BF%D1%80%D0%B8%D0%BC%D0%B5%D1%80.%D1%80%D1%84:443#pct-idn"],
  [`vless://${U}@[::ffff:1.2.3.4]:443#v4mapped`],
  [`vless://${U}@[1:0:0:2:0:0:0:3]:443#v6-first-run`],
  [`vless://${U}@[0:0:0:0:0:0:0:1]:443#v6-loopback`],
  [`vless://${U}@[2001:db8::]:443#v6-tail`],
  [`vless://${U}@example.com:00443#zeros`],
  [`vless://${U}@example.com:65535#max-port`],
  [`vless://${U}@example.com:65536#over-port`],
  [`vless://${U}@example.com:#empty-port`],
  [`vless://${U}@example.com:443/path/x?type=ws#with-path`],
  [`vless://${U}@exa\tmple.com:443?type=w\ns#na\tme`],
  [`vless://${U}@example.com:443\u0001`],
  [`vless://${U}@exa mple.com:443`],
  [`vless://${U}@exa^mple.com:443`],
  [`vless://${U}@:443`],
  [`vless://${U}@`],
  [`vless://${U}@example.com:443x`],
  ["VLESS://" + U + "@Example.com:443?SECURITY=tls#scheme-case"],
  // VMess: field types, JS property order, numbers and strings as JSON.stringify writes them.
  [vm({ v: 2, ps: "x", add: "Host.Example.COM", port: "0x1BB", id: U2, aid: "0", net: "WS", type: "none", host: "", path: "/", tls: "TLS", sni: "", alpn: "", fp: "" })],
  [vm({ 10: 1, 9: 2, b: { z: 1, 2: 3, a: [1, { y: null }] }, add: "h.example", port: 443, id: U2, A: 1, a: 2, "a-b": 3, a_b: 4 })],
  [vmRaw(`{"x":1.5e-7,"y":1e21,"z":0.1,"w":-0,"v":1E2,"u":123456789012345680000,"t":0.000001,"add":"h.example","port":443.0,"id":"${U2}","aid":1.0}`)],
  [vm({ ps: "Тест \u0001 \"q\" \\ /  ", add: "h.example", port: 443, id: U2, extra: "\u007f\u0000" })],
  [`vmess://${Buffer.from(JSON.stringify({ add: "h.example", port: 443, id: U2, ps: "ws" })).toString("base64url").replace(/(.{10})/g, "$1\n ")}`],
  [vm({ add: "h.example", port: 443, id: U2, tls: true, net: "kcp", type: "wechat-video", seed: "s" })],
  [vm({ add: "h.example", port: " 443 ", id: U2, net: "grpc", path: "svc", type: "gun", tls: "tls", alpn: "h2,http/1.1", fp: "hellogolang" })],
  [vm({ add: "h.example", port: "443.0", id: U2 })],
  [vm({ add: 1234, port: 443, id: U2 })],
  [vm({ add: "h.example", port: 443, id: U2, scy: "none", aid: "abc" })],
  [vm({ add: "h.example", port: 443, id: U2, tls: "reality", sni: "s.example", fp: "chrome" }), { xray: false }],
  [vm({ add: "h.example", port: 443, id: U2, net: "httpupgrade", host: "u.example", path: "/u", tls: 1 })],
  [vm({ add: "h.example", port: 443, id: U2, net: "xhttp", host: "x.example", path: "/x", mode: "stream-one", tls: "tls", sni: "пример.рф" })],
  [vm({ add: "[2001:db8::1]", port: 443, id: U2, ps: "  " })],
  [vm({ add: "h.example", port: 443, id: U2, flow: 5, ps: 7 })],
  [vm({ add: "h.example", port: 0, id: U2 })],
  [vm({ add: "h.example", port: 443.5, id: U2 })],
  [vm({ add: "", port: 443, id: U2 })],
  [vm([1, 2])],
  [vmRaw("{'add':'h','port':443}")],
  [vmRaw(`{"add":"h","port":443,}`)],
  [vmRaw(`﻿{"add":"h","port":443}`)],
  [vmRaw(`{"add":"h","port":443} /* c */`)],
  ["vmess://" + Buffer.from(JSON.stringify({ add: "h.example", port: 443, id: U2 })).toString("base64").replace(/=+$/, "")],
  ["vmess://" + "!!" + Buffer.from(JSON.stringify({ add: "h.example", port: 443, id: U2 })).toString("base64")],
  // Hysteria 2.
  [`hysteria2://user:pa%20ss@Example.COM:443,1000-2000/?SNI=sni.example&OBFS=Salamander&obfs_password=x&pcs=${pinB64Url}&hop-interval=10-20&upmbps=100&downmbps=200#%E2%9C%93%20ok`],
  [`hy2://pw@example.com:443?fm=${fmq({ quicParams: { congestion: " Reno ", brutalUp: "100 Mbps", brutalDown: "1g", initStreamReceiveWindow: 16384, maxStreamReceiveWindow: 100000, initConnectionReceiveWindow: 1000, maxConnectionReceiveWindow: 1e6, maxIdleTimeout: 120, keepAlivePeriod: 60, disablePathMTUDiscovery: true, udpHop: { ports: "2000:3000,4000", interval: 15 } } })}`],
  ["hysteria2://pw@[::1]#v6-no-port"],
  ["hysteria2://pw@[abc]:443#bracket-name"],
  ["hysteria2://pw@exa\\mple.com:443#backslash"],
  ["hysteria2://pw@0x7f.1:443#hex-ip"],
  ["hysteria2://pw@010.0.0.1#octal-ip"],
  ["hysteria2://pw@1.2.3#short-ip"],
  ["hysteria2://pw@a.1#bad-ip"],
  ["hysteria2://pw@ｅｘａｍｐｌｅ．ｃｏｍ#fullwidth"],
  ["hysteria2://pw@%65xample.com#pct-host"],
  ["hysteria2://pw@example.com#100%25?serverDescription=x#y"],
  ["hysteria2://pw@example.com#%zz name"],
  ["hysteria2://p%zz@example.com#bad-auth-pct"],
  ["hysteria2://pw@example.com/?up=10+mbps&down=0.6#plus"],
  // The desktop writes the huge rate as "1e+27 bps", which xray refuses; kept for parity.
  ["hysteria2://pw@example.com?up=1.2345678&down=999999999999999999999#rates", { xray: false }],
  ["hysteria2://pw@example.com:443,445-444,446?hopInterval=1s-2s#merge"],
  ["hysteria2://pw@example.com:20000-30000?hop_interval=7&hop_interval_max=7s#same"],
  ["hysteria2://pw@example.com:20000-30000?hop_interval=%2010%20s#spaces"],
  [`hysteria2://pw@example.com?pinSHA256=${PIN.toUpperCase()}&pinSHA256=ignored&insecure=YES#pin-upper`],
  ["hysteria2://pw@example.com?insecure=0&allowInsecure=1#insecure-order"],
  ["hysteria2://pw@example.com?obfs=PLAIN&obfs-password=x#plain"],
  [`hysteria2://pw@example.com?fm=${fmq({ udp: [{ type: "salamander", settings: { password: "" } }] })}#empty-mask-pw`],
  [`hysteria2://pw@example.com?fm=${fmq({ udp: [{ type: "salamander", settings: { password: 5 } }], quicParams: null })}#bad-quic`],
  [`hysteria2://pw@example.com?fm=${fmq({ udp: null })}#null-udp`],
  [`hysteria2://pw@example.com?fm=${fmq([])}#array-fm`],
  [`hysteria2://pw@example.com?fm=%20%20#blank-fm`],
  [`hysteria2://pw@example.com:1000-2000?fm=${fmq({ udp: [{ type: "udphop", settings: { remotePorts: 5000, interval: "3" } }] })}#udphop-number`],
  [`hysteria2://pw@example.com?vcn=%20%20&sni=%20#blank-tls`],
  [`hysteria2://pw@example.com?ech=${encodeURIComponent(Buffer.from([0, 4, 1, 2, 3, 4]).toString("base64url"))}#ech-url`],
  ["hysteria2://pw@example.com?obfs=" + "x".repeat(60) + "#long-obfs"],
  ["hysteria2://pw@" + "b".repeat(253) + "#max-host"],
  ["hy2://pw@example.com:443/?Mport=%2020000%20-%2030000%20#mport-spaces"],
];

// Links whose outbound also differs on xray >= 26.9.9 / 26.6.1.
const versioned = new Set([
  `vless://${U}@example.com:443?type=kcp&headerType=SRTP&seed=&mtu=%201350&tti=20#kcp-srtp`,
  `vless://${U}@example.com:443?type=kcp&fm=${fmq({ udp: [{ type: "header-dns", settings: { domain: "d.example" } }, { type: "mkcp-original" }] })}#kcp-fm-dns`,
  `hysteria2://user:pa%20ss@Example.COM:443,1000-2000/?SNI=sni.example&OBFS=Salamander&obfs_password=x&pcs=${pinB64Url}&hop-interval=10-20&upmbps=100&downmbps=200#%E2%9C%93%20ok`,
  `hy2://pw@example.com:443?fm=${fmq({ quicParams: { congestion: " Reno ", brutalUp: "100 Mbps", brutalDown: "1g", initStreamReceiveWindow: 16384, maxStreamReceiveWindow: 100000, initConnectionReceiveWindow: 1000, maxConnectionReceiveWindow: 1e6, maxIdleTimeout: 120, keepAlivePeriod: 60, disablePathMTUDiscovery: true, udpHop: { ports: "2000:3000,4000", interval: 15 } } })}`,
  vm({ add: "h.example", port: 443, id: U2, tls: true, net: "kcp", type: "wechat-video", seed: "s" })
]);

const run = (fn) => { try { return fn(); } catch (e) { return { error: e.message }; } };
const out = [];
for (const [link, flags] of cases) {
  const v = { link, stored: link.trim() };
  v.parse = run(() => { const p = parseProxyShareLink(link.trim()); delete p.rawUri; return p; });
  v.outbound = run(() => buildOutbound(link.trim()));
  if (versioned.has(link)) v.outbound_new = run(() => buildOutbound(link.trim(), { xrayVersion: NEW }));
  if (flags?.xray === false) v.xray = false;
  out.push(v);
}

// A fixed corpus of mutated links (seeded, so the file is reproducible). Mutations stay after the
// credentials, which the router checks more strictly than the desktop.
let seed = Number(process.env.FUZZ_SEED ?? 0x5eed);
const rand = () => {
  seed = (seed + 0x6d2b79f5) | 0;
  let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const pick = (a) => a[Math.floor(rand() * a.length)];
const POOL = [
  "%", "%4", "%41", "%zz", "%C3%A9", "%E2%80%A8", "%00", "%0A", "%25", "%2F", "%3A", "%40", "%5B", "%5D",
  "é", "Ж", "ß", "Σ", "例", "　", " ", "﻿", " ", "\t", " ", "+", ".", "-", "_", "~", ",", ";",
  "=", "&", "?", "#", "/", ":", "@", "[", "]", "\\", "^", "|", "<", ">", "\"", "'", "`", "{", "}", "*", "!",
  "$", "a", "Z", "0", "9", "xn--", "..", "::", "0x", "1.2.3.4", "[::1]", "😀", "æ", "œ", "ø", "đ", "ł", "þ", "ı",
  "й", "ё", "€", "☃", "Ｅ", "%EF%BC%A5", "%C2%A0", "%E3%80%80", "%EF%BB%BF"
];
const mutate = (link, safeFrom) => {
  let s = link;
  const ops = 1 + Math.floor(rand() * 3);
  for (let k = 0; k < ops; k++) {
    const at = safeFrom + Math.floor(rand() * (s.length - safeFrom + 1));
    const op = rand();
    if (op < 0.55) s = s.slice(0, at) + pick(POOL) + s.slice(at);
    else if (op < 0.75) s = s.slice(0, at) + s.slice(at + 1 + Math.floor(rand() * 3));
    else if (op < 0.9) s = s.slice(0, at) + s.slice(at, at + 1).toUpperCase() + s.slice(at + 1);
    else s = s.slice(0, at) + s.slice(at, at + 4) + s.slice(at);
  }
  return s;
};
const TEMPLATES = [
  `vless://${U}@example.com:443?type=ws&security=tls&sni=cdn.example.com&host=h.example&path=%2Fws&alpn=h2,http/1.1&fp=chrome#Name`,
  `vless://${U}@пример.рф:8443?type=grpc&security=tls&serviceName=svc&mode=multi#Сервер 1`,
  `vless://${U}@[2001:db8::1]:443?type=xhttp&security=tls&path=%2Fx&mode=auto#v6`,
  `vless://${U}@example.com:443?type=kcp&headerType=dns&host=d.example&seed=s&mtu=1350#kcp`,
  `vless://${U}@example.com:443?type=hysteria&security=tls&auth=pw&up=50&down=100&congestion=bbr#hy`,
  "trojan://secret@host.example:443?security=tls&sni=s.example&type=httpupgrade&path=%2Fu#tr",
  "trojan://secret@MÜNCHEN.de:443?allowInsecure=0&peer=p.example#de",
  `hysteria2://pw@example.com:443,20000-30000/?sni=s.example&obfs=salamander&obfs-password=x&pinSHA256=${PIN}&up=50&down=100&hop_interval=10#hy2`,
  `hy2://user:pass@[2001:db8::1]:443/?insecure=1&fm=${fmq({ quicParams: { congestion: "bbr", maxIdleTimeout: 30 } })}#v6`,
  "hysteria2://pw@node.example.com/?mport=1000:2000&ech=AAP%2BDQA%3D&vcn=v.example#Tokyo%201?serverDescription=x"
];
const credentialEnd = (t) => t.indexOf("@") + 1;
const fuzz = [];
for (let n = 0; n < Number(process.env.FUZZ_URI ?? 600); n++) {
  const t = pick(TEMPLATES);
  fuzz.push(mutate(t, credentialEnd(t)));
}
const VMESS_FIELDS = {
  ps: ["n", " Имя ", "", 7, null, "a\u0001b"], add: ["vmess.example.com", "Пример.рф", "[2001:db8::1]", " h.example ", "h.example.", "%41.example", 12, "a b"],
  port: [443, "443", " 8443 ", "0x1BB", 443.0, "1e3", true, [443], "443abc"], net: ["ws", "grpc", "kcp", "tcp", "raw", "h2", "xhttp", "httpupgrade", 1, null],
  tls: ["tls", "", "none", true, false, "TLS", "reality", 0], type: ["none", "multi", "wechat-video", "dns", "http", ""], host: ["cdn.example.com", "", "Ж.example"],
  path: ["/", "/ws?ed=2048", "seed", ""], sni: ["s.example", "", "пример.рф", " S.example "], alpn: ["h2", "h2, http/1.1", ""], fp: ["chrome", "none", "random", ""],
  aid: [0, "0", "1", null, "x"], scy: ["auto", "none", "aes-128-gcm", 1], v: ["2", 2], "10": [1], "Z": ["z"], "a-b": [1]
};
for (let n = 0; n < Number(process.env.FUZZ_VMESS ?? 200); n++) {
  const o = { id: pick([U, U2, "short-id", uc(U2)]) };
  for (const [k, values] of Object.entries(VMESS_FIELDS)) if (rand() < 0.6) o[k] = pick(values);
  let b = Buffer.from(JSON.stringify(o), "utf8").toString(rand() < 0.5 ? "base64" : "base64url");
  if (rand() < 0.3) b = b.replace(/=+$/, "");
  if (rand() < 0.2) b = b.replace(/(.{8})/g, "$1 ");
  fuzz.push(`vmess://${b}`);
}
function uc(s) { return s.toUpperCase(); }

// Outbounds are kept as a digest of their JSON with sorted keys, to keep this file small.
const canon = (v) => Array.isArray(v) ? `[${v.map(canon).join(",")}]`
  : (v !== null && typeof v === "object")
    ? `{${Object.keys(v).filter((k) => v[k] !== undefined).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(",")}}`
  : JSON.stringify(v);
// Where the router is stricter than the desktop (DESIGN §5), checked independently of links.uc:
// such a link keeps its full outbound, which xray must refuse.
const xrayIdValid = (id) => {
  const n = Buffer.byteLength(id);
  if (n < 32 || n > 36) return n >= 1 && n <= 30;
  return /^-?[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}/i.test(id);
};
const decodes = (s) => { try { return decodeURIComponent(s); } catch { return undefined; } };
function stricter(link, ob) {
  const scheme = /^([a-z0-9+.-]+):/i.exec(link)?.[1].toLowerCase();
  if (scheme === "vmess") {
    const id = ob.settings?.vnext?.[0]?.users?.[0]?.id;
    return ob.error === undefined && (typeof id !== "string" || !xrayIdValid(id));
  }
  if (scheme === "hysteria2" || scheme === "hy2") return ob.error === undefined && ob.streamSettings.hysteriaSettings.auth === "";
  let url;
  try { url = new URL(link); } catch { return false; }
  const secret = decodes(url.username);
  if (scheme === "vless" && (secret === undefined || !xrayIdValid(secret))) return true;
  if (scheme === "trojan" && !secret) return true;
  const security = url.searchParams.get("security");
  if (security?.trim().toLowerCase() === "reality") {
    if (!/^[A-Za-z0-9_-]{43}$/.test(url.searchParams.get("pbk") ?? "")) return true;
    const sid = url.searchParams.get("sid");
    if (sid !== null && !/^([0-9A-Fa-f]{2}){0,8}$/.test(sid)) return true;
  }
  return false;
}
const fuzzOut = fuzz.map((link) => {
  const ob = run(() => buildOutbound(link.trim()));
  const parse = run(() => { const p = parseProxyShareLink(link.trim()); delete p.rawUri; return p; });
  const strict = parse.error === undefined && stricter(link.trim(), ob);
  return {
    link,
    ...(link.trim() !== link ? { stored: link.trim() } : {}),
    parse,
    ...(strict ? { strict: true } : {}),
    outbound: (ob.error !== undefined || strict) ? ob : { sha256: createHash("sha256").update(canon(ob)).digest("hex") }
  };
});

// Bulk import: line numbers, comments, CRLF, the per-line limit.
const importText = [`  # comment`, "", `vless://${U}@example.com:443#one\r`, "tuic://x@example.com:443", `\thy2://pw@example.com#two  `, "x".repeat(65537), "#tail"].join("\n");
const imported = parseProxyShareLinks(importText);

process.stdout.write(JSON.stringify({
  xray_version_new: NEW,
  vectors: out,
  fuzz: fuzzOut,
  import: {
    text: importText,
    names: imported.profiles.map((p) => p.name),
    fingerprints: imported.profiles.map((p) => p.fingerprint),
    errors: imported.errors,
    skipped: imported.skipped
  }
}) + "\n");
