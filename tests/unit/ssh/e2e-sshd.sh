#!/bin/sh
# sshd side of tests/unit/ssh/e2e.sh, in a throwaway shadow-testenv/vpn container (Alpine, OpenSSH
# server, socat). /w is the test's work volume, /t this directory.
#   start   user "tunnel" (password /w/pw, key /w/authorized_keys), a TCP service on 127.0.0.1:8080, sshd
#   swap    restart sshd with one new Ed25519 host key (an impostor, as far as TOFU can tell)
#   kick    end the tunnel user's sessions
#   fp <t>  SHA256 fingerprint of the original <t> host key (rsa, ecdsa, ed25519)
set -e

# Only the listener: sessions run in their own sshd-session processes. busybox pgrep -x looks at
# the rewritten process title, so the pid file is the reliable handle.
restart_sshd() {
	if [ -s /var/run/sshd.pid ]; then
		pid=$(cat /var/run/sshd.pid)
		kill "$pid" 2>/dev/null || true
		while kill -0 "$pid" 2>/dev/null; do sleep 1; done
	fi
	/usr/sbin/sshd -f /t/e2e-sshd_config "$@"
}

case "$1" in
start)
	adduser -D -s /bin/sh tunnel 2>/dev/null || true
	echo "tunnel:$(cat /w/pw)" | chpasswd >/dev/null
	install -d -m 700 -o tunnel -g tunnel /home/tunnel/.ssh
	install -m 600 -o tunnel -g tunnel /w/authorized_keys /home/tunnel/.ssh/authorized_keys
	ssh-keygen -q -t ed25519 -N '' -f /etc/ssh/impostor_ed25519_key
	socat TCP-LISTEN:8080,bind=127.0.0.1,fork,reuseaddr EXEC:'/bin/sh /t/e2e-reply.sh' >/dev/null 2>&1 &
	restart_sshd
	;;
swap)
	restart_sshd -h /etc/ssh/impostor_ed25519_key
	;;
kick)
	pkill -u tunnel || true
	;;
fp)
	ssh-keygen -lf "/etc/ssh/ssh_host_$2_key.pub" | cut -d ' ' -f 2
	;;
esac
