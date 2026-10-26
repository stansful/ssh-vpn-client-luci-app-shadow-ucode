#!/bin/sh
# Router side of tests/unit/ssh/e2e.sh, in a throwaway router-image container: the helpers and the
# modules they import (ssh, keys, const, secrets, state) run on their real paths; gate-set and job
# are stubs that record their calls.
# Plays procd: an instance is ssh-run started with a clean environment, and a "respawn" starts it
# again once it has exited. Prints ok/not ok lines; usage: e2e-router.sh <phase> [args].

SID=s_00000000e2e0
KSID=k_00000000e2e0
ETC=/etc/shadow-vpn
RUN=/var/run/shadow-vpn
LIB=/usr/libexec/shadow-vpn
T=/src/tests/unit/ssh
SRC=/src/shadow-vpn/files
WAIT=30                                  # generous upper bound for every wait, in seconds
ARG=${2:-}

failed=0

ok() { echo "ok $1"; }
nok() { echo "not ok $1: $2"; failed=$((failed + 1)); }

# check <name> <shell condition>
check() {
	if eval "$2"; then ok "$1"; else nok "$1" "$2"; fi
}

# until_true <shell condition>: polls until it holds or WAIT seconds passed.
until_true() {
	i=0
	while [ $i -lt $WAIT ]; do
		eval "$1" && return 0
		sleep 1
		i=$((i + 1))
	done
	eval "$1"
}

field() {
	ucode -S -e 'import { readfile } from "fs"; let v = json(readfile(ARGV[0]) ?? "null"); for (let k in split(ARGV[1], ".")) v = v?.[k]; print(v ?? "");' "$1" "$2"
}

phase() { field $RUN/state.json phase; }
message() { field $RUN/state.json message; }
pid() { cat /tmp/e2e/inst.pid 2>/dev/null; }
cmdline() { { tr '\0' ' ' < /proc/$(pid)/cmdline; } 2>/dev/null; }
alive() { p=$(pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

# The procd instance: argv "ssh-run <sid>", an environment without secrets, stdin /dev/null.
start() {
	sh -c 'echo $$ > /tmp/e2e/inst.pid; exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin '"$LIB"'/ssh-run '"$SID" \
		</dev/null >>/tmp/e2e/inst.out 2>&1 &
	# not "alive": an instance that fails at once may be gone already
	until_true '[ -s /tmp/e2e/inst.pid ]'
}

stop() {
	alive && kill "$(pid)"
	until_true '! alive'
	rm -f /tmp/e2e/inst.pid
}

# respawn: what procd does after the instance exited.
respawn() {
	until_true '! alive' || nok "instance exited" "still running: $(cmdline)"
	rm -f /tmp/e2e/inst.pid
	start
}

# A fresh Connect: the plugin removes the fatal flag; nothing of the previous series is left.
fresh() {
	stop
	if pgrep -f ssh-openssh >/dev/null; then
		nok "previous phase left ssh running" "ssh-openssh still running"
		kill $(pgrep -f ssh-openssh)
	fi
	rm -f $RUN/fatal $RUN/state.json $RUN/attention.json $RUN/ssh.$SID.* $RUN/hostkey.$SID.*
	rm -f /tmp/e2e/job.* /tmp/e2e/gate-set.calls
}

# params <auth> [fingerprint] [host]: what apply renders from UCI, through ssh.params().
params() {
	ucode -S -e 'import { params } from "shadow-vpn.ssh"; print(params({ sid: ARGV[0], name: "E2E", host: ARGV[3] || "shv-ssh-sshd",
		port: 22, username: "tunnel", auth: ARGV[1], key: (ARGV[1] == "key") ? ARGV[4] : null, fingerprint: ARGV[2], keepalive: 15 }));' \
		"$SID" "$1" "${2:-}" "${3:-}" "$KSID" > $RUN/ssh.$SID.params
}

socks_ok() {
	[ "$(curl -s -m 10 --socks5-hostname 127.0.0.1:12346 http://127.0.0.1:8080/ 2>/dev/null)" = shadow-ok ]
}

