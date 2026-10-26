#!/bin/sh
# Generates throwaway test secrets + configs into /s (the host's tests/lab/state dir).
# Runs INSIDE shadow-testenv/vpn (alpine + xray + openssl + ssh-keygen). Idempotent: keeps existing secrets.
# HOST_IDS=<uid>:<gid>: the owner of everything in /s afterwards (a Linux bind mount keeps root's ids, and
# the host-side tests read state/ as the host user).
set -eu
S=/s
VPN_IP=203.0.113.20
WEB_IP=203.0.113.10
cd "$S"

[ -s uuid ] || xray uuid > uuid
[ -s x25519.txt ] || xray x25519 > x25519.txt
[ -s shortid ] || openssl rand -hex 8 > shortid
[ -s trojan.pw ] || echo "trojan-$(openssl rand -hex 6)" > trojan.pw
[ -s hy2.pw ] || echo "hy2-$(openssl rand -hex 6)" > hy2.pw
[ -s ssh.pw ] || echo "ssh-$(openssl rand -hex 6)" > ssh.pw
for n in web vpn; do
  [ -s $n.crt ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
      -subj "/CN=$n.shadow.lab" -addext "subjectAltName=DNS:$n.shadow.lab" \
      -keyout $n.key -out $n.crt 2>/dev/null
done
chmod 644 web.key vpn.key   # read by nginx/xray running as non-root users in the lab containers
[ -s router_id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -C shadow-router-test -f router_id_ed25519

UUID=$(cat uuid)
PRIV=$(sed -n 's/^PrivateKey: *//p' x25519.txt)
PBK=$(sed -n 's/^Password (PublicKey): *//p' x25519.txt)
SID=$(cat shortid)
TPW=$(cat trojan.pw)
HPW=$(cat hy2.pw)
PCS=$(openssl x509 -in vpn.crt -outform der | sha256sum | cut -d' ' -f1)
echo "$PCS" > vpn.crt.sha256

REALITY_SRV='"security":"reality","realitySettings":{"show":false,"target":"'$WEB_IP':443","xver":0,"serverNames":["web.shadow.lab"],"privateKey":"'$PRIV'","shortIds":["","'$SID'"]}'
TLS_SRV='"security":"tls","tlsSettings":{"certificates":[{"certificateFile":"/s/vpn.crt","keyFile":"/s/vpn.key"}]}'

cat > server.json <<EOF
{
  "log": { "loglevel": "warning", "access": "/tmp/xray-access.log" },
  "inbounds": [
    { "tag": "vless-reality-vision", "port": 443, "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID", "flow": "xtls-rprx-vision" } ], "decryption": "none" },
      "streamSettings": { "network": "raw", $REALITY_SRV } },
    { "tag": "vless-xhttp-reality", "port": 8443, "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/xh", "mode": "auto" }, $REALITY_SRV } },
    { "tag": "vmess-ws", "port": 10002, "protocol": "vmess",
      "settings": { "clients": [ { "id": "$UUID" } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vm" } } },
    { "tag": "trojan-tls", "port": 10003, "protocol": "trojan",
      "settings": { "clients": [ { "password": "$TPW" } ] },
      "streamSettings": { "network": "raw", $TLS_SRV } },
    { "tag": "hysteria2", "port": 8444, "protocol": "hysteria",
      "settings": { "version": 2, "clients": [ { "auth": "$HPW" } ] },
      "streamSettings": { "network": "hysteria", "hysteriaSettings": { "version": 2 },
        "security": "tls", "tlsSettings": { "alpn": ["h3"], "certificates": [ { "certificateFile": "/s/vpn.crt", "keyFile": "/s/vpn.key" } ] } } },
    { "tag": "vless-kcp", "port": 10005, "protocol": "vless",
      "settings": { "clients": [ { "id": "$UUID" } ], "decryption": "none" },
      "streamSettings": { "network": "kcp", "finalmask": { "udp": [ { "type": "mkcp-original" } ] } } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ]
}
EOF

# Share links in the formats the desktop app accepts (for link-parser tests on the router).
# mKCP: xray 26 moved the classic obfuscation every older mKCP server applies into the mkcp-original
# mask; a plain kcp link (no fm, headerType or seed) means that classic server to the desktop and to
# Shadow, so the lab server above applies it.
cat > links.txt <<EOF
vless://$UUID@$VPN_IP:443?type=tcp&security=reality&pbk=$PBK&fp=chrome&sni=web.shadow.lab&sid=$SID&flow=xtls-rprx-vision&encryption=none#lab-reality-vision
vless://$UUID@$VPN_IP:8443?type=xhttp&path=%2Fxh&mode=auto&security=reality&pbk=$PBK&fp=chrome&sni=web.shadow.lab&sid=$SID&encryption=none#lab-xhttp-reality
vmess://$(printf '{"v":"2","ps":"lab-vmess-ws","add":"%s","port":"10002","id":"%s","aid":"0","scy":"auto","net":"ws","type":"none","host":"","path":"/vm","tls":""}' "$VPN_IP" "$UUID" | base64 -w0)
trojan://$TPW@$VPN_IP:10003?type=tcp&security=tls&sni=vpn.shadow.lab&pcs=$PCS#lab-trojan-tls
hysteria2://$HPW@$VPN_IP:8444?sni=vpn.shadow.lab&alpn=h3&pinSHA256=$PCS#lab-hy2
vless://$UUID@$VPN_IP:10005?type=kcp&security=none&encryption=none#lab-vless-kcp
EOF

# "publicKey" (old name) is accepted by both 26.x and the 24.10 feed's 25.1.30; "password" only by 26.x.
REALITY_CLI='"security":"reality","realitySettings":{"serverName":"web.shadow.lab","fingerprint":"chrome","publicKey":"'$PBK'","shortId":"'$SID'"}'
MARK='"sockopt":{"mark":255}'
socks_in() { printf '{"tag":"%s","listen":"127.0.0.1","port":%s,"protocol":"socks","settings":{"udp":true}},' "$1" "$2"; }

# Router-side client: socks inbounds per protocol (unit checks) + two tproxy inbounds (dataplane checks).
# client_cfg <file> <1|0>: 1 = xray >= 26 (hysteria2, pinnedPeerCertSha256); 0 = 24.10 feed xray 25.1.30
client_cfg() {
if [ "$2" = 1 ]; then
  HY_IN="$(socks_in s-hy2 20005)"
  HY_OUT='{ "tag": "hy2", "protocol": "hysteria",
      "settings": { "version": 2, "address": "'$VPN_IP'", "port": 8444 },
      "streamSettings": { "network": "hysteria", "hysteriaSettings": { "version": 2, "auth": "'$HPW'" },
        "security": "tls", "tlsSettings": { "serverName": "vpn.shadow.lab", "alpn": ["h3"], "pinnedPeerCertSha256": "'$PCS'" }, '$MARK' } },'
  HY_RULE='{ "inboundTag": ["s-hy2"], "outboundTag": "hy2" },'
  TLS_PIN='"pinnedPeerCertSha256": "'$PCS'"'
  KCP_MASK=', "finalmask": { "udp": [ { "type": "mkcp-original" } ] }'
else
  HY_IN=""; HY_OUT=""; HY_RULE=""
  # xray 25.1.30: pinnedPeerCertificateChainSha256 is checked IN ADDITION to normal chain verification,
  # so a self-signed server needs allowInsecure (still allowed there; rejected by 26.x after 2026-06-01)
  TLS_PIN='"allowInsecure": true'
  KCP_MASK=''
fi
# (no $(...) inside the heredoc: busybox ash mis-parses that inside a function body)
IN_SOCKS="$(socks_in s-reality 20001) $(socks_in s-xhttp 20002) $(socks_in s-vmess 20003) $(socks_in s-trojan 20004) $HY_IN $(socks_in s-kcp 20006) $(socks_in s-ssh 20007)"
cat > "$1" <<EOF
{
  "log": { "loglevel": "warning", "access": "/tmp/shadow-test/access.log", "error": "/tmp/shadow-test/error.log" },
  "inbounds": [
    $IN_SOCKS
    { "tag": "tproxy-ssh", "listen": "127.0.0.1", "port": 12346, "protocol": "dokodemo-door",
      "settings": { "network": "tcp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } } },
    { "tag": "tproxy-xray", "listen": "127.0.0.1", "port": 12345, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true } }
  ],
  "outbounds": [
    { "tag": "reality", "protocol": "vless",
      "settings": { "vnext": [ { "address": "$VPN_IP", "port": 443, "users": [ { "id": "$UUID", "flow": "xtls-rprx-vision", "encryption": "none" } ] } ] },
      "streamSettings": { "network": "raw", $REALITY_CLI, $MARK } },
    { "tag": "xhttp", "protocol": "vless",
      "settings": { "vnext": [ { "address": "$VPN_IP", "port": 8443, "users": [ { "id": "$UUID", "encryption": "none" } ] } ] },
      "streamSettings": { "network": "xhttp", "xhttpSettings": { "path": "/xh", "mode": "auto" }, $REALITY_CLI, $MARK } },
    { "tag": "vmess", "protocol": "vmess",
      "settings": { "vnext": [ { "address": "$VPN_IP", "port": 10002, "users": [ { "id": "$UUID", "security": "auto" } ] } ] },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "/vm" }, $MARK } },
    { "tag": "trojan", "protocol": "trojan",
      "settings": { "servers": [ { "address": "$VPN_IP", "port": 10003, "password": "$TPW" } ] },
      "streamSettings": { "network": "raw", "security": "tls",
        "tlsSettings": { "serverName": "vpn.shadow.lab", $TLS_PIN }, $MARK } },
    $HY_OUT
    { "tag": "kcp", "protocol": "vless",
      "settings": { "vnext": [ { "address": "$VPN_IP", "port": 10005, "users": [ { "id": "$UUID", "encryption": "none" } ] } ] },
      "streamSettings": { "network": "kcp", $MARK $KCP_MASK } },
    { "tag": "ssh", "protocol": "socks", "settings": { "servers": [ { "address": "127.0.0.1", "port": 1080 } ] } },
    { "tag": "direct", "protocol": "freedom", "streamSettings": { $MARK } }
  ],
  "routing": { "rules": [
    { "inboundTag": ["tproxy-xray", "s-reality"], "outboundTag": "reality" },
    { "inboundTag": ["s-xhttp"], "outboundTag": "xhttp" },
    { "inboundTag": ["s-vmess"], "outboundTag": "vmess" },
    { "inboundTag": ["s-trojan"], "outboundTag": "trojan" },
    $HY_RULE
    { "inboundTag": ["s-kcp"], "outboundTag": "kcp" },
    { "inboundTag": ["tproxy-ssh", "s-ssh"], "outboundTag": "ssh" }
  ] }
}
EOF
}
client_cfg router-client.json 1
client_cfg router-client-xray25.json 0
[ -z "${HOST_IDS:-}" ] || chown -R "$HOST_IDS" "$S"
echo "state ready in $S"
