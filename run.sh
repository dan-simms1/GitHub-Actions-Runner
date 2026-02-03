#!/usr/bin/env bash
set -euo pipefail

OPTIONS_FILE="/data/options.json"

RUNNER_ROOT="/data/actions-runner"
LEGACY_RUNNER_ROOT="/opt/gha/actions-runner"
DEFAULT_RUNNER_VERSION="latest"   # was 2.317.0, which can 404
ADDON_VERSION="1.1.25"
RUNNER_PID=""

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
  if [[ -d "${LEGACY_RUNNER_ROOT}" && ! -e "${RUNNER_ROOT}/.runner" && ! -e "${RUNNER_ROOT}/.credentials" ]]; then
    if [[ -n "$(ls -A "${LEGACY_RUNNER_ROOT}" 2>/dev/null)" ]]; then
      log info "Migrating existing runner data from ${LEGACY_RUNNER_ROOT} to ${RUNNER_ROOT}"
      mkdir -p "${RUNNER_ROOT}"
      cp -a "${LEGACY_RUNNER_ROOT}/." "${RUNNER_ROOT}/" || log warn "Migration from legacy runner path failed, continuing with fresh setup"
    fi
  fi

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
  if [[ -x "./bin/installdependencies.sh" ]]; then
    log info "Installing GitHub runner dependencies"
    ./bin/installdependencies.sh || log warn "Dependency install script failed, continuing"
  fi
}

log_system_info() {
  log info "System diagnostics: uname=$(uname -a)"
  if [[ -r /etc/os-release ]]; then
    while IFS= read -r line; do
      log info "os-release: ${line}"
    done < /etc/os-release
  else
    log warn "/etc/os-release not found"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    log info "Package manager: apt-get"
  else
    log warn "Package manager: none detected (no apt-get)"
  fi
  if command -v ldd >/dev/null 2>&1; then
    log info "ldd: $(ldd --version 2>&1 | head -n1)"
  fi
  for ldso in /lib/ld-linux* /lib64/ld-linux* /usr/lib/ld-linux*; do
    if [[ -e "${ldso}" ]]; then
      log info "ld-so present: ${ldso}"
    fi
  done
}

repo_parts_from_url() {
  local url="${1}"
  url="${url#https://}"
  url="${url#http://}"
  if [[ "${url}" == */*/* ]]; then
    url="${url#*/}"
  fi
  url="${url%.git}"
  local owner repo
  owner="${url%%/*}"
  repo="${url#*/}"
  if [[ -z "${owner}" || -z "${repo}" || "${owner}" == "${repo}" ]]; then
    return 1
  fi
  echo "${owner} ${repo}"
}

is_probably_pat() {
  case "${1}" in
    ghp_*|gho_*|ghu_*|ghs_*|ghr_*|github_pat_*) return 0 ;;
    *) return 1 ;;
  esac
}

github_api_base_from_url() {
  local url="${1}"
  local host
  host="${url#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  if [[ -z "${host}" || "${host}" == "github.com" ]]; then
    echo "https://api.github.com"
  else
    echo "https://${host}/api/v3"
  fi
}

get_registration_token_from_pat() {
  local repo_url="${1}"
  local pat="${2}"
  local parts owner repo api_base
  parts="$(repo_parts_from_url "${repo_url}" || true)"
  if [[ -z "${parts}" ]]; then
    return 1
  fi
  owner="${parts%% *}"
  repo="${parts#* }"
  api_base="$(github_api_base_from_url "${repo_url}")"
  curl -fsSL -X POST \
    -H "Authorization: Bearer ${pat}" \
    -H "Accept: application/vnd.github+json" \
    "${api_base}/repos/${owner}/${repo}/actions/runners/registration-token" \
    | jq -r '.token'
}

get_removal_token_from_pat() {
  local repo_url="${1}"
  local pat="${2}"
  local parts owner repo api_base
  parts="$(repo_parts_from_url "${repo_url}" || true)"
  if [[ -z "${parts}" ]]; then
    return 1
  fi
  owner="${parts%% *}"
  repo="${parts#* }"
  api_base="$(github_api_base_from_url "${repo_url}")"
  curl -fsSL -X POST \
    -H "Authorization: Bearer ${pat}" \
    -H "Accept: application/vnd.github+json" \
    "${api_base}/repos/${owner}/${repo}/actions/runners/remove-token" \
    | jq -r '.token'
}

