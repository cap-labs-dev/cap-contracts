#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${ROOT}/.claude"
cd "$ROOT"

MASK_FILE="${CLAUDE_DIR}/maskfile"
mask_mounts=()

# From .claudeignore: prune_* = dirs find skips; mask_* = file patterns to overlay
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
    echo "error: missing $_cig_f (all prune and mask rules live there)" >&2
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
    echo "error: $_cig_f must define at least one prune directory (line ending with /)" >&2
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

build_mask_mounts() {
  parse_claudeignore
  build_find_prune_ary
  if [ ! -f "$MASK_FILE" ]; then
    echo "error: missing $MASK_FILE (read-only source for masked paths)" >&2
    exit 1
  fi
  mask_mounts=()

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
    append_masked_paths_from_stdin < <(
      find "$ROOT" \( "${find_prune_ary[@]}" \) -prune -o \( -type f \( "${_mask_clause[@]}" \) -print0 \)
    )
  fi
}

# Audit output only: replace repo root prefix with this placeholder (readable trace).
_audit_root_placeholder() {
  local p="$1"
  if [ "$p" = "$ROOT" ]; then
    printf '%s' '${PATH}'
  elif [[ "$p" == "$ROOT"/* ]]; then
    printf '%s%s' '${PATH}' "${p#"$ROOT"}"
  else
    printf '%q' "$p"
  fi
}

print_audit_run_cmd() {
  printf '%s \\\n' 'docker run -it --rm'
  printf '  -v %s:/workspace \\\n' "$(_audit_root_placeholder "$ROOT")"
  printf '  -v %s:/home/claude \\\n' "$(_audit_root_placeholder "${CLAUDE_DIR}/docker-home")"
  _par_i=0
  while [ "$_par_i" -lt "${#mask_mounts[@]}" ]; do
    _audit_flag="${mask_mounts[$_par_i]}"
    _audit_spec="${mask_mounts[$((_par_i + 1))]}"
    _audit_src="${_audit_spec%%:*}"
    _audit_suffix="${_audit_spec#"${_audit_src}:"}"
    _audit_vol="$(_audit_root_placeholder "$_audit_src"):${_audit_suffix}"
    printf '  %q %s \\\n' "$_audit_flag" "$_audit_vol"
    _par_i=$((_par_i + 2))
  done
  printf '  --env-file %s \\\n' "$(_audit_root_placeholder "${ROOT}/.env.claude")"
  printf '  cap-ui-claude'
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
    docker run -it --rm \
      -v "${ROOT}:/workspace" \
      -v "${CLAUDE_DIR}/docker-home:/home/claude" \
      "${mask_mounts[@]}" \
      --env-file "${ROOT}/.env.claude" \
      cap-ui-claude "$@"
    ;;
  audit)
    shift
    mkdir -p "${CLAUDE_DIR}/docker-home"
    build_mask_mounts
    echo "# docker run (same as: $0 run …)" >&2
    echo "# \${PATH} below = repo root: $(printf '%q' "$ROOT")" >&2
    echo "# prune dirs (lines ending with / in .claudeignore):" >&2
    echo "#   -name:$([ "${#_prune_names[@]}" -gt 0 ] && printf ' %s' "${_prune_names[@]}")" >&2
    echo "#   -path:$([ "${#_prune_paths[@]}" -gt 0 ] && printf ' %s' "${_prune_paths[@]}")" >&2
    echo "# mask basename:$([ "${#_mask_names[@]}" -gt 0 ] && printf ' %s' "${_mask_names[@]}")" >&2
    echo "# mask path:$([ "${#_mask_paths[@]}" -gt 0 ] && printf ' %s' "${_mask_paths[@]}")" >&2
    echo "# maskfile bind mounts: $((${#mask_mounts[@]} / 2)) ($(_audit_root_placeholder "$MASK_FILE"))" >&2
    echo >&2
    print_audit_run_cmd "$@"
    ;;
  test-file)
    shift
    rel="${1:?usage: $0 test-file <path-under-repo>, e.g. apps/ui/.env}"
    shift
    case "${rel}" in
      *..*)
        echo "error: path must not contain .." >&2
        exit 2
        ;;
    esac
    build_mask_mounts
    mkdir -p "${CLAUDE_DIR}/docker-home"
    docker run --rm \
      -v "${ROOT}:/workspace" \
      -v "${CLAUDE_DIR}/docker-home:/home/claude" \
      "${mask_mounts[@]}" \
      --env-file "${ROOT}/.env.claude" \
      --entrypoint sh \
      cap-ui-claude \
      -c 'f="/workspace/$1"; if ! cat "$f" >/dev/null 2>&1; then echo "ok: cat failed (missing or not readable)"; exit 0; fi; if [ ! -s "$f" ]; then echo "ok: file is empty (masked or empty on disk)"; exit 0; fi; echo "fail: cat succeeded and file is non-empty" >&2; exit 1' \
      sh "${rel}"
    ;;
  build)
    shift
    mkdir -p "${CLAUDE_DIR}/docker-home"
    exec docker build -f "${CLAUDE_DIR}/Dockerfile" -t cap-ui-claude \
      --build-arg "UID=$(id -u)" \
      --build-arg "GID=$(id -g)" \
      "${CLAUDE_DIR}" "$@"
    ;;
  *)
    echo "usage: $0 run|audit|build|test-file [args...]" >&2
    echo "  audit             — print the docker run command (quoted) for auditing" >&2
    echo "  test-file <path>  — verify path is not readable as non-empty inside the same mounts as run" >&2
    exit 1
    ;;
esac
