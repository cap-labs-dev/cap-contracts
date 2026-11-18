#!/usr/bin/env bash
# Verify on Etherscan the Sepolia contracts that `forge script --verify` cannot submit itself:
# everything created inside another call (CreateX proxies, beacons, mock tokens and feeds, and the
# markets, tranches and pools the Registry deploys through the factory).
#
# Usage, from the repo root with SEPOLIA_RPC_URL and ETHERSCAN_API_KEY exported:
#   bash script/sepolia/verify-sepolia.sh
#
# VerifyArgs.s.sol rebuilds each contract's constructor arguments from config/cap-v2.json and
# config/sepolia-scenarios.json and checks them against the on-chain code; this loop submits them.
# Etherscan answers "Already Verified" for a contract whose bytecode matches one verified earlier
# (its "Similar Match"); that is fine and the loop carries on.
set -euo pipefail
: "${ETHERSCAN_API_KEY:?export ETHERSCAN_API_KEY}"
: "${SEPOLIA_RPC_URL:?export SEPOLIA_RPC_URL}"

LINES=$(forge script script/sepolia/VerifyArgs.s.sol:VerifyArgs --rpc-url sepolia 2>&1 | tee /dev/stderr | grep '^  VERIFY ' || true)
[ -n "$LINES" ] || { echo "no VERIFY lines produced"; exit 1; }

ok=0; skipped=0; failed=0
while read -r _ address contract args; do
  echo "== $contract @ $address"
  if [ "$args" = "0x" ]; then
    out=$(forge verify-contract --chain sepolia --watch "$address" "$contract" 2>&1) && rc=0 || rc=$?
  else
    out=$(forge verify-contract --chain sepolia --watch --constructor-args "$args" "$address" "$contract" 2>&1) && rc=0 || rc=$?
  fi
  if [ $rc -eq 0 ]; then
    ok=$((ok+1)); echo "   verified"
  elif echo "$out" | grep -qi "already verified"; then
    skipped=$((skipped+1)); echo "   already verified"
  else
    failed=$((failed+1)); echo "   FAILED"; echo "$out" | tail -5
  fi
done <<< "$LINES"

echo; echo "verified $ok, already verified $skipped, failed $failed"
[ $failed -eq 0 ]
