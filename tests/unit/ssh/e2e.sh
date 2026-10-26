#!/bin/bash
# End-to-end test of the SSH helpers (DESIGN §8) against a real sshd, in throwaway containers:
#   shv-ssh-net     a Docker network
#   shv-ssh-sshd    sshd (shadow-testenv/vpn image), user "tunnel", a TCP service on its 127.0.0.1:8080
#   shv-ssh-router  the router image with ssh.uc, keys.uc and the helpers on their real paths
#   shv-ssh-work    a volume both share (the generated password and the authorized key)
# The sources are copied in with tar (no bind mounts).
# Proves: password login via askpass, key login with an encrypted key, SOCKS CONNECT on the -D port,
# LocalCommand ssh-up returning while the tunnel check still runs, the exact server address in
# @server4, reconnect after a dropped session, TOFU and then refusal of a changed host key, a pinned
# RSA key and a pin mismatch, DNS failure through the router resolver, and that a fatal error stops
# retries. Everything it starts is removed on exit. Usage: tests/unit/ssh/e2e.sh
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../../.." && pwd)"
ROUTER_IMG="${SHADOW_TEST_IMAGE:-shadow-testenv/tr3000-deps:25.12.6}"
SSHD_IMG="${SHADOW_SSHD_IMAGE:-shadow-testenv/vpn:xray26.3.27}"
NET=shv-ssh-net SSHD=shv-ssh-sshd ROUTER=shv-ssh-router WORK=shv-ssh-work

cleanup() {
	docker rm -f "$SSHD" "$ROUTER" >/dev/null 2>&1
	docker volume rm "$WORK" >/dev/null 2>&1
	docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

for img in "$ROUTER_IMG" "$SSHD_IMG"; do
	docker image inspect "$img" >/dev/null 2>&1 || { echo "missing image $img: build the lab images first" >&2; exit 2; }
done

cleanup
docker network create "$NET" >/dev/null || exit 2
docker volume create "$WORK" >/dev/null || exit 2

failed=0

router() {
	docker exec "$ROUTER" sh /src/tests/unit/ssh/e2e-router.sh "$@" || failed=1
}

sshd() {
	docker exec "$SSHD" sh /t/e2e-sshd.sh "$@"
}

# The sources go in as tar streams, not bind mounts: OrbStack bind mounts can show a stale, cut-off copy
# of a file that was just rewritten (tests/unit/run.sh does the same).
docker run -d --init --name "$ROUTER" --hostname router --network "$NET" --cap-add NET_ADMIN \
	-v "$WORK:/w" --entrypoint /bin/sh "$ROUTER_IMG" -c 'exec sleep 86400' >/dev/null || exit 2
COPYFILE_DISABLE=1 tar -C "$SRC" --exclude .DS_Store -cf - shadow-vpn/files tests/unit/ssh |
	docker exec -i "$ROUTER" sh -c 'mkdir -p /src && tar -xf - -C /src && chmod -R a-w /src' || exit 2
router files

docker run -d --init --name "$SSHD" --hostname vpn --network "$NET" \
	-v "$WORK:/w:ro" --entrypoint /bin/sh "$SSHD_IMG" -c 'exec sleep 86400' >/dev/null || exit 2
COPYFILE_DISABLE=1 tar -C "$HERE" --exclude .DS_Store -cf - . |
	docker exec -i "$SSHD" sh -c 'mkdir -p /t && tar -xf - -C /t && chmod -R a-w /t' || exit 2
sshd start || { echo "not ok sshd: setup failed"; exit 1; }
SSHD_IP=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$SSHD")

router net "$SSHD_IP"
router password "$SSHD_IP"
sshd kick
router drop
router key
router wrongpass
router auth
router pin "$(sshd fp rsa)"
router mismatch
router dns
router prepare-changed
sshd swap || { echo "not ok sshd: host key swap failed"; failed=1; }
router changed "$(docker exec "$SSHD" ssh-keygen -lf /etc/ssh/impostor_ed25519_key.pub | cut -d ' ' -f 2)"

[ "$failed" -eq 0 ] && echo "# e2e: all passed" || echo "# e2e: FAILED"
exit "$failed"
