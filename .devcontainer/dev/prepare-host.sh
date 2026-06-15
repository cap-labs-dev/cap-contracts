#!/usr/bin/env bash
# Host-side preparation before the dev container is created (bind mounts, etc.)
set -euo pipefail

source .devcontainer/features/host/prepare-host.sh

ensure_host_dir "${WORKSPACE_DIR}/.devcontainer/dev/node_modules"
ensure_host_dir "${WORKSPACE_DIR}/.devcontainer/dev/yarn-store"

ensure_host_file "${HOME_DIR}/.foundry/foundry.toml" <<'EOF'
# Global Foundry configuration (auto-created for devcontainer bind mount)
# https://book.getfoundry.sh/reference/config/
EOF
