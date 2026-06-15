# Host-side preparation before the dev container is created (bind mounts, etc.)
set -euo pipefail

log() {
  echo "prepare-host: $*" >&2
}

HOME_DIR="${HOME:-${USERPROFILE:-}}"
if [[ -z "${HOME_DIR}" ]]; then
  log "could not determine home directory"
  exit 1
fi

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

ensure_host_dir() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    return 0
  fi
  mkdir -p "${path}"
  log "created ${path}"
}

# Ensure a host file exists before Docker bind-mounts it. Docker creates a
# directory instead of a file when the source path is missing.
ensure_host_file() {
  local path="$1"

  if [[ -d "${path}" ]]; then
    log "${path} is a directory; remove it and rebuild"
    exit 1
  fi

  if [[ -f "${path}" ]]; then
    return 0
  fi

  ensure_host_dir "$(dirname "${path}")"
  cat >"${path}"
  log "created ${path}"
}
