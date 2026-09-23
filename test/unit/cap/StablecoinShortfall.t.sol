// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockAeraVault } from "../../shared/mocks/MockAeraVault.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

/// @notice Credit-independent exit pricing and reserve exhaustion with six-decimal USDC.
contract StablecoinShortfallTest is BaseTest {
    Stablecoin internal scoin;
    MockERC20 internal usdc;
    MockAeraVault internal reserve;
    address internal depositor = makeAddr("depositor");
    address internal borrower = makeAddr("borrower");

    function setUp() public {
        _setUpAccessManager();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        reserve = new MockAeraVault();
        scoin = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (
                        address(accessManager),
                        address(usdc),
                        "Cap USD",
                        "cUSD",
                        address(new MockIRM()),
                        address(reserve),
                        12 hours
                    )
                )
            )
        );
        usdc.mint(depositor, 100e6);
        vm.startPrank(depositor);
        usdc.approve(address(scoin), type(uint256).max);
        scoin.deposit(100e6, depositor);
        vm.stopPrank();

        usdc.burn(address(scoin), 20e6);
        scoin.recognizeBadDebtInReserve(20e18);
    }

    function testFuzz_creditAndPremiumDoNotChangeEitherQuote(
        uint96 principal,
        uint96 premium,
        uint96 shares,
        uint96 assets
    ) public {
        principal = uint96(bound(principal, 1, 100_000_000e18));
        premium = uint96(bound(premium, 1, 1_000_000e18));
        shares = uint96(bound(shares, 0, 200e18));
        assets = uint96(bound(assets, 0, 200e6));
        uint256[3] memory beforeQuotes =
            [scoin.convertToAssets(shares), scoin.convertToShares(assets), scoin.quoteWithdraw(assets)];

        scoin.mintCreditBacked(borrower, principal);
        _assertQuotes(shares, assets, beforeQuotes);
        scoin.fundCreditBacked(premium);
        _assertQuotes(shares, assets, beforeQuotes);
        scoin.burnCreditBacked(borrower, principal);
        _assertQuotes(shares, assets, beforeQuotes);
        assertEq(scoin.unlockedSupply(), 80e18, "credit never adds reserve capacity");
        assertEq(scoin.backing(), 80e18 + premium, "managed backing still includes performing credit");
        assertEq(scoin.totalAssets(), (80e18 + premium) / 1e12);
    }

    function _assertQuotes(uint256 shares, uint256 assets, uint256[3] memory expected) internal view {
        assertEq(scoin.convertToAssets(shares), expected[0], "redeem quote unchanged");
        assertEq(scoin.convertToShares(assets), expected[1], "floor inverse unchanged");
        assertEq(scoin.quoteWithdraw(assets), expected[2], "ceil inverse unchanged");
    }

    function test_fullReserveWithdrawalIsInitiallyBlocked() public {
        scoin.mintCreditBacked(borrower, 100e18);
        assertEq(scoin.quoteWithdraw(80e6), 100e18);
        assertEq(scoin.maxInstantRedeem(borrower), 80e18);

        vm.expectRevert(
            abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, borrower, 80e6, 60_952380)
        );
        vm.prank(borrower);
        scoin.instantWithdraw(80e6, borrower, borrower);
    }

    /// @dev Tokens have no provenance restriction. A borrower can absorb the old loss and exhaust
    /// the reserve through repeated exits, without reducing performing credit. Check both routes.
    function testFuzz_repeatedCreditRedemptionsRetireLossAndExhaustReserve(bool queued) public {
        scoin.mintCreditBacked(borrower, 100e18);
        uint256 id;
        if (queued) {
            vm.prank(borrower);
            id = scoin.requestRedeem(100e18, borrower, borrower);
        }
        uint256[4] memory payouts = [uint256(60_952380), 18_097502, 947856, 2262];
        for (uint256 i; i < payouts.length; ++i) {
            uint256 shares = queued ? scoin.claimableRedeemRequest(id, borrower) : scoin.maxInstantRedeem(borrower);
            uint256 debtBefore = scoin.badDebt();
            vm.prank(borrower);
            uint256 paid =
                queued ? scoin.redeem(id, shares, borrower, borrower) : scoin.instantRedeem(shares, borrower, borrower);
            assertEq(paid, payouts[i]);
            assertEq(debtBefore - scoin.badDebt(), shares - paid * 1e12, "haircut retires the loss");
            assertLe(scoin.creditBackedSupply() + scoin.badDebt(), scoin.totalSupply());
            assertEq(scoin.creditBackedSupply(), 100e18, "redemption is not repayment");
        }
        assertEq(usdc.balanceOf(borrower), 80e6);
        assertEq(usdc.balanceOf(address(scoin)), 0);
        assertEq(scoin.badDebt(), 0);
        assertEq(scoin.totalSupply(), 100e18);
        assertEq(scoin.balanceOf(depositor), 100e18);
        assertEq(scoin.redemptionQueue(), 0);
        assertEq(scoin.convertToAssets(100e18), 100e6, "par quote with no shortfall");
        assertEq(scoin.maxInstantRedeem(depositor), 0, "no immediately available cash");
        assertEq(scoin.maxInstantWithdraw(depositor), 0);
    }

    function test_zeroReserveBackingWithBadDebtBlocksExitsAndAllowsRepayment() public {
        usdc.burn(address(scoin), 80e6);
        scoin.recognizeBadDebtInReserve(80e18);
        scoin.mintCreditBacked(borrower, 100e18);

        assertEq(scoin.convertToAssets(0), 0);
        assertEq(scoin.convertToAssets(1e18), 0);
        assertEq(scoin.convertToAssets(200e18), 0);
        assertEq(scoin.quoteWithdraw(0), 0);
        assertEq(scoin.quoteWithdraw(1), 100e18);
        assertEq(scoin.unlockedSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector, borrower, 1, 0));
        vm.prank(borrower);
        scoin.instantWithdraw(1, borrower, borrower);

        scoin.burnCreditBacked(borrower, 100e18);
        assertEq(scoin.badDebt(), 100e18);
        assertEq(scoin.totalSupply(), 100e18);
        assertEq(scoin.creditBackedSupply(), 0);
        assertEq(scoin.convertToAssets(1e18), 0);
    }

    function test_roundingRetirementIsCappedAtSubUsdcBadDebt() public {
        scoin.mintCreditBacked(borrower, 100e18);
        vm.prank(depositor);
        scoin.coverBadDebt(20e18 - 1);

        vm.prank(borrower);
        uint256 paid = scoin.instantRedeem(80e18, borrower, borrower);
        assertEq(paid, 80e6 - 1, "payout rounds down by one USDC atom");
        assertEq(scoin.badDebt(), 0, "only the last share wei of loss is retired");
        assertEq(scoin.totalSupply() - scoin.creditBackedSupply(), 1);
        assertEq(usdc.balanceOf(address(scoin)), 1, "rounding dust remains in the reserve");
    }

    function test_investmentChangesAvailabilityWithoutChangingPrice() public {
        scoin.mintCreditBacked(borrower, 100e18);
        uint256 quote = scoin.convertToAssets(80e18);
        uint256 needed = scoin.quoteWithdraw(40e6);
        scoin.invest(40e6);

        assertEq(scoin.convertToAssets(80e18), quote, "liquidity does not enter the pricing basis");
        assertEq(scoin.quoteWithdraw(40e6), needed);
        assertLt(scoin.unlockedSupply(), 80e18, "liquidity still caps execution");
        vm.prank(borrower);
        assertEq(scoin.instantWithdraw(40e6, borrower, borrower), needed);
        assertEq(usdc.balanceOf(address(scoin)), 0);
        assertEq(usdc.balanceOf(address(reserve)), 40e6);
        assertGt(scoin.badDebt(), 0, "on-hand cash can run out while invested backing remains");
        assertEq(scoin.unlockedSupply(), 0);
    }
}
