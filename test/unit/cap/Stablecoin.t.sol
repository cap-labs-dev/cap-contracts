// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockIRM } from "../mocks/MockIRM.sol";
import { BaseTest } from "../utils/BaseTest.sol";

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
}
