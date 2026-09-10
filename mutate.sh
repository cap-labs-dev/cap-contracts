#!/usr/bin/env bash
# Revert each part of the M1/M2/M3 fixes and confirm a test notices.
set -u

B=contracts/cap/market/BaseMarket.sol
FL=contracts/cap/market/FloatingMarket.sol
T=contracts/cap/Tranche.sol
I=contracts/cap/InterestRateModel.sol
W=contracts/utils/WadRayMath.sol

FILES="$B $FL $T $I $W"
for f in $FILES; do cp "$f" "$f.bak"; done
restore() { for f in $FILES; do cp "$f.bak" "$f"; done; }
trap 'restore; for f in $FILES; do rm -f "$f.bak"; done' EXIT

check() {
  local name="$1" out
  out=$(forge test 2>&1)
  if echo "$out" | grep -qE "^(Error|\[FAIL)|failed to compile|Compiler run failed"; then
    echo "  KILLED   $name"
  else
    echo "  SURVIVED $name   <-- no test covers this"
  fi
  restore
}

echo "── M3: the market guard ──"
perl -0pi -e 's/, ReentrancyGuardTransient \{/ {/' $B
perl -pi -e 's/ nonReentrant//g; s/^\s*nonReentrant\n$//' $B $FL
check "guard dropped from every market entry point"

perl -pi -e 's/function repay\(uint256 amount\) external nonReentrant/function repay(uint256 amount) external/' $FL
check "guard dropped from repay alone, liquidate still guarded"

perl -pi -e 's/(function liquidate\(address recipient, uint256 amount\)\s*\n\s*external\s*\n\s*restricted\s*\n)\s*nonReentrant\s*\n/$1/' $FL
perl -0pi -e 's/(function liquidate\(address recipient, uint256 amount\)\s+external\s+restricted\s+)nonReentrant\s+/$1/s' $FL
check "guard dropped from liquidate alone"

echo "── M3: the tranche kill latch ──"
perl -0pi -e 's/(if \(!killed && totalSupply\(\) > )\(total - assets\)( \* KILL_RATIO\) \{\n.*?\n.*?\n\s*\}\n\n\s*)(IVault\(vault\)\.withdraw\(asset\(\), assets, recipient\);\n\s*emit Slashed\(recipient, assets, slashedValue\);)/$3\n\n        $1totalAssets()$2/s' $T
check "latch written after the withdrawal again"

echo "── M1: the averaging weight ──"
perl -pi -e 's/weight = 1e27 - retentionPerSecond\.rayPow\(elapsed\);/uint256 p = averagingPeriod; weight = elapsed >= p ? 1e27 : elapsed * 1e27 \/ p;/' $I
check "back to the per-call linear weight"

perl -pi -e 's/retentionPerSecond = 1e27 - 1e27 \/ _averagingPeriod;/retentionPerSecond = 1e27;/' $I
check "retention of one, so the average never moves"

perl -pi -e 's/if \(n > 0\) a = rayMul\(a, a\);/a = rayMul(a, a);/' $W
check "rayPow squares on the final iteration too"

perl -pi -e 's/if \(n & 1 == 1\) c = rayMul\(c, a\);/c = rayMul(c, a);/' $W
check "rayPow multiplies regardless of the bit"

echo "── M2: the tranche-set gate ──"
perl -pi -e 's/if \(healthAfter < 1e27 && healthAfter < healthBefore\) revert Unhealthy\(\);/if (healthAfter < 1e27) revert Unhealthy();/' $B
check "back to requiring an outright healthy result"

perl -pi -e 's/if \(healthAfter < 1e27 && healthAfter < healthBefore\) revert Unhealthy\(\);//' $B
check "gate dropped entirely, so capital can be pulled out"

perl -pi -e 's/if \(healthAfter < 1e27 && healthAfter < healthBefore\) revert Unhealthy\(\);/if (healthAfter < healthBefore) revert Unhealthy();/' $B
check "comparison only, dropping the absolute healthy case"
