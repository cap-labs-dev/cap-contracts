#!/usr/bin/env bash
# Run Foundry tests with campaign budgets and save reproduction artifacts and metrics.
set -euo pipefail

# Parse the complete runner before executing it, even if the file is edited mid-run.
main() {

  profile="${1:-local}"
  if [ "$#" -gt 0 ]; then shift; fi
  case "$profile" in local|pr|deep) ;; *) echo "Usage: $0 {local|pr|deep} [forge test arguments]" >&2; exit 2;; esac
  if [[ "$(forge --version)" != $'forge Version: 1.5.1-stable\n'* ]]; then
    echo 'This campaign is pinned to Foundry v1.5.1. Install with: foundryup --install v1.5.1' >&2
    exit 2
  fi

  artifact_dir="artifacts/fuzz-and-invariant-tests/$profile"
  mkdir -p "$artifact_dir"
  seed="${FOUNDRY_FUZZ_SEED:-0x$(openssl rand -hex 32)}"
  export FOUNDRY_PROFILE="$profile" FOUNDRY_FUZZ_SEED="$seed"
  {
    git rev-parse HEAD
    forge --version
    uname -sm
    echo "profile=$profile"
    echo "FOUNDRY_FUZZ_SEED=$seed"
    echo "started_utc=$(date -u +%FT%TZ)"
    printf 'extra_arg=%s\n' "$@"
  } > "$artifact_dir/run.txt"
  shasum -a 256 foundry.toml test/invariant/*.sol test/invariant/handlers/*.sol \
    script/run-fuzz-tests.sh script/summarize-invariant-metrics.js .github/workflows/fuzz-and-invariant-tests.yml \
    > "$artifact_dir/sources.sha256"

  # pipefail propagates failing regressions. Foundry persists minimized failures in
  # cache/invariant and cache/fuzz; never delete them as part of a test run.
  set +e
  /usr/bin/time -p forge test -vvv "$@" 2>&1 | tee "$artifact_dir/forge.log"
  test_result=${PIPESTATUS[0]}
  set -e
  echo "exit_code=$test_result" >> "$artifact_dir/run.txt"
  node script/summarize-invariant-metrics.js --profile "$profile" --seed "$seed" > "$artifact_dir/metrics.json"
  exit "$test_result"
}

main "$@"
