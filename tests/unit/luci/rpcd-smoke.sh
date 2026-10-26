#!/bin/sh
# Throwaway router (procd as PID 1): installs the LuCI app and the backend tree, reloads rpcd and calls every
# luci.shadow-vpn method through ubus against a fixture /etc/config/shadow-vpn. Backend modules that do not
# exist yet are replaced by the stubs in tests/unit/luci/stubs (reported as such). Needs the lab image and the
# lab's test links and key in tests/lab/state (both made by BUILD_ONLY=1 tests/lab/up.sh) and Internet access
# (the list download).
#
#   tests/unit/luci/rpcd-smoke.sh            run and remove the container
#   KEEP=1 LUCI_PORT=18089 tests/unit/luci/rpcd-smoke.sh   keep it, LuCI on 127.0.0.1:$LUCI_PORT (empty root password)
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../../.." && pwd)"
IMAGE="${SHADOW_TEST_IMAGE:-shadow-testenv/tr3000-deps:25.12.6}"
NAME="shv-luci-smoke"
PORT="${LUCI_PORT:-18089}"
MODULES="const config secrets state links validate lists keys"

cleanup() { [ "${KEEP:-0}" = 1 ] || docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "missing image $IMAGE: run BUILD_ONLY=1 tests/lab/up.sh" >&2; exit 2; }
for f in links.txt router_id_ed25519; do
	[ -s "$SRC/tests/lab/state/$f" ] || { echo "missing tests/lab/state/$f: run BUILD_ONLY=1 tests/lab/up.sh" >&2; exit 2; }
done

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname shvsmoke \
	--cap-add NET_ADMIN --cap-add NET_RAW --cap-add SYS_ADMIN \
	--security-opt seccomp=unconfined --security-opt apparmor=unconfined \
	-p "127.0.0.1:$PORT:80" "$IMAGE" /sbin/init >/dev/null

i=0
until docker exec "$NAME" sh -c 'pidof rpcd >/dev/null && pidof ubusd >/dev/null && pidof uhttpd >/dev/null' 2>/dev/null; do
	i=$((i + 1)); [ $i -lt 60 ] || { echo "not ok smoke: router did not boot"; exit 1; }
	sleep 1
done

# Package trees, the way the apk would lay them out.
tar -C "$SRC/luci-app-shadow-vpn/root" -cf - . | docker exec -i "$NAME" tar -C / -xf -
tar -C "$SRC/luci-app-shadow-vpn/htdocs" -cf - . | docker exec -i "$NAME" tar -C /www -xf -
tar -C "$SRC/shadow-vpn/files" -cf - usr | docker exec -i "$NAME" tar -C / -xf -

for m in $MODULES; do
	if [ ! -s "$SRC/shadow-vpn/files/usr/share/ucode/shadow-vpn/$m.uc" ]; then
		echo "# stub: shadow-vpn.$m (backend module missing)"
		docker exec -i "$NAME" sh -c "cat > /usr/share/ucode/shadow-vpn/$m.uc" < "$HERE/stubs/shadow-vpn/$m.uc"
	fi
done

docker exec "$NAME" sh -c 'apk add -q ucode-mod-socket ucode-mod-digest >/dev/null 2>&1' ||
	{ echo "# stub: socket (apk add ucode-mod-socket failed)"; docker exec -i "$NAME" sh -c 'cat > /usr/share/ucode/socket.uc' < "$HERE/stubs/socket.uc"; }

docker exec -i "$NAME" sh -c 'cat > /etc/config/shadow-vpn' < "$HERE/shadow-vpn.config"
docker exec -i "$NAME" sh -c 'mkdir -p /tmp/lab && cat > /tmp/lab/links.txt' < "$SRC/tests/lab/state/links.txt"
docker exec -i "$NAME" sh -c 'cat > /tmp/lab/key' < "$SRC/tests/lab/state/router_id_ed25519"
docker exec "$NAME" sh -c 'rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/*; /etc/init.d/rpcd restart' >/dev/null 2>&1
# rpcd registers the object once it has loaded the plugin: wait for it (the check below reports a failure)
i=0
until docker exec "$NAME" ubus list luci.shadow-vpn >/dev/null 2>&1; do
	i=$((i + 1)); [ $i -lt 30 ] || break
	sleep 1
