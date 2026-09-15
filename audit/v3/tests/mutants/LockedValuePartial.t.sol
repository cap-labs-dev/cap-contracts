// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice Killing tests for the untested branches of {BaseMarket-lockedValue} and
/// {Tranche-unlockedSupply}.
///
/// Gambit `BaseMarket#161` (== hand mutant H02) deletes `value -= capital` in the waterfall walk,
/// so a senior is locked for the whole requirement whenever the junior covers only part of it.
/// The stock suite only ever tests the two ends (junior covers all, junior covers nothing).
/// H01 flips the USD-requirement rounding to floor; H11 flips the token conversion to floor.
contract LockedValuePartialKillTest is CapDeployer {
    address internal seniorLp = makeAddr("seniorLp");
    address internal juniorLp = makeAddr("juniorLp");

    /// Kills BaseMarket#161 / H02. Requirement is debt / (lt − buffer) = 350 / 0.7 = 500. The
    /// junior holds 300, so the senior must lock exactly the 200 remainder.
    function test_seniorLocksOnlyTheRemainderAfterAPartialJuniorCover() public {
        _deployCap();
        MarketBundle memory b = _createReadyMarket("partial");
        _fundTranche(b.tranche0Addr, seniorLp, 1_000e18);
        _fundTranche(b.tranche1Addr, juniorLp, 300e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 350e18);

        assertEq(b.market.lockedValue(b.tranche1Addr), 500e18, "junior sees the whole requirement");
        assertEq(b.market.lockedValue(b.tranche0Addr), 200e18, "senior sees the requirement less the junior's capital");
        assertEq(b.tranche1.unlockedSupply(), 0, "junior fully locked");
        assertEq(b.tranche0.unlockedSupply(), 1_000e18 - 200e18, "senior may release everything above the remainder");
        assertEq(b.tranche0.maxInstantRedeem(seniorLp), 800e18, "and its holder can take it");
    }

    /// Kills H01. A requirement that does not divide exactly must round up: 350e18 + 1 wei of debt
    /// over 0.7 is 500e18 + 1.43 wei, so the lock is 500e18 + 2.
    function test_requirementRoundsUpToTheNextWei() public {
        _deployCap();
        MarketBundle memory b = _createReadyMarket("ceil");
        _fundTranche(b.tranche0Addr, seniorLp, 1_000e18);

        vm.prank(defaultBorrower);
        uint256 minted = b.market.borrow(defaultBorrower, 350e18 + 1);
        assertEq(minted, 350e18 + 1, "fresh index, so the draw is exact");

        assertEq(b.market.lockedValue(b.tranche0Addr), 500e18 + 2, "ceil of 500e18 + 1.43");
    }

    /// Kills H11. With the collateral at $3 a $100 lock is 33.33.. tokens and must round up to
    /// 33333333333333333334, so one third of a wei of collateral cannot walk out.
    function test_lockedAssetsRoundUpWhenThePriceDoesNotDivide() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.collateralPrice = 3e18;
        _deployCapWithConfig(cfg);
        MarketBundle memory b = _createReadyMarket("three");
        _fundTranche(b.tranche0Addr, seniorLp, 1_000e18); // $3000
        _fundTranche(b.tranche1Addr, juniorLp, 300e18); // $900

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 700e18); // requirement 1000: junior 900, senior 100

        assertEq(b.market.lockedValue(b.tranche0Addr), 100e18, "senior locks $100");
        uint256 lockedTokens = 33_333_333_333_333_333_334; // ceil(100e18 * 1e18 / 3e18)
        assertEq(b.tranche0.unlockedSupply(), 1_000e18 - lockedTokens, "one third of a wei rounds against the exit");
    }
}
