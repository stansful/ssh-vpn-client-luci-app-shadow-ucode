// Desktop parity vectors for links_test.uc, computed by the desktop app's own code (read-only).
// DESKTOP_SRC is a checkout of https://github.com/stansful/ssh-vpn-client-electron (Node 22.18+ or 24+,
// which load its TypeScript directly). The committed tests/unit/vectors/links.json is the source of truth
// for the tests; this script shows where it comes from and refreshes it after a desktop change:
//   DESKTOP_SRC=../ssh-vpn-client-electron node --import ./tests/unit/vectors/register.mjs \
//     tests/unit/vectors/vectors.mjs <out dir>       # writes <out dir>/vectors.json (= links.json) and cfg-*.json
import { writeFileSync, mkdirSync } from "node:fs";
import { desktopModule } from "./desktop.mjs";
const P = desktopModule("src/core/proxy/");
const { parseProxyShareLink } = await import(P + "share-link-parser.ts");
const { buildOutbound } = await import(P + "xray-config.ts");
const U = "11111111-1111-4111-8111-111111111111";
const PIN = "ba88452f1b0c1a3c4d7e6f5a49382716ba88452f1b0c1a3c4d7e6f5a49382716";
const vm = (o, b64 = (s) => Buffer.from(s, "utf8").toString("base64")) => `vmess://${b64(JSON.stringify(o))}`;
const fmq = (o) => encodeURIComponent(JSON.stringify(o));
const pinB64 = Buffer.from(PIN, "hex").toString("base64");
const opensslPin = PIN.toUpperCase().match(/../g).join(":");
const links = [
  `vless://${U}@example.com:443?type=ws&security=tls&path=%2Fws#Netherlands`,
  vm({ v: "2", ps: "vmess-demo", add: "vmess.example.com", port: "8443", id: "22222222-2222-4222-8222-222222222222", aid: "0", net: "grpc", tls: "tls" }),
  "trojan://secret@trojan.example.com:443?security=tls#trojan-demo",
  "trojan://secret@host.example.com:443?sni=sni.example.com#gfw",
  "trojan://secret@host.example.com:443?security=none#plain",
  "trojan://secret@host.example.com:443?tls=0#legacy",
  `vless://${U}@example.com:443#bare`,
  `vless://${U}@example.com:443?type=xhttp&security=tls&host=cdn.example.com&path=%2Fx&mode=packet-up#demo`,
  `vless://${U}@example.com:443?type=xhttp&security=reality&sni=www.example.com&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba8&fp=chrome&path=%2Fx&mode=auto&extra=${fmq({ xPaddingBytes: "100-1000" })}#xhttp-extra-ignored`,
  `vless://${U}@example.com:443?type=httpupgrade&security=tls&host=cdn.example.com&path=%2Fup#demo`,
  `vless://${U}@example.com:443?type=http-upgrade&path=%2Fup#alias`,
  `vless://${U}@example.com:443?type=raw&headerType=http&security=tls#raw`,
  `vless://${U}@example.com:443?type=kcp&security=none&headerType=wechat-video&seed=demo&mtu=1200&tti=30#demo`,
  `vless://${U}@example.com:443?type=kcp&security=none#kcp-plain`,
  `vless://${U}@example.com:443?type=kcp&headerType=dns&host=a.example.com#kcp-dns`,
  `vless://${U}@example.com:443?type=kcp&headerType=video#bad`,
  `vless://${U}@example.com:443?type=kcp&headerType=utp&seed=ignored&fm=${fmq({ udp: [{ type: "mkcp-legacy", settings: { header: "wireguard" } }, { type: "mkcp-legacy", settings: { value: "pw" } }] })}#kcp-fm`,
  `vless://${U}@example.com:443?type=kcp&fm=${fmq({ udp: [{ type: "noise" }] })}#kcp-noise`,
  `vless://${U}@example.com:443?type=kcp&mtu=2000&tti=5#kcp-bounds`,
  vm({ add: "vmess.example.com", port: 443, id: "22222222-2222-4222-8222-222222222222", net: "kcp", type: "dtls", path: "seed" }),
  `vless://${U}@example.com:443?type=h2&security=tls&path=%2Fh2#h2`,
  `vless://${U}@example.com:443?type=quic#quic`,
  `vless://${U}@пример.рф:443?type=ws&security=tls#idn`,
  "trojan://secret@MÜNCHEN.de:443?security=tls",
  vm({ add: "Пример.рф", port: 443, id: "22222222-2222-4222-8222-222222222222", ps: "idn" }),
  "vless://u@%zz.example:443",
  vm({ add: "vmess.example.com", port: 443, id: "22222222-2222-4222-8222-222222222222", tls: true, net: "ws", path: "/ws", host: "cdn.example.com" }),
  vm({ add: "vmess.example.com", port: 443, id: "22222222-2222-4222-8222-222222222222", tls: false }),
  vm({ add: "vmess.example.com", port: 443, id: "22222222-2222-4222-8222-222222222222", net: 7 }),
  "vmess://" + Buffer.from("null").toString("base64"),
  "vmess://not-base64-json!!",
  vm({ add: "vmess.example.com", port: "443abc", id: "x" }),
  vm({ add: "vmess.example.com", port: 443, id: "22222222-2222-4222-8222-222222222222", net: "ws", tls: "tls", fp: "safari", alpn: "h2", sni: "пример.рф", scy: "aes-128-gcm", aid: 0 }),
  vm({ add: "example.com", port: 443, id: "22222222-2222-4222-8222-222222222222", net: "grpc", type: "multi", path: "svc", tls: "tls" }),
  vm({ add: "example.com", port: 443, id: "22222222-2222-4222-8222-222222222222", net: "ws", tls: "tls" }, (s) => Buffer.from(s).toString("base64url")),
  `vless://${U}@example.com:443?type=ws&security=0#zero`,
  `vless://${U}@example.com:443?type=ws&security=xtls#xtls`,
  `vless://${U}@пример.рф:443?security=tls&sni=%D0%BF%D1%80%D0%B8%D0%BC%D0%B5%D1%80.%D1%80%D1%84&type=ws&host=cdn.example.com&path=%2F#idn-sni`,
  "trojan://secret@host.example.com:443?servername=M%C3%BCnchen.de#idn",
  "trojan://secret@host.example.com:443?sni=CDN.example.com#ascii",
  `vless://${U}@example.com:443?type=ws&security=tls&sni=cdn.example.com&alpn=h2%2Chttp%2F1.1&fp=chrome#tls`,
  `vless://${U}@example.com:443?security=tls&type=tcp&fp=none#fp-none`,
  "trojan://secret@example.com:443?security=tls&fp=HelloChrome_120#fp-hello",
  `vless://${U}@example.com:443?type=grpc&security=reality&sni=www.example.com&pbk=PUBLICKEY&sid=ab&fp=chrome&spx=%2Fsearch&serviceName=svc&mode=multi#reality`,
  `vless://${U}@example.com:443?type=tcp&security=reality&sni=www.example.com&pbk=Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw&sid=6ba85179e30d4fc2&fp=random&flow=xtls-rprx-vision#reality-vision`,
  `vless://${U}@example.com:443?type=grpc&security=tls&serviceName=svc&mode=gun#gun`,
  `vless://${U}@example.com:443?type=grpc&security=tls&path=from-path#grpc-path`,
  `vless://${U}@example.com:443?type=hysteria&security=tls&auth=pw&up=20&congestion=bbr#vless-hy`,
  `vless://${U}@example.com:443?type=hysteria&security=tls&sni=&auth=pw#vless-hy-empty-sni`,
  `vless://${U}@example.com:443?type=hysteria&auth=pw#vless-hy-no-tls`,
  `vless://${U}@example.com:443?security=tls&flow=&encryption=mlkem768x25519plus.native.0rtt.abc#empty-flow`,
  `vless://${U}@[2001:DB8:0:0::1]:443?security=tls#v6`,
  `vless://${U}@example.com?security=tls#noport`,
  `vless://${U}@example.com:70000?security=tls#bigport`,
  `vless://${U}@example.com:0443?security=tls#leading-zero`,
  "trojan://pa:ss@example.com:443#colon-pass",
  "trojan://p%40ss%3Aw@example.com:443#encoded-pass",
  `vless://${U}@example.com:443?Type=ws&Security=tls#case-keys`,
  `vless://${U}@example.com:443?type=ws&path=%2Fa+b&host=h#plus`,
  `vless://${U}@example.com:443?type=ws&type=grpc#dup`,
  `vless://${U}@example.com:443/?type=ws#slash-path`,
  `vless://${U}@example.com:443#%E0%A4%A`,
  `vless://${U}@example.com:443#`,
  "hysteria2://letmein@example.com:8443/?sni=real.example.com&obfs=salamander&obfs-password=gawrgura&pinSHA256=" + PIN + "#Helsinki%20QUIC",
  "hy2://secret@Node.Example.com",
  "hy2://letmein@example.com:8443/?insecure=1#demo",
  `hysteria2://pw@example.com:443,20000-30000/?sni=cdn.example.com&obfs=salamander&obfs-password=secret&pinSHA256=${PIN}&up=50&down=100&hop_interval=10#demo`,
  "hysteria2://pw@example.com:20000-30000?obfs-password=secret",
  "hysteria2://pw@example.com:30000-20000",
  "hy2://pw@example.com:443?mport=20000:30000&mportHopInt=10",
  `hysteria2://pw@example.com:443?fm=${fmq({ quicParams: { udpHop: { ports: "40000-50000", interval: "5-15" } } })}`,
  "hysteria2://pw@example.com:443,443",
  "hysteria2://pw@example.com:1000-2000?hop_interval=2s",
  "hysteria2://pw@example.com:1000-2000?hop_interval=30s&hop_interval_max=60s",
  "hysteria2://pw@example.com:1000-2000?hopInterval=bogus",
  "hysteria2://pw@example.com:20000-30000,443,25000-35000,35001-36000,443",
  `hy2://pw@example.com:443?fm=${fmq({ udp: [{ type: "UDPHOP", settings: { mode: "intervallocal", interval: "10-20", remotePorts: "20000:30000" } }, { type: "salamander", settings: { password: "s" } }] })}`,
  "hysteria2://user%40mail:p%40ss@example.com:443",
  "hysteria2://a/b@c@example.com:443/?sni=x",
  "hysteria2://pw@[2001:DB8::1]:443",
  "hysteria2://user:pass@[2001:db8::1]:443/?insecure=1#ipv6",
  "hysteria2://pw@пример.рф:443",
  "hysteria2://pw@:443",
  "hysteria2://pw@example.com:0",
  "hysteria2://pw@example.com:443,",
  "hysteria2://pw@example.com:70000",
  "hysteria2://pw@example.com:abc",
  "hysteria2://pw@example.com:443?mport=20000-70000",
  `hysteria2://pw@${"a".repeat(254)}:443`,
  "hysteria2://pw@[2001:db8::1",
  "hysteria2://pw@exa mple.com",
  "hysteria2://pw@example.com?obfs-password=nekobox",
  "hysteria2://pw@example.com?obfs=none&obfs-password=x",
  "hysteria2://pw@example.com?obfs=salamander",
  "hysteria2://pw@example.com?obfs=gecko&obfs-password=x",
  `hysteria2://pw@example.com?pinSHA256=${opensslPin}`,
  `hysteria2://pw@example.com?pinSHA256=${encodeURIComponent(pinB64)}`,
  `hysteria2://pw@example.com?pinSHA256=${PIN},${"1".repeat(64)}&pcs=${PIN}`,
  "hysteria2://pw@example.com?pinSHA256=deadbeef",
  "hysteria2://pw@example.com?allowInsecure=true",
  "hysteria2://pw@example.com?up=50&downmbps=100",
  "hysteria2://pw@example.com?up=100%20kbps",
  `hysteria2://pw@example.com?fm=${fmq({ udp: [{ type: "salamander", settings: { password: "from-fm" } }], quicParams: { congestion: "BBR", brutalUp: "60 mbps", maxIdleTimeout: 60, keepAlivePeriod: 1, debug: true } })}`,
  `hysteria2://pw@example.com?obfs-password=link&up=10&fm=${fmq({ udp: [{ type: "salamander", settings: { password: "from-fm" } }], quicParams: { congestion: "BBR", brutalUp: "60 mbps" } })}`,
  `hysteria2://pw@example.com?fm=${fmq({ quicParams: { congestion: "force-brutal" } })}`,
  `hysteria2://pw@example.com?fm=${fmq({ quicParams: { congestion: "force-brutal", brutalUp: "60 mbps", maxIdleTimeout: 60 } })}`,
  "hysteria2://pw@example.com?fm=%7Bnot-json",
  `hysteria2://pw@example.com?fm=${encodeURIComponent('{"udp":[{"type":"noise"}]}')}`,
  `hysteria2://pw@example.com?fm=${encodeURIComponent('{"udp":[{"type":"salamander","settings":{"password":"x","packetSize":"512-1200"}}]}')}`,
  "hysteria2://pw@example.com#Tokyo%201?serverDescription=aGVsbG8=",
  `hy2://pw@example.com?ech=${encodeURIComponent(Buffer.from([0, 3, 0xfe, 0x0d, 0]).toString("base64"))}`,
  `hy2://pw@example.com?ech=${encodeURIComponent("udp://127.0.0.1:53")}`,
  "hy2://pw@example.com?ech=AAAA",
  "hy2://pw@example.com?vcn=real.example.com&peer=peer.example.com",
  "HY2://pw@example.com?SNI=Upper.example.com",
  "hysteria://pw@example.com:443#v1",
  "tuic://x@example.com:443",
  "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#ss",
];
const out = [];
for (const link of links) {
  const v = { link };
  try { v.parse = parseProxyShareLink(link); delete v.parse.rawUri; } catch (e) { v.parse = { error: e.message }; }
  try { v.outbound = buildOutbound(link); } catch (e) { v.outbound = { error: e.message }; }
  out.push(v);
}
const dir = process.argv[2];
mkdirSync(dir, { recursive: true });
writeFileSync(dir + "/vectors.json", JSON.stringify(out, null, 1));
for (const [i, v] of out.entries()) {
  if (!v.outbound.error) writeFileSync(`${dir}/cfg-${String(i).padStart(3, "0")}.json`, JSON.stringify({ log: { loglevel: "warning" }, inbounds: [{ tag: "socks-in", protocol: "socks", listen: "127.0.0.1", port: 19080, settings: { udp: true, auth: "noauth" } }], outbounds: [v.outbound, { tag: "direct", protocol: "freedom" }] }));
}
console.log(out.length, "vectors");