done

docker exec -i "$NAME" sh -s <<'EOS'
set -u
O=luci.shadow-vpn
FAILED=0
call() {
	args=${2:-}
	[ -n "$args" ] || args='{}'
	ubus -t 30 call $O "$1" "$args" 2>&1
}
pass() { echo "ok $1"; }
fail() { echo "not ok $1: $2"; FAILED=1; }

# expect <method> <json args> <jsonfilter expression that must match>
expect() {
	out=$(call "$1" "$2")
	if [ -n "$(echo "$out" | jsonfilter -e "$3" 2>/dev/null)" ]; then pass "$1 $4"; else fail "$1 $4" "$out"; fi
}

waitjob() {
	j=0
	while [ $j -lt 90 ]; do
		st=$(call job_status "{\"id\":\"$1\"}" | jsonfilter -e '@.state' 2>/dev/null)
		[ -n "$st" ] && [ "$st" != running ] && { echo "$st"; return; }
		j=$((j + 1)); sleep 1
	done
	echo timeout
}

ubus list $O >/dev/null 2>&1 && pass "rpcd registers $O" || { fail "rpcd registers $O" "$(logread | grep -i rpcd | tail -5)"; exit 1; }
n=$(ubus -v list $O | grep -c '"')
[ "$n" -ge 35 ] && pass "rpcd lists $n methods" || fail "rpcd method list" "$(ubus -v list $O)"

expect status '' '@.phase' 'returns a phase'
expect status '' '@.memory.total_kb' 'reports memory'
expect status '' '@.versions.xray' 'reports the xray version'

# Servers and host keys
sid=$(call server_save '{"values":{"name":"Lab","host":"203.0.113.20","port":"22","username":"vpnuser","auth":"password","keepalive":"15"},"password":"lab-pw"}' | jsonfilter -e '@.sid')
[ -n "$sid" ] && pass "server_save creates $sid" || fail server_save "$(call server_save '{"values":{"name":"Lab","host":"203.0.113.20","port":"22","username":"vpnuser","auth":"password"},"password":"lab-pw"}')"
expect server_save '{"values":{"name":"","host":"","port":"0","username":"","auth":"password"}}' '@.errors.host' 'returns field errors'
expect servers '' "@.servers[@.sid='$sid'].has_password" 'shows the server'
case "$(ls -l /etc/shadow-vpn/secrets/$sid.password 2>&1)" in -rw-------*) pass 'password secret is 0600' ;; *) fail 'password secret mode' "$(ls -l /etc/shadow-vpn/secrets/ 2>&1)" ;; esac
grep -q lab-pw /etc/config/shadow-vpn && fail 'password stays out of UCI' 'found in /etc/config/shadow-vpn' || pass 'password stays out of UCI'

mkdir -p /var/run/shadow-vpn
FPA="SHA256:$(printf 'a%.0s' $(seq 1 43))"
echo "ssh-ed25519 $FPA AAAAC3NzaC1lZDI1NTE5AAAAIExample" > /var/run/shadow-vpn/hostkey.$sid.seen
expect hostkey_pin "{\"sid\":\"$sid\"}" '@.error' 'refuses a pin without the fingerprint the page showed'
expect hostkey_pin "{\"sid\":\"$sid\",\"fingerprint\":\"$FPA\"}" '@.fingerprint' 'pins the seen key'
expect hostkey_forget "{\"sid\":\"$sid\"}" '@.ok' 'forgets the trusted key'
expect server_delete '{"sid":"../../etc/passwd"}' '@.error' 'refuses a bad sid'

