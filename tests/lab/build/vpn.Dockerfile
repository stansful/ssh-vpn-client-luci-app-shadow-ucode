# "Your own server": sshd (ssh -D target) + official Xray-core build (same version as the OpenWrt feed).
ARG XRAY_IMG=ghcr.io/xtls/xray-core:26.3.27
ARG TOOLS_IMG=shadow-testenv/tools:alpine3.22
FROM ${XRAY_IMG} AS xray
FROM ${TOOLS_IMG}
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
