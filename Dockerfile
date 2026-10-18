# syntax=docker/dockerfile:1

ARG ALPINE_VERSION=3.24
ARG SOFTETHER_VERSION=v4.44-9807-rtm
ARG SOFTETHER_COMMIT=ed17437af9719ac66acab30faa29e375d613c35f

FROM alpine:${ALPINE_VERSION} AS build
ARG SOFTETHER_VERSION
ARG SOFTETHER_COMMIT
SHELL ["/bin/sh", "-o", "pipefail", "-c"]
WORKDIR /src

# Package versions come from the pinned Alpine 3.24 branch. Dependabot updates that base.
# GCC 15 defaults to C23, where bool is a keyword, and treats several old C patterns as
# errors. SoftEther 4.44 is built as C11 with those diagnostics downgraded to warnings.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        build-base \
        git \
        linux-headers \
        ncurses-dev \
        openssl-dev \
        readline-dev \
        zlib-dev \
    && git -c advice.detachedHead=false clone --depth 1 --branch "${SOFTETHER_VERSION}" \
        https://github.com/SoftEtherVPN/SoftEtherVPN_Stable.git . \
    && test "$(git rev-parse HEAD)" = "${SOFTETHER_COMMIT}" \
    && grep -Fq 'UnixVLanCreateEx(name, "vpn", mac_address);' src/Cedar/VLanUnix.c \
    && mkdir -p tmp/objs/Mayaqua tmp/objs/Cedar tmp/as \
        bin/vpnclient bin/vpncmd \
    && ./configure \
    && make -j"$(nproc)" CC="gcc -std=gnu11 -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration -Wno-error=int-conversion -Wno-error=return-mismatch" bin/vpnclient/vpnclient bin/vpncmd/vpncmd \
    && mkdir -p /opt/install/usr/vpnclient /opt/install/usr/vpncmd /opt/install/usr/bin \
    && cp bin/vpnclient/vpnclient bin/vpnclient/hamcore.se2 /opt/install/usr/vpnclient/ \
    && cp bin/vpncmd/vpncmd bin/vpncmd/hamcore.se2 /opt/install/usr/vpncmd/ \
    && strip /opt/install/usr/vpnclient/vpnclient /opt/install/usr/vpncmd/vpncmd \
    && printf '%s\n' '#!/bin/sh' 'exec /usr/vpnclient/vpnclient "$@"' > /opt/install/usr/bin/vpnclient \
    && printf '%s\n' '#!/bin/sh' 'exec /usr/vpncmd/vpncmd "$@"' > /opt/install/usr/bin/vpncmd \
    && chmod 755 /opt/install/usr/bin/vpnclient /opt/install/usr/bin/vpncmd

FROM alpine:${ALPINE_VERSION}
ARG SOFTETHER_VERSION
ARG SOFTETHER_COMMIT
SHELL ["/bin/sh", "-o", "pipefail", "-c"]

LABEL org.opencontainers.image.title="docker-softether-vpn-client" \
      org.opencontainers.image.description="Alpine container that connects to one SoftEther VPN server." \
      org.opencontainers.image.source="https://github.com/nefarius/docker-softether-vpn-client" \
      org.opencontainers.image.url="https://github.com/nefarius/docker-softether-vpn-client" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${SOFTETHER_VERSION}" \
      org.opencontainers.image.revision="${SOFTETHER_COMMIT}"

# The client remains root: creating a TUN/TAP adapter and configuring it requires it.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        dhcpcd \
        ncurses-libs \
        openssl \
        readline \
        supervisor \
        zlib \
    && mkdir -p /usr/vpnclient /var/log/supervisor

ENV LANG=C.UTF-8 \
    SE_ACCOUNT_NAME=default \
    SE_TYPE=standard \
    SE_NICNAME=vpn

COPY --from=build /opt/install/ /
COPY --chmod=755 assets/entrypoint.sh /entrypoint.sh
COPY --chmod=755 assets/dhcpcd-vpn /usr/local/bin/dhcpcd-vpn
COPY assets/supervisord.conf /etc/supervisord.conf

ENTRYPOINT ["/entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