forget_trust() {
	rm -f $ETC/trusted.$SID
	if [ -f $ETC/known_hosts ]; then
		grep -v "^shadow-$SID " $ETC/known_hosts > /tmp/e2e/kh
		cat /tmp/e2e/kh > $ETC/known_hosts
	fi
}

case "$1" in
files)
	# Packages and files the real install would provide.
	apk add -q ucode-mod-socket >/dev/null 2>&1 || nok "install ucode-mod-socket" "apk add failed"
	mkdir -p /usr/share/ucode/shadow-vpn $LIB /tmp/e2e
	for m in ssh keys const secrets state; do
		cp $SRC/usr/share/ucode/shadow-vpn/$m.uc /usr/share/ucode/shadow-vpn/
	done
	cp $SRC/usr/libexec/shadow-vpn/ssh-* $T/stubs/libexec/gate-set $T/stubs/libexec/job $LIB/
	chmod 755 $LIB/*
	mkdir -p -m 0700 $ETC $ETC/secrets $ETC/keys $RUN
	umask 077
	hexdump -n 12 -e '12/1 "%02x"' /dev/urandom > $ETC/secrets/$SID.password
	cp $ETC/secrets/$SID.password /w/pw
	chmod 644 /w/pw
	# The desktop's encrypted Ed25519 fixture, stored the way the key form stores it.
	ucode -S -e 'import { readfile, writefile } from "fs"; import { normalize } from "shadow-vpn.keys";
		let f = json(readfile(ARGV[0])), k = f.keys.desktop_ed25519, r = normalize(k.text);
		writefile(ARGV[1], r.text); writefile(ARGV[2], f.passphrase); writefile(ARGV[3], k.public + "\n");
		print(r.type, " ", r.format, " ", r.encrypted, "\n");' \
		$T/keys.json $ETC/keys/$KSID $ETC/secrets/$KSID.passphrase /w/authorized_keys > /tmp/e2e/key.info
	chmod 644 /w/authorized_keys
	check 'files: fixture key normalised as encrypted ed25519' '[ "$(cat /tmp/e2e/key.info)" = "ed25519 openssh true" ]'
	;;

net)
	# The router resolver: dnsmasq on 127.0.0.1 knows the server and says NXDOMAIN for .invalid.
	dnsmasq --no-resolv --no-hosts --listen-address=127.0.0.1 --bind-interfaces --port=53 --user=root \
		--address=/shv-ssh-sshd/$ARG --address=/invalid/ --pid-file=/tmp/e2e/dnsmasq.pid
	echo 'nameserver 127.0.0.1' > /etc/resolv.conf
	nft -f $T/e2e.nft
	check 'net: router resolver answers for the server' '[ "$(nslookup shv-ssh-sshd 127.0.0.1 2>/dev/null | sed -n "s/^Address: *//p" | tail -n 1)" = "$ARG" ]'
	;;

