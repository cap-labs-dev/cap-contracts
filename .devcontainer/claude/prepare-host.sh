#!/usr/bin/env bash
# Host-side preparation before the dev container is created (bind mounts, etc.)
set -euo pipefail

source .devcontainer/features/host/prepare-host.sh

ensure_host_dir "${WORKSPACE_DIR}/.devcontainer/claude/node_modules"
ensure_host_dir "${WORKSPACE_DIR}/.devcontainer/claude/yarn-store"
