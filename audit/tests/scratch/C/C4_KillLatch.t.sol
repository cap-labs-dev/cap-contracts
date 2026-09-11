// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// WS-C / H14: the kill latch fires whenever a slash leaves totalSupply > 100 * totalAssets.
/// A junior tranche whose real holders have all exited still carries the 1e3 dead shares over a
/// few wei of dust, is first in the waterfall, and is swept to zero by ANY liquidation - which
/// latches it killed for good. Separately, a wiped tranche keeps its premium weight because
/// _chargePremium tests stakedSupply (shares) rather than capital.
contract C4_KillLatch is CapDeployer {
    FloatingMarket market;
    Tranche senior;
    Tranche junior;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _deployCap();
        MarketBundle memory b = _createReadyMarket("M");
        market = b.market;
        senior = b.tranche0;
        junior = b.tranche1;
    }

    function test_H14_exitedJuniorTrancheIsKilledByAnyLiquidation() public {
        // bob underwrites the junior tranche for a while, then leaves entirely
        _fundTranche(address(junior), bob, 10e18);
        uint256 bobShares = junior.balanceOf(bob);
        vm.prank(bob);
        junior.redeem(bobShares, bob, bob);
        emit log_named_uint("junior supply after exit (dead shares)", junior.totalSupply());
        emit log_named_uint("junior assets after exit (wei)", junior.totalAssets());

        _fundTranche(address(senior), alice, 1000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        oracle.setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 10e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 10e18);

        emit log_named_string("junior killed", junior.killed() ? "true" : "false");
        // nobody can ever underwrite through this tranche again
        _fundVault(bob, 1e18);
        vm.prank(bob);
        vault.setOperator(address(junior), true);
        vm.prank(bob);
        (bool ok,) = address(junior).call(abi.encodeCall(IERC4626.deposit, (1e18, bob)));
        emit log_named_string("re-deposit into junior", ok ? "ok" : "REVERT (ExceededMaxDeposit)");
        assertFalse(junior.killed(), "a tranche nobody is underwriting should not be retired by a routine liquidation");
    }

    function test_wipedTrancheKeepsEarningItsWeight() public {
        _fundTranche(address(senior), alice, 1000e18);
        _fundTranche(address(junior), bob, 10e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        oracle.setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 20e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 20e18); // 20.4 USD of slash, junior holds 4 USD: wiped
        assertEq(junior.totalAssets(), 0, "junior wiped");
        assertGt(junior.stakedSupply(), 0, "but still has staked shares");

        uint256 before = stablecoin.balanceOf(address(junior));
        vm.warp(block.timestamp + 30 days);
        market.chargePremium();
        uint256 got = stablecoin.balanceOf(address(junior)) - before;
        emit log_named_uint("premium minted to wiped junior over 30 days (cUSD)", got);
        emit log_named_uint("premium minted to senior over 30 days (cUSD)", stablecoin.balanceOf(address(senior)));
        assertEq(got, 0, "a tranche with zero capital bears no risk and should earn no premium");
    }
}
