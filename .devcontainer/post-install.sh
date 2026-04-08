#!/usr/bin/env bash
set -euo pipefail

# Foundry
curl -L https://foundry.paradigm.xyz | bash
export PATH="$HOME/.foundry/bin:$PATH"
foundryup

# Git submodules
git submodule update --init --recursive

# Node dependencies
yarn install