# Keys
req=$(ucode -e 'print(sprintf("%J", { name: "Lab key", text: require("fs").readfile("/tmp/lab/key") }))')
kid=$(ubus call $O key_save "$req" | jsonfilter -e '@.sid')
[ -n "$kid" ] && pass "key_save stores $kid" || fail key_save "$(ubus call $O key_save "$req")"
expect keys '' "@.keys[@.sid='$kid'].type" 'lists the key'
expect key_show "{\"sid\":\"$kid\"}" '@.text' 'returns the key text'
expect server_save "{\"sid\":\"$sid\",\"values\":{\"name\":\"Lab\",\"host\":\"203.0.113.20\",\"port\":\"22\",\"username\":\"vpnuser\",\"auth\":\"key\",\"key\":\"$kid\",\"keepalive\":\"15\"}}" '@.sid' 'switches to key auth'
expect key_delete "{\"sid\":\"$kid\"}" '@.error' 'refuses a key in use'

# Xray profiles
req=$(ucode -e 'print(sprintf("%J", { text: require("fs").readfile("/tmp/lab/links.txt"), source: "import" }))')
out=$(ubus call $O profiles_import "$req")
added=$(echo "$out" | jsonfilter -e '@.added')
[ "${added:-0}" -ge 1 ] && pass "profiles_import adds $added profiles" || fail profiles_import "$out"
echo "# profiles_import: $out" | cut -c1-400
grep -q "fingerprint 'sha256:" /etc/config/shadow-vpn && fail 'profile identities are keyed' "$(grep fingerprint /etc/config/shadow-vpn | head -2)" ||
	pass 'profile identities are keyed (no plain link hash in UCI)'
case "$(ls -l /etc/shadow-vpn/fingerprint.key 2>&1)" in -rw-------*) pass 'the identity key is 0600' ;; *) fail 'identity key mode' "$(ls -l /etc/shadow-vpn 2>&1)" ;; esac
pid=$(call profiles | jsonfilter -e '@.profiles[0].sid')
expect profile_rename "{\"sid\":\"$pid\",\"name\":\"Renamed\"}" '@.ok' 'renames'
expect profile_pin "{\"sid\":\"$pid\",\"pinned\":true}" '@.ok' 'pins'
expect profile_link "{\"sid\":\"$pid\"}" '@.link' 'returns the link'
expect select "{\"transport\":\"xray\",\"sid\":\"$pid\"}" '@.ok' 'selects the profile'
expect profiles '' "@.profiles[@.sid='$pid'].selected" 'marks the selection'
expect profiles_delete_unpinned '' '@.deleted' 'deletes unpinned profiles'
expect profiles '' "@.profiles[@.sid='$pid']" 'keeps the pinned profile'

# Rules
rid=$(call rule_add '{"type":"domain","value":"example.org"}' | jsonfilter -e '@.sid')
[ -n "$rid" ] && pass "rule_add adds $rid" || fail rule_add "$(call rule_add '{"type":"domain","value":"example.org"}')"
expect rule_add '{"type":"domain","value":"example.org"}' '@.error' 'refuses a duplicate'
expect rule_add '{"type":"ip","value":"149.154.160.0/20"}' '@.sid' 'adds an IP rule'
expect rule_add '{"type":"device","value":"3c:22:fb:1a:0e:77"}' '@.sid' 'adds a device rule'
expect rule_set "{\"sid\":\"$rid\",\"enabled\":false}" '@.ok' 'disables a rule'
expect rules '' '@.rules[2].value' 'lists rules'
call rules_export | jsonfilter -e '@.json' > /tmp/export.json
req=$(ucode -e 'print(sprintf("%J", { text: require("fs").readfile("/tmp/export.json"), apply: false }))')
[ -n "$req" ] && expect rules_import "$req" '@.imported' 'previews the export' || fail rules_import 'could not build the request'
expect rules_import '{"text":"[{\"type\":\"process.name\",\"value\":\"x\"},{\"type\":\"domain\",\"value\":\"a.example\"}]","apply":true}' '@.skipped.apps' 'replaces rules and counts app rules'
expect rule_delete "{\"sid\":\"$(call rules | jsonfilter -e '@.rules[0].sid')\"}" '@.ok' 'deletes a rule'

