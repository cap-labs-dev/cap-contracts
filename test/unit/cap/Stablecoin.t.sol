// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract StablecoinTest is BaseTest {
    Stablecoin internal scoin;
    MockERC20 internal asset;
    MockIRM internal irm;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _setUpAccessManager();
        asset = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();

        Stablecoin impl = new Stablecoin();
        scoin = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize, (address(accessManager), address(asset), "Cap USD", "cUSD", "", address(irm))
                )
            )
        );

        asset.mint(alice, 1_000e18);
        vm.prank(alice);
        asset.approve(address(scoin), type(uint256).max);
    }

    function test_decimalsIs18() public view {
        assertEq(scoin.decimals(), 18);
    }

    function test_mintCreditBacked_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.mintCreditBacked(alice, 1e18);
    }

    function test_mintCreditBacked_increasesSupplyAndCreditBacked() public {
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.balanceOf(bob), 100e18);
        assertEq(scoin.totalSupply(), 100e18);
        assertEq(scoin.creditBackedSupply(), 100e18);
        assertEq(irm.updateCalls(), 1);
        assertEq(scoin.utilizationRate(), RAY);
    }

    function test_burnCreditBacked_decreases() public {
        scoin.mintCreditBacked(bob, 100e18);
        scoin.burnCreditBacked(bob, 40e18);
        assertEq(scoin.balanceOf(bob), 60e18);
        assertEq(scoin.totalSupply(), 60e18);
        assertEq(scoin.creditBackedSupply(), 60e18);
    }

    function test_unlockedSupply_excludesCreditBacked() public {
        vm.prank(alice);
        scoin.deposit(200e18, alice);
        scoin.mintCreditBacked(bob, 50e18);

        assertEq(scoin.totalSupply(), 250e18);
        assertEq(scoin.unlockedSupply(), 200e18);
    }

    function test_utilizationRate_partial() public {
        vm.prank(alice);
        scoin.deposit(300e18, alice);
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.utilizationRate(), 0.25e27);
    }

    function test_increaseBadDebt_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.increaseBadDebt(1e18);
    }

    function test_badDebt_reducesTotalAssets() public {
        scoin.mintCreditBacked(bob, 100e18);
        assertEq(scoin.totalAssets(), 100e18);
        scoin.increaseBadDebt(30e18);
        assertEq(scoin.badDebt(), 30e18);
        assertEq(scoin.totalAssets(), 70e18);
    }

    function test_deposit_oneToOne() public {
        vm.prank(alice);
        uint256 shares = scoin.deposit(100e18, alice);
        assertEq(shares, 100e18);
        assertEq(scoin.balanceOf(alice), 100e18);
        assertEq(asset.balanceOf(address(scoin)), 100e18);
        assertEq(scoin.totalSupply(), 100e18);
    }

    function test_preview_oneToOne_18decimals() public view {
        assertEq(scoin.previewDeposit(123e18), 123e18);
        assertEq(scoin.previewMint(123e18), 123e18);
    }

    function test_maxRedeem_fullWhenLiquid() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        assertEq(scoin.maxRedeem(alice), 100e18);
    }

    function test_utilizationRate_zeroSupply_isZero() public view {
        assertEq(scoin.totalSupply(), 0);
        assertEq(scoin.utilizationRate(), 0);
    }

    function test_previewRedeem_withBadDebt_sharesAboveBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(20e18);

        uint256 assets = scoin.previewRedeem(50e18);
        assertGt(assets, 30e18);
        assertLt(assets, 50e18);
    }

    function test_previewRedeem_withBadDebt_sharesBelowBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(60e18);

        uint256 assets = scoin.previewRedeem(40e18);
        assertGt(assets, 0);
        assertLt(assets, 40e18);
    }

    function test_previewWithdraw_withBadDebt_bothBranches() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(20e18);

        uint256 below = scoin.previewWithdraw(10e18);
        uint256 above = scoin.previewWithdraw(50e18);
        assertGt(below, 0);
        assertGt(above, below);
    }

    function test_instantRedeem_absorbsBadDebt_whenSharesExceedDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(20e18);
        uint256 irmBefore = irm.updateCalls();
        uint256 aliceAssetsBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = scoin.redeem(50e18, alice, alice);

        assertEq(scoin.badDebt(), 0);
        assertEq(scoin.totalSupply(), 50e18);
        assertEq(asset.balanceOf(alice) - aliceAssetsBefore, assets);
        assertLt(assets, 50e18);
        assertEq(irm.updateCalls(), irmBefore + 1);
    }

    function test_instantRedeem_absorbsBadDebt_partial() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(60e18);

        vm.prank(alice);
        scoin.redeem(40e18, alice, alice);

        assertEq(scoin.badDebt(), 20e18);
        assertEq(scoin.totalSupply(), 60e18);
    }

    function test_upgrade_authorized() public {
        Stablecoin newImpl = new Stablecoin();
        UUPSUpgradeable(address(scoin)).upgradeToAndCall(address(newImpl), "");
        assertEq(scoin.decimals(), 18);
    }

    function test_upgrade_unauthorized_reverts() public {
        Stablecoin newImpl = new Stablecoin();
        vm.prank(alice);
        vm.expectRevert();
        UUPSUpgradeable(address(scoin)).upgradeToAndCall(address(newImpl), "");
    }
}
