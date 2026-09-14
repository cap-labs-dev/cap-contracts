// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { DeadShares } from "../../../contracts/utils/DeadShares.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice The wrapper is an ERC-4626 over cUSD: it opts in, and deposit/withdraw fold vested
/// premium into `totalAssets` before the share price is read.
contract WrapperTest is BaseTest {
    uint256 internal constant PERIOD = 12 hours;
    uint256 internal constant PREMIUM = 10e18;

    Stablecoin internal scoin;
    Wrapper internal wrapper;
    MockERC20 internal usdc;
    MockIRM internal irm;

    address internal alice = makeAddr("alice");
    address internal outsider = makeAddr("outsider");

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
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", "", address(irm), address(0))
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

    function test_depositClaimsVestedPremiumBeforePricingTheShare() public {
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

    function test_withdrawClaimsVestedPremiumBeforePricingTheShare() public {
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