# Settings, devices, attention, log
expect settings_set '{"values":{"check_endpoint":"example.com:443","lists_refresh":"6"}}' '@.ok' 'stores settings'
expect settings_set '{"values":{"check_endpoint":"https://x/"}}' '@.errors.check_endpoint' 'validates the endpoint'
echo '1792900000 3c:22:fb:1a:0e:77 192.168.1.140 AppleTV *' > /tmp/dhcp.leases
expect leases '' '@.leases[0].mac' 'reads DHCP leases'
logger -t shadow-vpn 'smoke: password=hunter2 vless://11111111-1111-4111-8111-111111111111@nl.example.net:443'
logger -t other-daemon 'smoke: must not show up'
out=$(call logs '{"lines":50}')
echo "$out" | grep -q 'smoke: password=<redacted> vless://<redacted>@nl.example.net' && pass 'logs redacts secrets' || fail 'logs redacts secrets' "$out"
echo "$out" | grep -q other-daemon && fail 'logs keeps only Shadow tags' "$out" || pass 'logs keeps only Shadow tags'
expect attention_dismiss '{"id":"none-such"}' '@.ok' 'accepts an unknown id'
expect job_status '{"id":"../x"}' '@.error' 'refuses a bad job id'

# Lists (downloads from GitHub through the container's network)
expect lists '' '@.proxy' 'reports both lists'
job=$(call list_refresh '{"kind":"direct"}' | jsonfilter -e '@.job')
if [ -n "$job" ]; then
	st=$(waitjob "$job")
	[ "$st" = done ] && pass "list_refresh job $job finished" || fail "list_refresh job $job" "$st $(call job_status "{\"id\":\"$job\"}")"
else
	fail list_refresh "$(call list_refresh '{"kind":"direct"}')"
fi
expect list_view '{"kind":"direct"}' '@.domains' 'returns domains'
job=$(call list_set '{"kind":"proxy","enabled":true}' | jsonfilter -e '@.job')
[ -n "$job" ] && pass "list_set returns job $job ($(waitjob "$job"))" || fail list_set "$(call list_set '{"kind":"proxy","enabled":true}')"

# On / check / off through the real job helper
out=$(call set_enabled '{"enabled":true}')
job=$(echo "$out" | jsonfilter -e '@.job')
if [ -n "$job" ]; then
	st=$(waitjob "$job")
	pass "set_enabled true -> job $job ($st)"
	echo "# job: $(call job_status "{\"id\":\"$job\"}" | tr -d '\n\t' | cut -c1-300)"
else
	fail 'set_enabled true' "$out"
fi
echo "# status: $(call status | jsonfilter -e '@.phase' -e '@.active' -e '@.message' | tr '\n' ' ' | cut -c1-300)"
out=$(call check)
job=$(echo "$out" | jsonfilter -e '@.job')
[ -n "$job" ] && pass "check -> job $job ($(waitjob "$job"))" || echo "# check: $out"
out=$(call set_enabled '{"enabled":false}')
job=$(echo "$out" | jsonfilter -e '@.job')
[ -n "$job" ] && pass "set_enabled false -> job $job ($(waitjob "$job"))" || fail 'set_enabled false' "$out"

expect profile_delete "{\"sid\":\"$pid\"}" '@.ok' 'deletes a profile'
expect server_delete "{\"sid\":\"$sid\"}" '@.ok' 'deletes the server'
expect key_delete "{\"sid\":\"$kid\"}" '@.ok' 'deletes the unused key'

# LuCI side: the files are served and the menu entry is visible to rpcd's ACL check
served=1
for v in overview ssh xray routing log settings; do
	wget -q -O /tmp/view.js "http://127.0.0.1/luci-static/resources/view/shadow-vpn/$v.js" &&
		cmp -s /tmp/view.js "/www/luci-static/resources/view/shadow-vpn/$v.js" || { served=0; fail 'uhttpd serves the views' "$v.js"; }
done
[ $served = 1 ] && pass 'uhttpd serves the views' 
logread | grep -i 'luci.shadow-vpn' | tail -5 | sed 's/^/# rpcd: /'
exit $FAILED
EOS