password)
	fresh
	forget_trust
	params password
	start
	until_true '[ "$(phase)" = connected ]'
	check 'password: connected through askpass' '[ "$(phase)" = connected ]'
	check 'password: state text' '[ "$(message)" = "Connected to E2E." ]'
	check 'password: askpass was asked for the password' '[ "$(cat $RUN/ssh.$SID.askpass)" = password ]'
	check 'password: the instance pid is ssh itself' 'case "$(cmdline)" in "/usr/libexec/ssh-openssh -F none "*) true ;; *) false ;; esac'
	check 'password: no secret in argv' '! grep -qF "$(cat $ETC/secrets/$SID.password)" /proc/$(pid)/cmdline'
	check 'password: no secret in the environment' '! grep -qF "$(cat $ETC/secrets/$SID.password)" /proc/$(pid)/environ'
	check 'password: askpass set up by ssh-run' 'tr "\0" "\n" < /proc/$(pid)/environ | grep -qx "SSH_ASKPASS=$LIB/ssh-askpass"'
	check 'password: exactly the server address in @server4' '[ "$(nft list set inet shadow_vpn server4 | grep -o "elements = {[^}]*}")" = "elements = { $ARG }" ]'
	check 'password: @server6 flushed' '! nft list set inet shadow_vpn server6 | grep -q 2001:db8::99'
	check 'password: HostName is the resolved address' 'cmdline | grep -q "HostName=$ARG "'
	check 'password: TOFU stored the host key' 'grep -q "^shadow-$SID ssh-ed25519 " $ETC/known_hosts && [ -s $ETC/trusted.$SID ]'
	check 'password: the key seen is recorded' '[ "$(cut -d " " -f 2 $RUN/hostkey.$SID.seen)" = "$(cut -d " " -f 2 $ETC/trusted.$SID)" ]'
	until_true '[ -e /tmp/e2e/job.started ]'
	check 'password: gate-set ran from ssh-up' '[ -s /tmp/e2e/gate-set.calls ]'
	check 'password: tunnel check started detached' '[ "$(cat /tmp/e2e/job.calls)" = check ]'
	check 'password: SOCKS CONNECT through -D while the check still runs' 'socks_ok && [ ! -e /tmp/e2e/job.done ]'
	touch /tmp/e2e/job.release
	;;

drop)
	# Called after the host ended the session on the server: procd respawns, ssh-run reconnects.
	respawn
	until_true '[ "$(phase)" = connected ]'
	check 'drop: reconnected after the session ended' '[ "$(phase)" = connected ] && socks_ok'
	check 'drop: classified as a lost session' '[ "$(field $RUN/ssh.$SID.last code)" = dropped ]'
	check 'drop: no fatal flag' '[ ! -e $RUN/fatal ]'
	;;

key)
	fresh
	params key
	start
	until_true '[ "$(phase)" = connected ]'
	check 'key: connected with the encrypted key' '[ "$(phase)" = connected ]'
	check 'key: askpass gave the passphrase' '[ "$(cat $RUN/ssh.$SID.askpass)" = passphrase ]'
	check 'key: identity file in argv, passphrase not' 'cmdline | grep -q "IdentityFile=$ETC/keys/$KSID " && ! grep -qF "horse" /proc/$(pid)/cmdline'
	check 'key: SOCKS CONNECT' 'socks_ok'
	touch /tmp/e2e/job.release
	stop
	;;

wrongpass)
	fresh
	cp $ETC/secrets/$KSID.passphrase /tmp/e2e/passphrase
	printf 'wrong horse' > $ETC/secrets/$KSID.passphrase
	params key
	start
	respawn
	until_true '[ "$(phase)" = error ]'
	check 'wrongpass: stops with the desktop text' '[ "$(message)" = "SSH authentication failed: Unable to load SSH private key because the passphrase is wrong." ]'
	check 'wrongpass: fatal flag and attention' '[ -s $RUN/fatal ] && grep -q ssh_fatal $RUN/attention.json'
	until_true 'cmdline | grep -q "^sleep 2147483647"'
	check 'wrongpass: the instance sleeps instead of retrying' 'cmdline | grep -q "^sleep 2147483647"'
	stop
	start
	until_true 'cmdline | grep -q "^sleep 2147483647"'
	check 'fatal: a restarted instance sleeps at once' 'cmdline | grep -q "^sleep 2147483647" && [ ! -s $RUN/ssh.$SID.log ] && ! pgrep -f ssh-openssh >/dev/null'
	cat /tmp/e2e/passphrase > $ETC/secrets/$KSID.passphrase
	;;

auth)
	fresh
	cp $ETC/secrets/$SID.password /tmp/e2e/password
	echo not-the-password > $ETC/secrets/$SID.password
	params password
	start
	respawn
	until_true '[ "$(phase)" = error ]'
	check 'auth: rejected password on the first connect is fatal' '[ "$(message)" = "SSH authentication failed: password auth rejected" ] && [ "$(field $RUN/fatal code)" = auth ]'
	cat /tmp/e2e/password > $ETC/secrets/$SID.password
	stop
	;;

