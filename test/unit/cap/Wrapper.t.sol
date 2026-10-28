// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { DeadShares } from "../../../contracts/utils/DeadShares.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The wrapper prices shares using collectible premium, then harvests it during execution.
contract WrapperTest is BaseTest {
    uint256 internal constant PERIOD = 12 hours;
    uint256 internal constant PREMIUM = 10e18;

    Stablecoin internal scoin;
    Wrapper internal wrapper;
    MockERC20 internal usdc;
    MockIRM internal irm;

    address internal alice = makeAddr("alice");
    address internal outsider = makeAddr("outsider");
    address internal bob = makeAddr("bob");
    address internal earlyHolder = makeAddr("early holder");
    address internal dustHolder = makeAddr("dust holder");

    function setUp() public {
        vm.warp(1_000_000);
        _setUpAccessManager();
        usdc = new MockERC20("USD Coin", "USDC", 18);
        irm = new MockIRM();

        scoin = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", address(irm), address(0), 12 hours)
                )
            )
        );
        wrapper = Wrapper(
            _deployProxy(
                address(new Wrapper()), abi.encodeCall(Wrapper.initialize, (address(accessManager), address(scoin)))
            )
        );

        usdc.mint(alice, 1_000e18);
        vm.startPrank(alice);
        usdc.approve(address(scoin), type(uint256).max);
        scoin.deposit(200e18, alice);
        scoin.approve(address(wrapper), type(uint256).max);
        vm.stopPrank();
    }

    function _fund(uint256 amount) internal {
        scoin.fundCreditBacked(amount);
    }

    function test_initializeOptsTheVaultIntoTheAsset() public view {
        assertTrue(scoin.optedIn(address(wrapper)));
        assertEq(scoin.stakedSupply(), 0);
        assertEq(wrapper.asset(), address(scoin));
        assertEq(wrapper.name(), "Staked Cap USD");
        assertEq(wrapper.symbol(), "stcUSD");
        assertEq(wrapper.decimals(), 18);
    }

    function test_emptyVaultQuotesMintAtParPlusTheSeed() public view {
        uint256 shares = 100e18 - DeadShares.SHARES;
        assertEq(wrapper.previewDeposit(100e18), shares);
        assertEq(wrapper.previewMint(shares), 100e18);
    }

    function test_mintSeedsDeadShares() public {
        uint256 shares = 100e18 - DeadShares.SHARES;
        vm.prank(alice);
        uint256 assets = wrapper.mint(shares, alice);

        assertEq(assets, 100e18);
        assertEq(wrapper.balanceOf(alice), shares);
        assertEq(wrapper.balanceOf(DeadShares.HOLDER), DeadShares.SHARES);
    }

    function test_firstDepositBelowTheSeedReverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(DeadShares.DepositBelowSeed.selector, DeadShares.SHARES, DeadShares.SHARES)
        );
        wrapper.deposit(DeadShares.SHARES, alice);
    }

    function test_depositAddsTheBalanceToStakedSupply() public {
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        assertEq(scoin.stakedSupply(), 100e18);
        assertEq(scoin.balanceOf(address(wrapper)), 100e18);
        assertEq(wrapper.totalAssets(), 100e18);
        assertEq(wrapper.balanceOf(alice), 100e18 - DeadShares.SHARES);
        assertEq(wrapper.balanceOf(DeadShares.HOLDER), DeadShares.SHARES);
    }

    function test_totalAssetsIncludesUnclaimedVest() public {
        vm.prank(alice);
        wrapper.deposit(100e18, alice);
        _fund(PREMIUM);
        vm.warp(block.timestamp + PERIOD);

        uint256 claimable = scoin.claimable(address(wrapper));
        assertGt(claimable, 0);
        assertEq(wrapper.totalAssets(), 100e18 + claimable);
    }

    function test_depositHarvestMatchesPremiumIncludedInQuote() public {
        vm.prank(alice);
        wrapper.deposit(100e18, alice);
        _fund(PREMIUM);
        vm.warp(block.timestamp + 20 * PERIOD);

        uint256 owed = scoin.claimable(address(wrapper));
        assertApproxEqRel(owed, PREMIUM, 1e12);

        vm.prank(alice);
        wrapper.deposit(50e18, alice);

        assertEq(scoin.claimable(address(wrapper)), 0, "the vest was pulled in");
        assertEq(scoin.balanceOf(address(wrapper)), 100e18 + owed + 50e18);
        assertEq(wrapper.totalAssets(), scoin.balanceOf(address(wrapper)));
    }

    function test_withdrawHarvestMatchesPremiumIncludedInQuote() public {
        vm.prank(alice);
        wrapper.deposit(100e18, alice);
        _fund(PREMIUM);
        vm.warp(block.timestamp + 20 * PERIOD);

        uint256 owed = scoin.claimable(address(wrapper));
        vm.prank(alice);
        uint256 assets = wrapper.redeem(50e18, alice, alice);

        assertGt(assets, 50e18, "she leaves with her share of the vest");
        assertApproxEqAbs(assets, (100e18 + owed) / 2, 1);
        assertEq(scoin.claimable(address(wrapper)), 0);
    }

    function test_aHolderWhoNeverOptsInEarnsNothing() public {
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        usdc.mint(outsider, 100e18);
        vm.startPrank(outsider);
        usdc.approve(address(scoin), type(uint256).max);
        scoin.deposit(100e18, outsider);
        vm.stopPrank();

        assertFalse(scoin.optedIn(outsider));
        _fund(PREMIUM);
        vm.warp(block.timestamp + 20 * PERIOD);

        assertEq(scoin.claimable(outsider), 0);
        assertApproxEqRel(scoin.claimable(address(wrapper)), PREMIUM, 1e12);
    }

    /// @dev All amounts are token wei. Normal funding and floored reward debts create an
    /// entitlement of 1,501 against 1,500 spendable, without draining funds or editing storage.
    function _prepareCappedClaim() internal {
        vm.prank(alice);
        scoin.transfer(earlyHolder, 2);
        vm.prank(earlyHolder);
        scoin.optIn();
        _fund(1);
        vm.warp(block.timestamp + 100 * PERIOD);
        vm.prank(earlyHolder);
        assertEq(scoin.claim(alice), 1);
        assertEq(scoin.premiumPerShare(), RAY / 2);
        assertEq(scoin.balanceOf(address(scoin)), 0);

        vm.startPrank(alice);
        wrapper.deposit(2_001, alice);
        scoin.transfer(bob, 1_000);
        scoin.transfer(dustHolder, 1);
        vm.stopPrank();
        vm.startPrank(bob);
        scoin.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1_000, bob);
        vm.stopPrank();
        vm.prank(dustHolder);
        scoin.optIn();
        assertEq(scoin.stakedSupply(), 3_004);

        _fund(1_502);
        vm.warp(block.timestamp + 100 * PERIOD);
        vm.prank(earlyHolder);
        assertEq(scoin.claim(alice), 1);
        vm.prank(dustHolder);
        assertEq(scoin.claim(alice), 1);

        // Checkpoint the wrapper's full entitlement without claiming or changing its balance.
        vm.prank(alice);
        scoin.transfer(address(wrapper), 0);
        assertEq(scoin.pendingPremium(address(wrapper)), 1_501);
        assertEq(scoin.balanceOf(address(scoin)), 1_500);
        assertEq(scoin.balanceOf(address(wrapper)), 3_001);
        assertEq(wrapper.totalSupply(), 3_001);
    }

    function test_cappedPremium_depositPricesCollectibleAssets() public {
        _prepareCappedClaim();
        uint256 expected = Math.mulDiv(10_000, wrapper.totalSupply() + 1, 4_501 + 1);
        assertEq(wrapper.previewDeposit(10_000), expected);
        vm.prank(alice);
        assertEq(wrapper.deposit(10_000, alice), expected);
        assertEq(wrapper.totalAssets(), 4_501 + 10_000);
    }

    function test_cappedPremium_mintPricesCollectibleAssets() public {
        _prepareCappedClaim();
        uint256 expected = Math.mulDiv(10_000, 4_501 + 1, wrapper.totalSupply() + 1, Math.Rounding.Ceil);
        assertEq(wrapper.previewMint(10_000), expected);
        vm.prank(alice);
        assertEq(wrapper.mint(10_000, alice), expected);
        assertEq(wrapper.totalAssets(), 4_501 + expected);
    }

    function test_cappedPremium_redeemPricesCollectibleAssets() public {
        _prepareCappedClaim();
        uint256 expected = Math.mulDiv(1_000, 4_501 + 1, wrapper.totalSupply() + 1);
        assertEq(wrapper.previewRedeem(1_000), expected);
        vm.prank(bob);
        assertEq(wrapper.redeem(1_000, bob, bob), expected);
        assertEq(wrapper.totalAssets(), 4_501 - expected);
    }

    function test_cappedPremium_withdrawPricesCollectibleAssets() public {
        _prepareCappedClaim();
        uint256 expected = Math.mulDiv(1_500, wrapper.totalSupply() + 1, 4_501 + 1, Math.Rounding.Ceil);
        assertEq(wrapper.previewWithdraw(1_500), expected);
        vm.prank(alice);
        assertEq(wrapper.withdraw(1_500, alice, alice), expected);
        assertEq(wrapper.totalAssets(), 4_501 - 1_500);
    }

    function test_cappedPremium_claimableExcludesRedemptionEscrow() public {
        _prepareCappedClaim();
        vm.prank(alice);
        scoin.requestRedeem(10_000, alice, alice);
        assertEq(scoin.balanceOf(address(scoin)), 11_500);
        assertEq(scoin.redemptionQueue(), 10_000);
        assertEq(scoin.claimable(address(wrapper)), 1_500);
        assertEq(wrapper.totalAssets(), 4_501);

        vm.prank(address(wrapper));
        assertEq(scoin.claim(address(wrapper)), 1_500);
        assertEq(wrapper.totalAssets(), 4_501, "harvesting does not change the quoted assets");
        assertEq(scoin.pendingPremium(address(wrapper)), 0, "the unpaid wei is still cleared");
        assertEq(scoin.balanceOf(address(scoin)), scoin.redemptionQueue());
    }

    function test_initializeCannotRunTwice() public {
        vm.expectRevert();
        wrapper.initialize(address(accessManager), address(scoin));
    }

    function test_upgradeUnauthorizedReverts() public {
        Wrapper newImpl = new Wrapper();
        vm.prank(alice);
        vm.expectRevert();
        UUPSUpgradeable(address(wrapper)).upgradeToAndCall(address(newImpl), "");
    }
}
