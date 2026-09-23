// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Virtual-share rounding can cross the retirement threshold on any withdrawal path.
contract TrancheRetirementTest is CapDeployer {
    Tranche internal tranche;
    address internal supplier = makeAddr("supplier");

    function setUp() public {
        _deployCap();
        (address market, address t,) = _createMarket("Retirement");
        tranche = Tranche(t);
        _fundTranche(t, supplier, 1_000_000);
        vm.prank(market);
        tranche.slash(990_000, makeAddr("slash recipient"));
        assertEq(tranche.totalAssets(), 10_000);
        assertFalse(tranche.killed(), "exactly one percent remains open");
    }

    function test_instantRedeemLatchesRetirement() public {
        _crossThreshold(0);
    }

    function test_instantWithdrawLatchesRetirement() public {
        _crossThreshold(1);
    }

    function test_queuedRedeemLatchesRetirement() public {
        _crossThreshold(2);
    }

    function test_queuedWithdrawLatchesRetirement() public {
        _crossThreshold(3);
    }

    function _crossThreshold(uint256 route) internal {
        uint256 shares = 20_099;
        uint256 assets = 201;
        vm.startPrank(supplier);
        uint256 id;
        if (route >= 2) id = tranche.requestRedeem(shares, supplier, supplier);
        vm.expectEmit(false, false, false, true, address(tranche));
        emit ITranche.Killed();
        if (route == 0) assertEq(tranche.instantRedeem(shares, supplier, supplier), assets);
        if (route == 1) assertEq(tranche.instantWithdraw(assets, supplier, supplier), shares);
        if (route == 2) assertEq(tranche.redeem(id, shares, supplier, supplier), assets);
        if (route == 3) assertEq(tranche.withdraw(id, assets, supplier, supplier), shares);
        vm.stopPrank();

        assertEq(tranche.totalSupply(), 979_901);
        assertEq(tranche.totalAssets(), 9_799);
        assertLt(tranche.totalAssets(), Math.ceilDiv(tranche.totalSupply(), 100));
        assertTrue(tranche.killed());
        assertEq(tranche.maxDeposit(supplier), 0);
        assertEq(tranche.maxMint(supplier), 0);
        vm.startPrank(supplier);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, supplier, 1, 0));
        tranche.deposit(1, supplier);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxMint.selector, supplier, 1, 0));
        tranche.mint(1, supplier);
        vm.stopPrank();

        _fundVault(address(tranche), 1_000_000);
        assertEq(tranche.maxDeposit(supplier), 0, "donations cannot undo retirement");
        uint256 remaining = tranche.balanceOf(supplier);
        vm.prank(supplier);
        assertGt(tranche.instantRedeem(remaining, supplier, supplier), 0, "retirement leaves exits open");
    }

    function test_withdrawalAtExactOnePercentDoesNotRetire() public {
        vm.prank(supplier);
        assertEq(tranche.instantRedeem(100, supplier, supplier), 1);
        assertEq(tranche.totalAssets() * 100, tranche.totalSupply());
        assertFalse(tranche.killed());
        assertEq(tranche.maxDeposit(supplier), type(uint256).max);
    }

    function test_largeBalancesDoNotOverflowTheRetirementComparison() public {
        (, address t,) = _createMarket("Large retirement comparison");
        Tranche large = Tranche(t);
        uint256 amount = type(uint256).max / 2;
        _fundTranche(t, supplier, amount);
        address market = large.market();
        vm.prank(market);
        assertEq(large.slash(1, makeAddr("recipient")), 1);
        assertGt(large.totalAssets(), type(uint256).max / 100);
        assertFalse(large.killed());
        vm.prank(supplier);
        assertEq(large.instantRedeem(1, supplier, supplier), 0);
        assertFalse(large.killed());
    }
}
