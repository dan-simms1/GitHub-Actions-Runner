#!/usr/bin/env bash
set -euo pipefail

OPTIONS_FILE="/data/options.json"

RUNNER_ROOT="/opt/gha/actions-runner"
DEFAULT_RUNNER_VERSION="latest"   # was 2.317.0, which can 404
CLEANUP_ON_STOP="true"

timestamp() {
  # BusyBox: date -Iseconds
  if date -Iseconds >/dev/null 2>&1; then
    date -Iseconds
  # GNU coreutils: date --iso-8601=seconds
  elif date --iso-8601=seconds >/dev/null 2>&1; then
    date --iso-8601=seconds
  else
    date '+%Y-%m-%dT%H:%M:%S%z'
  fi
}

level_to_num() {
  case "${1,,}" in
    debug) echo 0 ;;
    info) echo 1 ;;
    warn|warning) echo 2 ;;
    error) echo 3 ;;
    *) echo 1 ;;
  esac
}

LOG_LEVEL="${LOG_LEVEL:-info}"
CURRENT_LOG_LEVEL="$(level_to_num "${LOG_LEVEL}")"

log() {
  local level="${1,,}"
  shift || true
  local msg="$*"
  local lvl_num
  lvl_num="$(level_to_num "${level}")"
  if [[ "${lvl_num}" -lt "${CURRENT_LOG_LEVEL}" ]]; then
    return
  fi
  printf '%s [%s] %s\n' "$(timestamp)" "${level^^}" "${msg}"
}

require_file() {
  if [[ ! -f "${1}" ]]; then
    log error "Required file ${1} not found"
    exit 1
  fi
}

as_runner() {
  if command -v su-exec >/dev/null 2>&1; then
    su-exec runner:runner "$@"
  elif command -v gosu >/dev/null 2>&1; then
    gosu runner:runner "$@"
  else
    log error "Neither su-exec nor gosu is installed (needed to drop privileges)"
    exit 1
  fi
}

load_option() {
  local key="${1}"
  local default="${2:-}"
  jq -r --arg key "${key}" --arg default "${default}" \
    'if has($key) and .[$key] != null then .[$key] else $default end' \
    "${OPTIONS_FILE}"
}

require_nonempty() {
  local name="${1}"
  local value="${2}"
  if [[ -z "${value}" ]]; then
    log error "Required option '${name}' is missing or empty"
    exit 1
  fi
}

detect_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "arm" ;;
    i386|i686)
      log warn "Upstream runner has no dedicated i386 build; falling back to x64 tarball"
      echo "x64"
      ;;
    *)
      log error "Unsupported architecture: ${arch}"
      exit 1
      ;;
  esac
}

ensure_runner_dir() {
  mkdir -p "${RUNNER_ROOT}"
  chown -R runner:runner "${RUNNER_ROOT}"
  cd "${RUNNER_ROOT}"
}

get_latest_runner_version() {
  # GitHub API returns tag_name like "v2.329.0"
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' || true)"
  tag="${tag#v}"
  if [[ -z "${tag}" || "${tag}" == "null" ]]; then
    return 1
  fi
  echo "${tag}"
}

install_runner_deps_if_possible() {
  # Works on Debian based images. On Alpine this will not fix glibc issues.
  if [[ -x "./bin/installdependencies.sh" ]]; then
    log info "Installing GitHub runner dependencies"
    ./bin/installdependencies.sh || log warn "Dependency install script failed, continuing"
  fi
}

