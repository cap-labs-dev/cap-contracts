#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${ROOT}/.claude"
# Built by `build`, consumed by `run`. Override: CLAUDE_DOCKER_IMAGE=… $0 …
CLAUDE_DOCKER_IMAGE="${CLAUDE_DOCKER_IMAGE:-claude-docker}"
cd "$ROOT"

MASK_DIR="${CLAUDE_DIR}/maskdir"
MASK_FILE="${MASK_DIR}/maskfile"
mask_mounts=()

# From .claudeignore: lines ending with / → maskdir bind mounts; other lines → maskdir/maskfile bind mounts.
_prune_names=()
_prune_paths=()
_mask_names=()
_mask_paths=()
find_prune_ary=()

parse_claudeignore() {
  _prune_names=()
  _prune_paths=()
  _mask_names=()
  _mask_paths=()
  _cig_f="${CLAUDE_DIR}/.claudeignore"
  if [ ! -f "$_cig_f" ]; then
    echo "error: missing $_cig_f (maskdir entries, maskfile patterns, comments)" >&2
    exit 1
  fi
  while IFS= read -r _cig_line || [ -n "$_cig_line" ]; do
    _cig_line="${_cig_line%$'\r'}"
    _cig_line="${_cig_line#"${_cig_line%%[![:space:]]*}"}"
    _cig_line="${_cig_line%"${_cig_line##*[![:space:]]}"}"
    [ -z "$_cig_line" ] && continue
    [[ "$_cig_line" == \#* ]] && continue
    if [[ "$_cig_line" == */ ]]; then
      _cig_pat="${_cig_line%/}"
      _cig_pat="${_cig_pat#"${_cig_pat%%[![:space:]]*}"}"
      _cig_pat="${_cig_pat%"${_cig_pat##*[![:space:]]}"}"
      _cig_pat="${_cig_pat#/}"
      [ -z "$_cig_pat" ] && continue
      if [[ "$_cig_pat" == */* ]]; then
        _prune_paths+=("$_cig_pat")
      else
        _prune_names+=("$_cig_pat")
      fi
      continue
    fi
    _cig_pat="$_cig_line"
    _cig_pat="${_cig_pat#"${_cig_pat%%[![:space:]]*}"}"
    _cig_pat="${_cig_pat%"${_cig_pat##*[![:space:]]}"}"
    _cig_pat="${_cig_pat#/}"
    [ -z "$_cig_pat" ] && continue
    if [[ "$_cig_pat" == */* ]]; then
      _mask_paths+=("$_cig_pat")
    else
      _mask_names+=("$_cig_pat")
    fi
  done <"$_cig_f"

  if [ "${#_prune_names[@]}" -eq 0 ] && [ "${#_prune_paths[@]}" -eq 0 ]; then
    echo "error: $_cig_f must define at least one maskdir entry (line ending with /)" >&2
    exit 1
  fi
}

build_find_prune_ary() {
  find_prune_ary=()
  # bash 3.2 + set -u: do not iterate "${arr[@]}" when arr is empty (unbound).
  if [ "${#_prune_paths[@]}" -gt 0 ]; then
    for __rel in "${_prune_paths[@]}"; do
      if [ ${#find_prune_ary[@]} -gt 0 ]; then
        find_prune_ary+=( -o )
      fi
      find_prune_ary+=( -path "${ROOT}/${__rel}" -o -path "${ROOT}/${__rel}/*" )
    done
  fi
  if [ "${#_prune_names[@]}" -gt 0 ]; then
    for __nm in "${_prune_names[@]}"; do
      if [ ${#find_prune_ary[@]} -gt 0 ]; then
        find_prune_ary+=( -o )
      fi
      find_prune_ary+=( -name "$__nm" )
    done
  fi
}

append_masked_paths_from_stdin() {
  local _mf _rel
  while IFS= read -r -d '' _mf; do
    _rel="${_mf#"$ROOT"/}"
    mask_mounts+=(-v "${MASK_FILE}:/workspace/${_rel}:ro")
  done
}

# Directory entries (lines ending with /): find skips them when listing maskfile targets;
# in the container, maskdir is bind-mounted at each matching path (same tree as host maskdir).
append_maskdir_mounts() {
  local _pd _rel
  while IFS= read -r -d '' _pd; do
    _rel="${_pd#"$ROOT"/}"
    _rel="${_rel#/}"
    [ -z "$_rel" ] && continue
    mask_mounts+=(-v "${MASK_DIR}:/workspace/${_rel}:ro")
  done < <(
    find "$ROOT" \( "${find_prune_ary[@]}" \) -exec sh -c 'test -d "$1" && printf "%s\0" "$1"' _ {} \; -prune
  )
}

build_mask_mounts() {
  echo "claude-docker: resolving .claudeignore …" >&2
  SECONDS=0
  parse_claudeignore
  build_find_prune_ary
  echo "claude-docker:   parsed .claudeignore + built find prune expression (${SECONDS}s)" >&2

  if [ ! -f "$MASK_FILE" ]; then
    echo "error: missing $MASK_FILE (keep maskdir/maskfile in the repo; empty file is ok)" >&2
    exit 1
  fi
  mask_mounts=()

  SECONDS=0
  append_maskdir_mounts
  echo "claude-docker:   find(1) for maskdir bind-mount targets (${SECONDS}s)" >&2

  if [ "${#_mask_names[@]}" -gt 0 ] || [ "${#_mask_paths[@]}" -gt 0 ]; then
    _mask_clause=(-false)
    if [ "${#_mask_names[@]}" -gt 0 ]; then
      for __n in "${_mask_names[@]}"; do
        _mask_clause+=( -o -name "$__n" )
      done
    fi
    if [ "${#_mask_paths[@]}" -gt 0 ]; then
      for __p in "${_mask_paths[@]}"; do
        _mask_clause+=( -o -path "${ROOT}/${__p}" )
      done
    fi
    SECONDS=0
    append_masked_paths_from_stdin < <(
      find "$ROOT" \( "${find_prune_ary[@]}" \) -prune -o \( -type f \( "${_mask_clause[@]}" \) -print0 \)
    )
    echo "claude-docker:   find(1) for maskfile bind-mount targets (${SECONDS}s)" >&2
  else
    echo "claude-docker:   find(1) for maskfile bind-mount targets (skipped, no patterns)" >&2
  fi
  echo "claude-docker: resolving .claudeignore done" >&2
}

# Printed docker command only: mask paths → $MASKFILE / $MASKDIR; other paths under $ROOT → $PATH + suffix.
_echo_cmd_host_path() {
  local p="$1"
  if [ "$p" = "$MASK_FILE" ]; then
    printf '%s' '$MASKFILE'
  elif [ "$p" = "$MASK_DIR" ]; then
    printf '%s' '$MASKDIR'
  elif [[ "$p" == "$MASK_DIR"/* ]]; then
    printf '%s%s' '$MASKDIR' "${p#"$MASK_DIR"}"
  elif [ "$p" = "$ROOT" ]; then
    printf '%s' '$PATH'
  elif [[ "$p" == "$ROOT"/* ]]; then
    printf '%s%s' '$PATH' "${p#"$ROOT"}"
  else
    printf '%q' "$p"
  fi
}

print_docker_run_cmd() {
  printf '%s \\\n' 'docker run -it --rm'
  printf '  -v %s:/workspace \\\n' "$(_echo_cmd_host_path "$ROOT")"
  printf '  -v %s:/home/claude \\\n' "$(_echo_cmd_host_path "${CLAUDE_DIR}/docker-home")"
  _par_i=0
  while [ "$_par_i" -lt "${#mask_mounts[@]}" ]; do
    _vol_spec="${mask_mounts[$((_par_i + 1))]}"
    _vol_host="${_vol_spec%%:*}"
    _vol_rest="${_vol_spec#"${_vol_host}:"}"
    printf '  -v %s:%s \\\n' "$(_echo_cmd_host_path "$_vol_host")" "$_vol_rest"
    _par_i=$((_par_i + 2))
  done
  printf '  --env-file %s \\\n' "$(_echo_cmd_host_path "${ROOT}/.env.claude")"
  printf '  %s' "$CLAUDE_DOCKER_IMAGE"
  for _par_a in "$@"; do
    printf ' %q' "$_par_a"
  done
  printf '\n'
}

case "${1-}" in
  run)
    shift
    build_mask_mounts
    mkdir -p "${CLAUDE_DIR}/docker-home"
    echo "# docker run (executing next); placeholders: \$PATH=repo root, \$MASKDIR=\$PATH/.claude/maskdir, \$MASKFILE=\$MASKDIR/maskfile:" >&2
    print_docker_run_cmd "$@" >&2
    echo >&2
    docker run -it --rm \
      -v "${ROOT}:/workspace" \
      -v "${CLAUDE_DIR}/docker-home:/home/claude" \
      "${mask_mounts[@]}" \
      --env-file "${ROOT}/.env.claude" \
      "$CLAUDE_DOCKER_IMAGE" "$@"
    ;;
  build)
    shift
    mkdir -p "${CLAUDE_DIR}/docker-home"
    exec docker build -f "${CLAUDE_DIR}/Dockerfile" -t "$CLAUDE_DOCKER_IMAGE" \
      --build-arg "UID=$(id -u)" \
      --build-arg "GID=$(id -g)" \
      "${CLAUDE_DIR}" "$@"
    ;;
  *)
    echo "usage: $0 run|build [args...]" >&2
    echo "  run   — print docker command to stderr, then run Claude in Docker (args forwarded to claude)" >&2
    echo "  build — docker build image $CLAUDE_DOCKER_IMAGE" >&2
    exit 1
    ;;
esac
