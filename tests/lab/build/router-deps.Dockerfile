# Factory TR3000 rootfs + the runtime deps Shadow is expected to pull in (MODE=deps).
# MODE=factory skips this image so install.sh can be tested from scratch.
ARG BASE
FROM ${BASE}
ARG SHADOW_PKGS="dnsmasq-full xray-core openssh-client kmod-nft-tproxy kmod-nft-socket luci-i18n-base-ru"
ARG DEBUG_PKGS="curl socat ss ip-full conntrack tcpdump-mini"
RUN set -x; mkdir -p /tmp/lock /var/lock; \
    if command -v apk >/dev/null; then \
        apk update && apk add ${SHADOW_PKGS} ${DEBUG_PKGS}; \
    else \
        opkg update && cd /tmp && opkg download dnsmasq-full && opkg remove dnsmasq \
        && opkg install /tmp/dnsmasq-full*.ipk ${SHADOW_PKGS#dnsmasq-full } ${DEBUG_PKGS} \
        && rm -f /tmp/*.ipk; \
    fi; rc=$?; rm -f /etc/config/*.apk-new /etc/config/*-opkg; \
    command -v xray && command -v ssh && dnsmasq --version | grep -q nftset && exit 0 || exit $rc
CMD ["/sbin/init"]
