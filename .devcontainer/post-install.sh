#!/usr/bin/env bash
set -euo pipefail

# Foundry
curl -L https://foundry.paradigm.xyz | bash
export PATH="$HOME/.foundry/bin:$PATH"
foundryup

# Git submodules — only if inside a git repo (.git may be masked in sandboxed containers)
if git rev-parse --git-dir > /dev/null 2>&1; then
  git submodule update --init --recursive
fi

# Node dependencies
yarn install
