ARG BUILD_FROM
FROM $BUILD_FROM

# Install required packages
RUN apk add --no-cache \
    curl \
    jq \
    ca-certificates \
    bash \
    tar \
    git \
    sudo

# Create a non-root user for running the runner
RUN addgroup -g 1000 runner && \
    adduser -D -u 1000 -G runner runner && \
    mkdir -p /data/work && \
    chown -R runner:runner /data

# Copy run script
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Set working directory
WORKDIR /data

# Run as non-root user
USER runner

CMD ["/run.sh"]
