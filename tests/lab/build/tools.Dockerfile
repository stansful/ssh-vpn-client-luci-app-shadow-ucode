# Helper image for the lan-client, web (+DNS) and vpn-server roles.
FROM alpine:3.22
RUN apk add --no-cache curl bind-tools iproute2 openssh-server socat tcpdump nftables \
        iperf3 dnsmasq nginx openssl \
 && ssh-keygen -A \
 && adduser -D -s /bin/sh vpnuser
