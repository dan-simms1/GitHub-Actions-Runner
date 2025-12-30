ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM}

ENV LANG=C.UTF-8 \
    HOME=/opt/gha

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        jq \
        tar \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -d /opt/gha -s /bin/bash runner \
    && mkdir -p /opt/gha \
    && chown -R runner:runner /opt/gha

COPY run.sh /run.sh
RUN chmod +x /run.sh

USER runner
WORKDIR /opt/gha

HEALTHCHECK --interval=60s --timeout=10s --start-period=60s CMD pgrep -f Runner\\.Listener >/dev/null || exit 1

ENTRYPOINT ["/run.sh"]
