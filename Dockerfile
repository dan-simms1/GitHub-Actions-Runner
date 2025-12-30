ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM}

ENV LANG=C.UTF-8 \
    HOME=/opt/gha

RUN set -eux; \
    if command -v apt-get >/dev/null; then \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            bash ca-certificates curl jq tar gosu libicu72 libssl3 zlib1g libkrb5-3 libgcc-s1 libstdc++6; \
        rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null; then \
        apk add --no-cache \
            bash ca-certificates curl jq tar shadow su-exec \
            gcompat icu-libs icu-data-full gettext-libs krb5-libs libc6-compat libgcc libstdc++ zlib; \
        GLIBC_VER="2.38-r1"; \
        wget -q -O /etc/apk/keys/sgerrand.rsa.pub https://alpine-pkgs.sgerrand.com/sgerrand.rsa.pub; \
        wget -q https://github.com/sgerrand/alpine-pkg-glibc/releases/download/${GLIBC_VER}/glibc-${GLIBC_VER}.apk; \
        apk add --no-cache glibc-${GLIBC_VER}.apk; \
        rm -f glibc-${GLIBC_VER}.apk; \
    else \
        echo "Unsupported base image: missing apt-get/apk" >&2; \
        exit 1; \
    fi

RUN useradd -m -d /opt/gha -s /bin/bash runner \
    && mkdir -p /opt/gha \
    && chown -R runner:runner /opt/gha

COPY run.sh /run.sh
RUN chmod +x /run.sh

WORKDIR /opt/gha
ENTRYPOINT ["/run.sh"]
