// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// Round-3 port of round-1 L-12 (C4_KillLatch). HEAD `Tranche.slash` (:71-95): returns early only
/// when `total == 0` or the delivered value floors to 0; the latch
/// `totalSupply() > (total - assets) * 100` (:88) still fires on a tranche that holds nothing but
/// the 1e3 dead-share seed, so an exited junior is retired by the first routine liquidation.
contract R1_L12_KillLatch is CapDeployer {
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
        junior.instantRedeem(bobShares, bob, bob);
        emit log_named_uint("junior supply after exit (dead shares)", junior.totalSupply());
        emit log_named_uint("junior assets after exit (wei)", junior.totalAssets());

        _fundTranche(address(senior), alice, 1000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);

        _setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 10e18);
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

    function test_L12_healthyJuniorSmallSlashNotKilled() public {
        _fundTranche(address(senior), alice, 1000e18);
        _fundTranche(address(junior), bob, 10e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 400e18);
        _setPrice(address(collateral), 0.4e18);
        _mintStable(defaultLiquidator, 1e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 1e18);
        assertFalse(junior.killed(), "healthy junior with real capital must not be killed by a small slash");
        assertEq(junior.maxDeposit(bob), type(uint256).max);
    }
}