remove_runner_remote_if_exists() {
  local repo_url="${1}"
  local token="${2}"
  local runner_name="${3}"

  local parts owner repo
  parts="$(repo_parts_from_url "${repo_url}" || true)"
  if [[ -z "${parts}" ]]; then
    log warn "Could not parse owner/repo from ${repo_url}; skipping remote runner cleanup"
    return
  fi
  owner="${parts%% *}"
  repo="${parts#* }"

  local list_json runner_id
  list_json="$(curl -fsSL -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    "$(github_api_base_from_url "${repo_url}")/repos/${owner}/${repo}/actions/runners?per_page=100" 2>/dev/null || true)"
  runner_id="$(echo "${list_json}" | jq -r --arg name "${runner_name}" '.runners[]? | select(.name == $name) | .id' | head -n1)"
  if [[ -z "${runner_id}" || "${runner_id}" == "null" ]]; then
    log info "No existing runner named '${runner_name}' found via GitHub API"
    return
  fi
  log warn "Found existing runner '${runner_name}' (id=${runner_id}) on GitHub; attempting removal"
  if curl -fsSL -X DELETE \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    "$(github_api_base_from_url "${repo_url}")/repos/${owner}/${repo}/actions/runners/${runner_id}" >/dev/null 2>&1; then
    log info "Removed runner '${runner_name}' (id=${runner_id}) via GitHub API"
  else
    log warn "Failed to remove runner '${runner_name}' (id=${runner_id}) via GitHub API; continuing"
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
  # Preserve existing credentials/config when updating the runner bits
  local preserve_tmp=""
  for f in .runner .credentials .credentials_rsaparams .path .service .env; do
    if [[ -e "${f}" ]]; then
      if [[ -z "${preserve_tmp}" ]]; then
        preserve_tmp="$(mktemp -d)"
      fi
      cp -a "${f}" "${preserve_tmp}/" || log warn "Failed to preserve ${f} during runner update"
    fi
  done

  rm -rf ./*
  if [[ -n "${preserve_tmp}" ]]; then
    cp -a "${preserve_tmp}/." . || log warn "Failed to restore preserved runner config"
    rm -rf "${preserve_tmp}"
  fi

  local tgz="actions-runner-linux-${runner_arch}-${runner_version}.tar.gz"
  local base_url="https://github.com/actions/runner/releases/download/v${runner_version}"
  local url="${base_url}/${tgz}"

  if ! curl -fSL -o "${tgz}" "${url}"; then
    log error "Failed to download runner from ${url}"
    log error "If you pinned runner_version, try a newer version. If you used 'latest', check outbound access from the add-on."
    exit 1
  fi

  if curl -fsSL -o "${tgz}.sha256" "${url}.sha256" 2>/dev/null; then
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

clear_local_runner_config() {
  local removed="false"
  for f in .runner .credentials .credentials_rsaparams .env .path .service .settings; do
    if [[ -e "${f}" ]]; then
      removed="true"
      rm -f "${f}" || log warn "Failed to remove ${f}"
    fi
  done
  if [[ "${removed}" == "true" ]]; then
    log info "Removed local runner configuration files"
  fi
}

shutdown_runner() {
  log warn "Stopping runner"
  if [[ -n "${RUNNER_PID}" ]]; then
    if kill -0 "${RUNNER_PID}" 2>/dev/null; then
      log info "Stopping runner process (pid ${RUNNER_PID})"
      kill "${RUNNER_PID}" 2>/dev/null || true
      local waited=0
      while kill -0 "${RUNNER_PID}" 2>/dev/null; do
        if [[ "${waited}" -ge 20 ]]; then
          log warn "Runner did not exit; sending SIGKILL"
          kill -9 "${RUNNER_PID}" 2>/dev/null || true
          break
        fi
        sleep 1
        waited=$((waited + 1))
      done
    fi
  fi
  exit 0
}

start_runner_as_runner() {
  log info "Starting GitHub Actions runner service (as runner user)"
  as_runner ./run.sh &
  RUNNER_PID=$!
  local pid="${RUNNER_PID}"
  sleep 2
  if kill -0 "${pid}" 2>/dev/null; then
    log info "Runner process is running (pid ${pid})"
  else
    log warn "Runner process exited immediately after launch"
  fi
  wait "${pid}"
  local code=$?
  RUNNER_PID=""
  log warn "Runner exited with status ${code}"
  return "${code}"
}

main() {
  require_file "${OPTIONS_FILE}"

  local repo_url
  repo_url="$(load_option "repo_url")"
  require_nonempty "repo_url" "${repo_url}"

  local github_token
  github_token="$(load_option "github_token" "")"
  local github_pat=""
  local registration_token=""
  local removal_token=""

  local runner_name
  runner_name="$(load_option "runner_name" "ha-runner-1")"
  local runner_name_effective="${runner_name}"

  local runner_labels_csv
  runner_labels_csv="$(jq -r '.runner_labels // ["ha","self-hosted"] | map(select(. != null and . != "")) | if length == 0 then ["ha","self-hosted"] else . end | join(",")' "${OPTIONS_FILE}")"

  local ephemeral
  ephemeral="$(load_option "ephemeral" "false")"

  local workdir
  workdir="$(load_option "workdir" "/data/_work")"

  local force_reregister
  force_reregister="$(load_option "force_reregister" "false")"

  local configured_log_level
  configured_log_level="$(load_option "log_level" "info")"
  LOG_LEVEL="${configured_log_level}"
  CURRENT_LOG_LEVEL="$(level_to_num "${LOG_LEVEL}")"
  log info "Add-on version ${ADDON_VERSION}"

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

  log_system_info

  if [[ -n "${github_token}" ]]; then
    if is_probably_pat "${github_token}"; then
      github_pat="${github_token}"
      registration_token="$(get_registration_token_from_pat "${repo_url}" "${github_pat}" || true)"
      if [[ -n "${registration_token}" && "${registration_token}" != "null" ]]; then
        log info "Obtained runner registration token from GitHub API"
      else
        registration_token=""
        log warn "Failed to obtain runner registration token from GitHub API; check PAT scopes"
      fi

      removal_token="$(get_removal_token_from_pat "${repo_url}" "${github_pat}" || true)"
      if [[ -n "${removal_token}" && "${removal_token}" != "null" ]]; then
        log info "Obtained runner removal token from GitHub API"
      else
        removal_token=""
      fi
    else
      registration_token="${github_token}"
    fi
  fi

  # Ensure workdir exists and is writable by runner
  mkdir -p "${workdir}"
  chown -R runner:runner "${workdir}"

  ensure_runner_dir
  ensure_runner_downloaded "${runner_arch}" "${runner_version}"

  trap shutdown_runner SIGINT SIGTERM

  # Configure as runner (GitHub runner refuses to run as root)
  # If config exists but github_token is provided, re-register to replace stale/removed registrations
  local has_runner_config="false"
  if [[ -e ".runner" || -e ".credentials" ]]; then
    has_runner_config="true"
  fi

  local has_partial_config="false"
  for f in .runner .credentials .credentials_rsaparams .env .path .service .settings; do
    if [[ -e "${f}" ]]; then
      has_partial_config="true"
      break
    fi
  done

  local remote_runner_removed="false"

  if [[ "${has_runner_config}" == "true" ]]; then
    if [[ "${force_reregister}" == "true" ]]; then
      if [[ -z "${registration_token}" ]]; then
        log error "force_reregister is true but no registration token is available"
        log error "Provide a registration token, or a PAT with repo/administration scopes to request one"
        exit 1
      fi
      log warn "force_reregister enabled; re-registering runner"
      if [[ -n "${github_pat}" ]]; then
        remove_runner_remote_if_exists "${repo_url}" "${github_pat}" "${runner_name_effective}"
        remote_runner_removed="true"
      fi
      clear_local_runner_config
      has_runner_config="false"
      has_partial_config="false"
    else
      log info "Existing runner configuration found, will attempt to reconnect"
      log info "Set force_reregister=true to re-register with a new token"
    fi
  fi

  if [[ "${has_runner_config}" != "true" ]]; then
    if [[ "${has_partial_config}" == "true" ]]; then
      log warn "Found partial runner configuration; cleaning up before registration"
      clear_local_runner_config
      has_partial_config="false"
    fi

    if [[ -z "${registration_token}" ]]; then
      log error "No runner configuration exists and no registration token is available"
      log error "Provide a registration token, or a PAT with repo/administration scopes to request one"
      exit 1
    fi
    
    log info "Registering new runner '${runner_name_effective}' (ephemeral=${ephemeral}) for ${repo_url}"
    
    # Clean up any stale config files (always clear before registering)
    if [[ "${has_partial_config}" == "true" ]]; then
      log warn "Removing stale runner configuration files"
    fi

    if [[ -n "${removal_token}" ]]; then
      log info "Ensuring prior runner registration is removed (best-effort)"
      if ! as_runner ./config.sh remove --token "${removal_token}" >/dev/null 2>&1; then
        log warn "config.sh remove failed; continuing with fresh registration"
      fi
    fi

    clear_local_runner_config
    
    # Remove any existing runner with same name via API
    if [[ "${remote_runner_removed}" != "true" && -n "${github_pat}" ]]; then
      remove_runner_remote_if_exists "${repo_url}" "${github_pat}" "${runner_name_effective}"
      remote_runner_removed="true"
    fi
    
    if [[ "${ephemeral}" == "true" ]]; then
      as_runner ./config.sh \
        --url "${repo_url}" \
        --token "${registration_token}" \
        --name "${runner_name_effective}" \
        --labels "${runner_labels_csv}" \
        --work "${workdir}" \
        --unattended \
        --replace \
        --ephemeral
    else
      as_runner ./config.sh \
        --url "${repo_url}" \
        --token "${registration_token}" \
        --name "${runner_name_effective}" \
        --labels "${runner_labels_csv}" \
        --work "${workdir}" \
        --unattended \
        --replace
    fi
  fi

  unset github_token
  unset registration_token
  unset github_pat
  unset removal_token

  start_runner_as_runner
}

main "$@"
