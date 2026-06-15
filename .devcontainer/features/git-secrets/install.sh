#!/usr/bin/env bash
# Dev Containers feature: https://containers.dev/implementors/features/
set -euo pipefail

VERSION="${VERSION:-1.3.0}"
REPO="https://github.com/awslabs/git-secrets.git"
BUILD_DIR="/tmp/git-secrets-${VERSION}"

apt-get update
apt-get install -y --no-install-recommends make ca-certificates git
rm -rf /var/lib/apt/lists/*

rm -rf "${BUILD_DIR}"
git clone --depth 1 --branch "${VERSION}" "${REPO}" "${BUILD_DIR}"
make -C "${BUILD_DIR}" install PREFIX=/usr/local
rm -rf "${BUILD_DIR}"

if ! command -v git-secrets >/dev/null 2>&1; then
  echo "git-secrets feature: install failed — git-secrets not on PATH" >&2
  exit 1
fi

echo "git-secrets $(git-secrets --version 2>/dev/null || true) installed"
