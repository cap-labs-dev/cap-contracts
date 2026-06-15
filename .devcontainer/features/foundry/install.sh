#!/usr/bin/env bash
# Dev Containers feature: https://containers.dev/implementors/features/
set -euo pipefail

USERNAME="${_REMOTE_USER:-node}"
# devcontainer option `foundryVersion` -> env var FOUNDRYVERSION
FOUNDRYVERSION="${FOUNDRYVERSION:-stable}"

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates git jq
rm -rf /var/lib/apt/lists/*

# Install foundryup and toolchain as the remote user (binaries land in ~/.foundry/bin).
# install v0.0.4: https://github.com/foundry-rs/foundryup/releases/tag/v0.0.4
su - "${USERNAME}" -c 'curl -fsSL https://raw.githubusercontent.com/foundry-rs/foundryup/bbba3472f2274763e5dc31c1320789c9db5b896b/foundryup-init.sh | bash'
su - "${USERNAME}" -c "export PATH=\"\$HOME/.foundry/bin:\$PATH\" && foundryup --install \"${FOUNDRYVERSION}\""

for rc in "/home/${USERNAME}/.bashrc" "/home/${USERNAME}/.zshrc"; do
  if ! grep -q '.foundry/bin' "${rc}" 2>/dev/null; then
    echo 'export PATH="$HOME/.foundry/bin:$PATH"' >>"${rc}"
  fi
done

# postCreateCommand runs via /bin/sh -c and does not source shell rc files.
for bin in forge cast anvil chisel; do
  ln -sf "/home/${USERNAME}/.foundry/bin/${bin}" "/usr/local/bin/${bin}"
done

for bin in forge cast anvil chisel; do
  if ! su - "${USERNAME}" -c "export PATH=\"\$HOME/.foundry/bin:\$PATH\" && command -v ${bin}" >/dev/null 2>&1; then
    echo "foundry feature: install failed — ${bin} not on PATH" >&2
    exit 1
  fi
done

echo "foundry $(su - "${USERNAME}" -c 'export PATH="$HOME/.foundry/bin:$PATH" && forge --version' | head -1) installed"