pin)
	# $2: fingerprint of the server's RSA host key; ssh by itself would negotiate Ed25519.
	fresh
	forget_trust
	params password "$ARG"
	start
	until_true '[ "$(phase)" = connected ]'
	check 'pin: a pinned RSA key connects' '[ "$(phase)" = connected ] && socks_ok'
	check 'pin: the pinned key is the trusted one' '[ "$(cut -d " " -f 1,2 $ETC/trusted.$SID)" = "ssh-rsa $ARG" ] && grep -q "^shadow-$SID ssh-rsa " $ETC/known_hosts'
	check 'pin: pin rendered for ssh-hostkey' '[ "$(cat $RUN/pin.$SID)" = "$ARG" ]'
	touch /tmp/e2e/job.release
	stop
	;;

mismatch)
	fresh
	forget_trust
	pin=SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
	params password "$pin"
	start
	until_true '[ "$(phase)" = error ]'
	check 'mismatch: stops before login with every key the server offered' 'message | grep -q "^SSH server fingerprint mismatch: expected $pin, got SHA256:.* (ssh-ed25519), SHA256:.* (ecdsa-sha2-nistp256), SHA256:.* (ssh-rsa)\.$"'
	check 'mismatch: status for LuCI' 'grep -q "^pin_mismatch expected=$pin got=SHA256:" $RUN/hostkey.$SID.status'
	check 'mismatch: nothing trusted' '[ ! -e $ETC/trusted.$SID ]'
	until_true 'cmdline | grep -q "^sleep 2147483647"'
	check 'mismatch: no retries' 'cmdline | grep -q "^sleep 2147483647"'
	stop
	;;

dns)
	fresh
	params password '' nope.invalid
	start
	respawn
	until_true '[ "$(field $RUN/ssh.$SID.last code)" = dns ]'
	check 'dns: NXDOMAIN through the router resolver is temporary' '[ "$(field $RUN/ssh.$SID.last message)" = "getaddrinfo ENOTFOUND nope.invalid" ] && [ ! -e $RUN/fatal ]'
	stop
	;;

prepare-changed)
	# Trust the original key once more, before the host swaps the server's keys.
	fresh
	forget_trust
	params password
	start
	until_true '[ "$(phase)" = connected ]'
	check 'changed: trusted on first use' '[ "$(phase)" = connected ]'
	touch /tmp/e2e/job.release
	stop
	cut -d ' ' -f 2 $ETC/trusted.$SID > /tmp/e2e/trusted.fp
	;;

changed)
	# $2: fingerprint of the impostor's Ed25519 key.
	fresh
	params password
	start
	respawn
	until_true '[ "$(phase)" = error ]'
	check 'changed: a changed host key stops the connection' 'message | grep -qF "SSH server host key does not match the key Shadow trusted on its first connection to shv-ssh-sshd:22: expected $(cat /tmp/e2e/trusted.fp), got $ARG (ssh-ed25519)."'
	check 'changed: status for LuCI' '[ "$(cat $RUN/hostkey.$SID.status)" = "changed expected=$(cat /tmp/e2e/trusted.fp) got=$ARG type=ssh-ed25519" ]'
	check 'changed: the trusted key is kept' '[ "$(cut -d " " -f 2 $ETC/trusted.$SID)" = "$(cat /tmp/e2e/trusted.fp)" ]'
	until_true 'cmdline | grep -q "^sleep 2147483647"'
	stop
	start
	until_true 'cmdline | grep -q "^sleep 2147483647"'
	check 'changed: no retries until Connect' 'cmdline | grep -q "^sleep 2147483647" && ! pgrep -f ssh-openssh >/dev/null'
	stop
	;;

*)
	echo "usage: $0 files|net <ip>|password <ip>|drop|key|wrongpass|auth|pin <fp>|mismatch|dns|prepare-changed|changed <fp>" >&2
	exit 2
	;;
esac

[ $failed -eq 0 ]
