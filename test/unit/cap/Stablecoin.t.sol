// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

    // --- metadata / config ---

    function test_decimalsIs18() public view {
        assertEq(scoin.decimals(), 18);
    }

    function test_underlyingDecimals() public view {
        assertEq(scoin.underlyingDecimals(), 18);
    }

    // --- unbacked mint / burn ---

    function test_mintUnbacked_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.mintUnbacked(alice, 1e18);
    }

    function test_mintUnbacked_increasesSupplyAndUnbacked() public {
        scoin.mintUnbacked(bob, 100e18);
        assertEq(scoin.balanceOf(bob), 100e18);
        assertEq(scoin.totalSupply(), 100e18);
        assertEq(irm.updateCalls(), 1);
        // unbacked == totalSupply -> utilization 1e27
        assertEq(scoin.utilizationRate(), RAY);
    }

    function test_burnUnbacked_decreases() public {
        scoin.mintUnbacked(bob, 100e18);
        scoin.burnUnbacked(bob, 40e18);
        assertEq(scoin.balanceOf(bob), 60e18);
        assertEq(scoin.totalSupply(), 60e18);
    }

    function test_unlockedSupply_excludesUnbacked() public {
        // backed deposit by alice
        vm.prank(alice);
        scoin.deposit(200e18, alice);
        // unbacked mint
        scoin.mintUnbacked(bob, 50e18);

        assertEq(scoin.totalSupply(), 250e18);
        // unlocked = totalSupply - unbacked = backed portion
        assertEq(scoin.unlockedSupply(), 200e18);
    }

    function test_utilizationRate_partial() public {
        vm.prank(alice);
        scoin.deposit(300e18, alice); // backed
        scoin.mintUnbacked(bob, 100e18); // unbacked
        // unbacked / totalSupply = 100/400 = 0.25e27
        assertEq(scoin.utilizationRate(), 0.25e27);
    }

    // --- bad debt ---

    function test_increaseBadDebt_onlyAuthority() public {
        vm.prank(alice);
        vm.expectRevert();
        scoin.increaseBadDebt(1e18);
    }

    function test_badDebt_reducesTotalAssets() public {
        scoin.mintUnbacked(bob, 100e18);
        assertEq(scoin.totalAssets(), 100e18);
        scoin.increaseBadDebt(30e18);
        assertEq(scoin.badDebt(), 30e18);
        assertEq(scoin.totalAssets(), 70e18);
    }

    // --- deposit (backed) ---

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

    // --- instant redeem when fully liquid (unbacked == 0) ---

    function test_maxRedeem_fullWhenLiquid() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        // no unbacked -> unlockedSupply == totalSupply, alice can redeem her full balance
        assertEq(scoin.maxRedeem(alice), 100e18);
    }

    // --- utilization edge case ---

    function test_utilizationRate_zeroSupply_isZero() public view {
        // no mints/deposits: must not divide by zero
        assertEq(scoin.totalSupply(), 0);
        assertEq(scoin.utilizationRate(), 0);
    }

    // --- bad debt conversions (previews) ---

    function test_previewRedeem_withBadDebt_sharesAboveBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(20e18); // totalAssets = 80

        // shares (50) > badDebt (20): linear (50-20) + socialized conversion of the 20
        uint256 assets = scoin.previewRedeem(50e18);
        assertGt(assets, 30e18); // at least the un-socialized remainder
        assertLt(assets, 50e18); // strictly less than 1:1 because of bad debt
    }

    function test_previewRedeem_withBadDebt_sharesBelowBadDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(60e18); // totalAssets = 40

        // shares (40) < badDebt (60): fully socialized conversion
        uint256 assets = scoin.previewRedeem(40e18);
        assertGt(assets, 0);
        assertLt(assets, 40e18);
    }

    function test_previewWithdraw_withBadDebt_bothBranches() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(20e18); // badDebtInAssets = 20

        uint256 below = scoin.previewWithdraw(10e18); // assets < badDebtInAssets
        uint256 above = scoin.previewWithdraw(50e18); // assets >= badDebtInAssets
        assertGt(below, 0);
        assertGt(above, below);
    }

    // --- bad debt absorption on instant redeem ---

    function test_instantRedeem_absorbsBadDebt_whenSharesExceedDebt() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(20e18);
        uint256 irmBefore = irm.updateCalls();
        uint256 aliceAssetsBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 assets = scoin.redeem(50e18, alice, alice); // ERC4626 instant redeem

        // shares (50) > badDebt (20) -> bad debt fully cleared
        assertEq(scoin.badDebt(), 0);
        assertEq(scoin.totalSupply(), 50e18);
        assertEq(asset.balanceOf(alice) - aliceAssetsBefore, assets);
        assertLt(assets, 50e18); // redeemer absorbed part of the loss
        assertEq(irm.updateCalls(), irmBefore + 1); // _withdraw pokes the IRM
    }

    function test_instantRedeem_absorbsBadDebt_partial() public {
        vm.prank(alice);
        scoin.deposit(100e18, alice);
        scoin.increaseBadDebt(60e18);

        vm.prank(alice);
        scoin.redeem(40e18, alice, alice);

        // shares (40) <= badDebt (60) -> remaining bad debt = 20
        assertEq(scoin.badDebt(), 20e18);
        assertEq(scoin.totalSupply(), 60e18);
    }

    // --- UUPS ---

    function test_upgrade_authorized() public {
        Stablecoin newImpl = new Stablecoin();
        UUPSUpgradeable(address(scoin)).upgradeToAndCall(address(newImpl), "");
        assertEq(scoin.decimals(), 18); // still functional
    }

    function test_upgrade_unauthorized_reverts() public {
        Stablecoin newImpl = new Stablecoin();
        vm.prank(alice);
        vm.expectRevert();
        UUPSUpgradeable(address(scoin)).upgradeToAndCall(address(newImpl), "");
    }
}
