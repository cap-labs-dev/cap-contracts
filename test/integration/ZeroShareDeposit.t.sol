// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { IERC7540AsyncRedeem } from "../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { IWrapper } from "../../contracts/interfaces/IWrapper.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice A nonzero post-seed deposit quoting zero shares must not transfer any assets.
contract ZeroShareDepositTest is CapDeployer {
    address internal supplier = makeAddr("supplier");
    Tranche internal tranche;

    function setUp() public {
        _deployCap();
        (, address t,) = _createMarket("Zero-share deposits");
        tranche = Tranche(t);
        _fundTranche(t, supplier, 10_000);
    }

    function test_trancheRejectsZeroQuoteAndStillAcceptsOneShare() public {
        _mintCollateral(address(tranche), 10_000);
        _mintCollateral(supplier, 3);
        assertEq(tranche.previewDeposit(1), 0);
        uint256 supply = tranche.totalSupply();
        vm.startPrank(supplier);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroShares.selector);
        tranche.deposit(1, supplier);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroShares.selector);
        tranche.mint(0, supplier);
        vm.stopPrank();
        assertEq(collateral.balanceOf(supplier), 3);
        assertEq(tranche.totalAssets(), 20_000);
        assertEq(tranche.totalSupply(), supply);
        vm.prank(supplier);
        assertEq(tranche.deposit(2, supplier), 1);
    }

    function test_underwriterRejectsZeroQuoteBeforeAutoAllocation() public {
        Underwriter pool = _deployUnderwriter();
        _fundUnderwriter(address(pool), supplier, 10_000);
        _mintCollateral(address(pool), 10_000);
        pool.addTranche(address(tranche));
        _admitDepositor(address(tranche), address(pool));
        pool.setDefaultTranche(address(tranche));
        _mintCollateral(supplier, 3);
        assertEq(pool.previewDeposit(1), 0);
        vm.startPrank(supplier);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroShares.selector);
        pool.deposit(1, supplier);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroShares.selector);
        pool.mint(0, supplier);
        vm.stopPrank();
        assertEq(collateral.balanceOf(supplier), 3);
        assertEq(pool.totalAssets(), 20_000);
        assertEq(pool.totalSupply(), 10_000);
        assertEq(pool.totalDebt(), 0);
        assertEq(tranche.balanceOf(address(pool)), 0);
        vm.prank(supplier);
        assertEq(pool.deposit(2, supplier), 1);
    }

    function test_wrapperRejectsZeroQuoteWithoutTakingStablecoin() public {
        _mintStable(supplier, 10_003);
        vm.startPrank(supplier);
        stablecoin.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(10_000, supplier);
        vm.stopPrank();
        _mintStable(address(wrapper), 10_000);
        assertEq(wrapper.previewDeposit(1), 0);
        vm.startPrank(supplier);
        vm.expectRevert(IWrapper.ZeroShares.selector);
        wrapper.deposit(1, supplier);
        vm.expectRevert(IWrapper.ZeroShares.selector);
        wrapper.mint(0, supplier);
        vm.stopPrank();
        assertEq(stablecoin.balanceOf(supplier), 3);
        assertEq(stablecoin.balanceOf(address(wrapper)), 20_000);
        assertEq(wrapper.totalSupply(), 10_000);
        vm.prank(supplier);
        assertEq(wrapper.deposit(2, supplier), 1);
    }

    function test_stablecoinRejectsZeroDepositAndMint() public {
        _depositStable(supplier, 1e6);
        uint256 supply = stablecoin.totalSupply();
        vm.startPrank(supplier);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroShares.selector);
        stablecoin.deposit(0, supplier);
        vm.expectRevert(IERC7540AsyncRedeem.ZeroShares.selector);
        stablecoin.mint(0, supplier);
        vm.stopPrank();
        assertEq(stablecoin.totalSupply(), supply);
        assertEq(cusdUnderlying.balanceOf(address(stablecoin)), 1e6);
    }

    /// @dev A deposit too small to buy one default-tranche share is accepted and held idle,
    /// instead of reverting or donating it to the tranche's holders.
    function test_underwriterHoldsDepositIdleWhenNestedTrancheQuoteIsZero() public {
        Underwriter pool = _deployUnderwriter();
        _fundUnderwriter(address(pool), supplier, 10_000);
        _mintCollateral(address(tranche), 100_000);
        pool.addTranche(address(tranche));
        _admitDepositor(address(tranche), address(pool));
        pool.setDefaultTranche(address(tranche));
        _mintCollateral(supplier, 1);
        assertEq(tranche.previewDeposit(1), 0, "the deposit cannot buy a tranche share");
        vm.prank(supplier);
        assertEq(pool.deposit(1, supplier), 1, "the pool still issues its own shares");
        assertEq(collateral.balanceOf(supplier), 0);
        assertEq(collateral.balanceOf(address(pool)), 10_001, "held idle in the pool");
        assertEq(pool.totalAssets(), 10_001);
        assertEq(pool.totalDebt(), 0);
        assertEq(tranche.balanceOf(address(pool)), 0);
        assertEq(tranche.totalAssets(), 110_000, "nothing reaches the tranche");
        assertEq(collateral.allowance(address(pool), address(tranche)), 0);
    }
}
