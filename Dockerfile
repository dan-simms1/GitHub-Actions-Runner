ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM}

ENV LANG=C.UTF-8 \
    HOME=/opt/gha

RUN set -eux; \
    if command -v apt-get >/dev/null; then \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            bash ca-certificates curl jq tar gosu; \
        rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null; then \
        apk add --no-cache \
            bash ca-certificates curl jq tar shadow su-exec \
            gcompat icu-libs icu-data-full krb5-libs libc6-compat libgcc libstdc++ zlib; \
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