ensure_runner_downloaded() {
  local runner_arch="${1}"
  local runner_version="${2}"

  local cached_version=""
  if [[ -f ".runner_version" ]]; then
    cached_version="$(< .runner_version)"
  fi
  if [[ "${cached_version}" == "${runner_version}" && -x "./bin/Runner.Listener" ]]; then
    log info "Using cached runner version ${runner_version}"
    return
  fi

  log info "Downloading GitHub Actions runner v${runner_version} for ${runner_arch}"
  rm -rf ./*

  local tgz="actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"
  local base_url="https://github.com/actions/runner/releases/download/v${runner_version}"
  local url="${base_url}/${tgz}"

  if ! curl -fSL -o "${tgz}" "${url}"; then
    log error "Failed to download runner from ${url}"
    log error "If you pinned runner_version, try a newer version. If you used 'latest', check outbound access from the add-on."
    exit 1
  fi

  if curl -fsSL -o "${tgz}.sha256" "${url}.sha256"; then
    local expected
    expected="$(cut -d ' ' -f1 < "${tgz}.sha256" || true)"
    if [[ -n "${expected}" ]]; then
      echo "${expected}  ${tgz}" | sha256sum -c - || log warn "Checksum verification failed, continuing"
    else
      log warn "Checksum file empty, skipping verification"
    fi
  else
    log warn "Checksum not available, skipping verification"
  fi

  tar -xzf "${tgz}"
  rm -f "${tgz}" "${tgz}.sha256"
  echo "${runner_version}" > .runner_version

  install_runner_deps_if_possible

  # Ensure runner owns everything after extract
  chown -R runner:runner "${RUNNER_ROOT}"
}

cleanup_runner() {
  if [[ "${CLEANUP_ON_STOP:-true}" != "true" ]]; then
    log info "Cleanup on stop disabled, skipping deregistration"
    exit 0
  fi
  log warn "Cleaning up runner registration"
  as_runner ./config.sh remove --unattended || true
  exit 0
}

start_runner_as_runner() {
  log info "Starting GitHub Actions runner service (as runner user)"
  as_runner ./run.sh &
  local pid=$!
  wait "${pid}"
  local code=$?
  log warn "Runner exited with status ${code}"
  return "${code}"
}

main() {
  require_file "${OPTIONS_FILE}"

  local repo_url
  repo_url="$(load_option "repo_url")"
  require_nonempty "repo_url" "${repo_url}"

  local github_token
  github_token="$(load_option "github_token")"
  require_nonempty "github_token" "${github_token}"

  local runner_name
  runner_name="$(load_option "runner_name" "ha-runner-1")"

  local runner_labels_csv
  runner_labels_csv="$(jq -r '.runner_labels // ["ha","self-hosted"] | map(select(. != null and . != "")) | if length == 0 then ["ha","self-hosted"] else . end | join(",")' "${OPTIONS_FILE}")"

  local ephemeral
  ephemeral="$(load_option "ephemeral" "true")"

  local workdir
  workdir="$(load_option "workdir" "/data/_work")"

  local cleanup_on_stop
  cleanup_on_stop="$(load_option "cleanup_on_stop" "true")"

  local configured_log_level
  configured_log_level="$(load_option "log_level" "info")"
  LOG_LEVEL="${configured_log_level}"
  CURRENT_LOG_LEVEL="$(level_to_num "${LOG_LEVEL}")"

  local runner_version
  runner_version="$(load_option "runner_version" "")"
  if [[ -z "${runner_version}" ]]; then
    runner_version="${DEFAULT_RUNNER_VERSION}"
  fi
  if [[ "${runner_version}" == "latest" ]]; then
    runner_version="$(get_latest_runner_version || true)"
    if [[ -z "${runner_version}" ]]; then
      log error "Could not determine latest runner version from GitHub API"
      exit 1
    fi
    log info "Using latest runner version ${runner_version}"
  fi

  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export HOME="/opt/gha"

  local runner_arch
  runner_arch="$(detect_arch)"

  # Ensure workdir exists and is writable by runner
  mkdir -p "${workdir}"
  chown -R runner:runner "${workdir}"

  ensure_runner_dir
  ensure_runner_downloaded "${runner_arch}" "${runner_version}"

  CLEANUP_ON_STOP="${cleanup_on_stop}"
  trap cleanup_runner SIGINT SIGTERM

  # Configure as runner (GitHub runner refuses to run as root)
  if [[ -f ".runner" ]]; then
    log warn "Existing runner configuration detected, removing before re-configuring"
    as_runner ./config.sh remove --unattended || rm -f .runner
  fi

  log info "Configuring runner '${runner_name}' (ephemeral=${ephemeral}) for ${repo_url}"
  if [[ "${ephemeral}" == "true" ]]; then
    as_runner ./config.sh \
      --url "${repo_url}" \
      --token "${github_token}" \
      --name "${runner_name}" \
      --labels "${runner_labels_csv}" \
      --work "${workdir}" \
      --unattended \
      --ephemeral
  else
    as_runner ./config.sh \
      --url "${repo_url}" \
      --token "${github_token}" \
      --name "${runner_name}" \
      --labels "${runner_labels_csv}" \
      --work "${workdir}" \
      --unattended
  fi

  unset github_token

  start_runner_as_runner
}

main "$@"