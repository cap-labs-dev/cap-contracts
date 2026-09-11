// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// R2 port of audit/tests/scratch/C/C4_KillLatch.t.sol (L-12). New latch:
/// `totalSupply > (total - assets) * 100` evaluated BEFORE the withdrawal.
contract L12_KillLatch is CapDeployer {
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

    function test_L12_exitedJuniorTrancheIsKilledByAnyLiquidation() public {
        _fundTranche(address(junior), bob, 10e18);
        uint256 bobShares = junior.balanceOf(bob);
        vm.prank(bob);
        junior.redeem(bobShares, bob, bob);
        uint256 supply = junior.totalSupply();
        uint256 total = junior.totalAssets();
        emit log_named_uint("junior supply after exit (dead shares)", supply);
        emit log_named_uint("junior assets after exit (wei)", total);

        _fundTranche(address(senior), alice, 1000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        _setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 10e18);
        // slash requested on junior = 10.2 USD >> dust, so assets := total and (total-assets) = 0
        emit log_named_uint("latch lhs totalSupply", supply);
        emit log_named_uint("latch rhs (total-assets)*100", 0);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 10e18);

        emit log_named_string("junior killed", junior.killed() ? "true" : "false");
        emit log_named_uint("junior maxDeposit", junior.maxDeposit(bob));
        _fundVault(bob, 1e18);
        vm.prank(bob);
        vault.setOperator(address(junior), true);
        _admitDepositor(address(junior), bob);
        vm.prank(bob);
        (bool ok,) = address(junior).call(abi.encodeCall(IERC4626.deposit, (1e18, bob)));
        emit log_named_string("re-deposit into junior", ok ? "ok" : "REVERT (ExceededMaxDeposit)");
        assertFalse(junior.killed(), "a tranche nobody is underwriting should not be retired by a routine liquidation");
    }

    /// Characterisation: a live junior with real capital taking a small slash is NOT killed.
    function test_L12_healthyJuniorSmallSlashNotKilled() public {
        _fundTranche(address(senior), alice, 1000e18);
        _fundTranche(address(junior), bob, 10e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        _setPrice(address(collateral), 0.4e18);
        uint256 supply = junior.totalSupply();
        uint256 total = junior.totalAssets();
        // 1 USD repaid -> 1.02 USD slash -> 2.55 tokens out of 10
        uint256 assets = 1.02e18 * 1e18 / 0.4e18;
        emit log_named_uint("latch lhs totalSupply", supply);
        emit log_named_uint("latch rhs (total-assets)*100", (total - assets) * 100);
        _mintStable(defaultLiquidator, 1e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 1e18);
        emit log_named_uint("junior assets after slash", junior.totalAssets());
        assertFalse(junior.killed(), "healthy junior with real capital must not be killed by a small slash");
        assertEq(junior.maxDeposit(bob), type(uint256).max);
    }
}
