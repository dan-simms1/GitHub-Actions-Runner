FROM debian:bookworm-slim

ENV LANG=C.UTF-8 \
    HOME=/opt/gha

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash ca-certificates curl jq tar gosu libicu72 libssl3 zlib1g libkrb5-3 libgcc-s1 libstdc++6; \
    rm -rf /var/lib/apt/lists/*

RUN useradd -m -d /opt/gha -s /bin/bash runner \
    && mkdir -p /opt/gha \
    && chown -R runner:runner /opt/gha

COPY run.sh /run.sh
RUN chmod +x /run.sh

WORKDIR /opt/gha
ENTRYPOINT ["/run.sh"]
