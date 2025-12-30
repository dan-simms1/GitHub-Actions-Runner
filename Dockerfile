ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM}

ENV LANG=C.UTF-8 \
    HOME=/opt/gha

RUN set -eux; \
    if command -v apt-get >/dev/null; then \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            bash \
            ca-certificates \
            curl \
            jq \
            tar; \
        rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null; then \
        apk add --no-cache \
            bash \
            ca-certificates \
            curl \
            jq \
            tar \
            shadow; \
    else \
        echo "Unsupported base image: missing apt-get/apk" >&2; \
        exit 1; \
    fi

RUN useradd -m -d /opt/gha -s /bin/bash runner \
    && mkdir -p /opt/gha \
    && chown -R runner:runner /opt/gha \
    && chmod 644 /data/options.json \
    && chown -R runner:runner /data/options.json 

COPY run.sh /run.sh
RUN chmod +x /run.sh


# Run as root to ensure access to /data/options.json
USER runner
WORKDIR /opt/gha

HEALTHCHECK --interval=60s --timeout=10s --start-period=60s CMD pgrep -f Runner\\.Listener >/dev/null || exit 1

ENTRYPOINT ["/run.sh"]
