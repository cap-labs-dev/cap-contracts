#!/usr/bin/env bash
# Dev Containers feature: https://containers.dev/implementors/features/
set -euo pipefail

USERNAME="${_REMOTE_USER:-node}"
ALIASES="${ALIASES:-p=pnpm}"
alias_defs=()

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

if [ -z "${ALIASES// /}" ]; then
  echo "shell-aliases feature: no aliases configured, skipping"
  exit 0
fi

IFS=',' read -r -a raw_aliases <<< "${ALIASES}"
for alias_def in "${raw_aliases[@]}"; do
  alias_def="$(trim "${alias_def}")"
  [ -z "${alias_def}" ] && continue
  alias_defs+=("${alias_def}")
done

if [ "${#alias_defs[@]}" -eq 0 ]; then
  echo "shell-aliases feature: no aliases configured, skipping"
  exit 0
fi

for rc in "/home/${USERNAME}/.bashrc" "/home/${USERNAME}/.zshrc"; do
  for alias_def in "${alias_defs[@]}"; do
    alias_line="alias ${alias_def}"
    if ! grep -qxF "${alias_line}" "${rc}" 2>/dev/null; then
      echo "${alias_line}" >>"${rc}"
    fi
  done
done

echo "shell-aliases feature: configured ${#alias_defs[@]} alias(es)"
