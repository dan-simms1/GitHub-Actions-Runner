#!/usr/bin/env bash
set -e

# Load configuration from Home Assistant options
CONFIG_PATH="/data/options.json"

# Read configuration values
REPO_URL=$(jq -r '.repo_url' $CONFIG_PATH)
GITHUB_TOKEN=$(jq -r '.github_token' $CONFIG_PATH)
RUNNER_NAME=$(jq -r '.runner_name' $CONFIG_PATH)
RUNNER_LABELS=$(jq -r '.runner_labels' $CONFIG_PATH)
EPHEMERAL=$(jq -r '.ephemeral' $CONFIG_PATH)
WORKDIR=$(jq -r '.workdir' $CONFIG_PATH)
CLEANUP_ON_STOP=$(jq -r '.cleanup_on_stop' $CONFIG_PATH)
LOG_LEVEL=$(jq -r '.log_level' $CONFIG_PATH)
RUNNER_VERSION=$(jq -r '.runner_version' $CONFIG_PATH)

# Set log level
case "$LOG_LEVEL" in
    debug) set -x ;;
    info) ;;
    warning) ;;
    error) ;;
esac

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting GitHub Actions Runner"

# Validate required configuration
if [ -z "$REPO_URL" ] || [ "$REPO_URL" = "null" ]; then
    log "ERROR: repo_url is required"
    exit 1
fi

if [ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "null" ]; then
    log "ERROR: github_token is required"
    exit 1
fi

# Validate repo URL format
if [[ ! "$REPO_URL" =~ ^https://github.com/[^/]+/[^/]+$ ]]; then
    log "ERROR: repo_url must be in format https://github.com/owner/repo"
    exit 1
fi

# Extract owner and repo from URL
REPO_OWNER=$(echo "$REPO_URL" | sed -n 's#https://github.com/\([^/]*\)/.*#\1#p')
REPO_NAME=$(echo "$REPO_URL" | sed -n 's#https://github.com/[^/]*/\(.*\)#\1#p')

log "Repository: $REPO_OWNER/$REPO_NAME"

# Determine architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) RUNNER_ARCH="x64" ;;
    aarch64) RUNNER_ARCH="arm64" ;;
    armv7l) RUNNER_ARCH="arm" ;;
    i686) RUNNER_ARCH="x64" ;;
    *) log "ERROR: Unsupported architecture: $ARCH"; exit 1 ;;
esac

log "Architecture: $RUNNER_ARCH"

# Determine runner version to download
if [ "$RUNNER_VERSION" = "latest" ] || [ -z "$RUNNER_VERSION" ]; then
    log "Fetching latest runner version..."
    RUNNER_VERSION=$(curl -s https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
fi

log "Runner version: $RUNNER_VERSION"

# Download and extract GitHub Actions Runner
RUNNER_DIR="/data/actions-runner"
RUNNER_FILE="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_FILE}"

if [ ! -d "$RUNNER_DIR" ]; then
    log "Creating runner directory..."
    mkdir -p "$RUNNER_DIR"
fi

cd "$RUNNER_DIR"

if [ ! -f "$RUNNER_DIR/config.sh" ]; then
    log "Downloading runner from $DOWNLOAD_URL..."
    if ! curl -L -o "$RUNNER_FILE" "$DOWNLOAD_URL"; then
        log "ERROR: Failed to download runner"
        exit 1
    fi

    log "Extracting runner..."
    if ! tar xzf "$RUNNER_FILE"; then
        log "ERROR: Failed to extract runner"
        exit 1
    fi

    rm -f "$RUNNER_FILE"
    log "Runner downloaded and extracted successfully"
else
    log "Runner already exists, skipping download"
fi

# Create work directory
mkdir -p "$WORKDIR"

# Get registration token from GitHub API
log "Getting registration token from GitHub..."
REG_TOKEN=$(curl -s -X POST \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/registration-token" | jq -r '.token')

if [ -z "$REG_TOKEN" ] || [ "$REG_TOKEN" = "null" ]; then
    log "ERROR: Failed to get registration token. Check your github_token and repo_url"
    exit 1
fi

log "Registration token obtained"

# Remove existing runner configuration if present
if [ -f "$RUNNER_DIR/.runner" ]; then
    log "Removing existing runner configuration..."
    rm -f "$RUNNER_DIR/.runner"
fi

# Configure the runner
log "Configuring runner..."
RUNNER_ALLOW_RUNASROOT=1

CONFIG_OPTS="--url $REPO_URL --token $REG_TOKEN --name $RUNNER_NAME --work $WORKDIR --labels $RUNNER_LABELS --unattended"

if [ "$EPHEMERAL" = "true" ]; then
    CONFIG_OPTS="$CONFIG_OPTS --ephemeral"
fi

# Run configuration as the runner would normally run
if ! ./config.sh $CONFIG_OPTS; then
    log "ERROR: Failed to configure runner"
    exit 1
fi

log "Runner configured successfully"

# Cleanup function
cleanup() {
    log "Received shutdown signal"
    
    if [ "$CLEANUP_ON_STOP" = "true" ]; then
        log "Cleaning up runner..."
        
        # Get removal token
        REMOVE_TOKEN=$(curl -s -X POST \
            -H "Authorization: token ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/actions/runners/remove-token" | jq -r '.token')
        
        if [ -n "$REMOVE_TOKEN" ] && [ "$REMOVE_TOKEN" != "null" ]; then
            log "Removing runner from GitHub..."
            ./config.sh remove --token "$REMOVE_TOKEN" || log "WARNING: Failed to remove runner"
        else
            log "WARNING: Failed to get removal token"
        fi
    fi
    
    log "Shutdown complete"
    exit 0
}

# Trap SIGTERM for graceful shutdown
trap cleanup SIGTERM SIGINT

# Run the GitHub Actions runner
log "Starting runner..."
./run.sh &

# Wait for the runner process
RUNNER_PID=$!
wait $RUNNER_PID
