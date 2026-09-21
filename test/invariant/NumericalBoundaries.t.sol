// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IERC7540AsyncRedeem } from "../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { IFixedMarket } from "../../contracts/interfaces/IFixedMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { DeadShares } from "../../contracts/utils/DeadShares.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";

contract NumericalBoundariesTest is CapDeployer {
    address internal alice;

    function setUp() public {
        _deployCap();
        alice = makeAddr("boundary alice");
    }

    function _decimals(uint256 raw) internal pure returns (uint8) {
        return raw % 3 == 0 ? 6 : raw % 3 == 1 ? 8 : 18;
    }

    function _stable(uint8 decimals_) internal returns (Stablecoin s, MockERC20 token) {
        token = new MockERC20("Reserve boundary", "RSV", decimals_);
        s = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(token), "Boundary cUSD", "bcUSD", address(irm), address(0))
                )
            )
        );
        token.mint(alice, 1e30);
        vm.prank(alice);
        token.approve(address(s), type(uint256).max);
    }

    function testFuzz_reserveDecimalsParAndMintCeil(uint8 decimalSeed, uint96 raw) public {
        uint8 d = _decimals(decimalSeed);
        (Stablecoin s, MockERC20 token) = _stable(d);
        uint256 assets = bound(raw, 0, 1e24);
        uint256 scale = 10 ** (18 - d);
        vm.prank(alice);
        uint256 shares = s.deposit(assets, alice);
        assertEq(shares, assets * scale);
        assertEq(token.balanceOf(address(s)), assets);
        uint256 requestedShares = uint256(raw) % 1e24 + 1;
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 paid = s.mint(requestedShares, alice);
        assertEq(before - token.balanceOf(alice), paid);
        // Independent integer unit bounds: minimal raw reserve units covering the mint.
        assertGe(paid * scale, requestedShares);
        assertLt((paid - 1) * scale, requestedShares);
        uint256 balanceBefore = token.balanceOf(alice);
        uint256 n = s.balanceOf(alice);
        vm.prank(alice);
        uint256 out = s.instantRedeem(n, alice, alice);
        assertEq(token.balanceOf(alice) - balanceBefore, out);
        assertLe(out, assets + paid, "round trip creates no reserve units");
        // At most one reserve unit was donated by an unaligned share mint.
        assertLe(assets + paid - out, 1);
    }

    function testFuzz_custodyAcrossDecimals(uint8 decimalSeed, uint96 raw) public {
        MockERC20 token = new MockERC20("Custody boundary", "CST", _decimals(decimalSeed));
        uint256 assets = bound(raw, 0, 1e27);
        token.mint(alice, assets);
        vm.startPrank(alice);
        token.approve(address(vault), assets);
        vault.deposit(address(token), assets, alice);
        vault.transfer(address(0xB0B), address(token), assets / 2);
        vault.withdraw(address(token), assets - assets / 2, alice);
        vm.stopPrank();
        assertEq(vault.totalSupply(vault.id(address(token))), assets / 2);
        assertEq(token.balanceOf(address(vault)), assets / 2);
        vm.prank(address(0xB0B));
        vault.withdraw(address(token), assets / 2, alice);
        assertEq(token.balanceOf(alice), assets);
        assertEq(vault.totalSupply(vault.id(address(token))), 0);
    }

    function _tranche(uint8 decimals_) internal returns (FloatingMarket market, Tranche t, MockERC20 token) {
        token = _newCollateral("Collateral boundary", "COL", decimals_, 1e18);
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        uint256[] memory weights = new uint256[](1);
        weights[0] = RAY;
        (address m, address[] memory tranches) =
            _createMarket("Boundary", address(this), defaultBorrower, assets, weights);
        market = FloatingMarket(m);
        t = Tranche(tranches[0]);
        t.setMaxCapital(1e30);
        _admitDepositor(address(t), alice);
        token.mint(alice, 1e30);
        vm.startPrank(alice);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(address(token), 1e29, alice);
        vault.setOperator(address(t), true);
        vm.stopPrank();
    }

    function test_seedZeroOneAndMinimumAcrossDecimals() public {
        for (uint256 i; i < 3; ++i) {
            (, Tranche t,) = _tranche(_decimals(i));
            uint256[3] memory tooSmall = [uint256(0), 1, DEAD_SHARES];
            for (uint256 j; j < 3; ++j) {
                vm.expectRevert(abi.encodeWithSelector(DeadShares.DepositBelowSeed.selector, tooSmall[j], DEAD_SHARES));
                vm.prank(alice);
                t.deposit(tooSmall[j], alice);
            }
            vm.prank(alice);
            assertEq(t.deposit(DEAD_SHARES + 1, alice), 1);
            assertEq(t.balanceOf(DeadShares.HOLDER), DEAD_SHARES);
            vm.prank(alice);
            assertEq(t.instantRedeem(1, alice, alice), 1);
            assertEq(t.totalAssets(), DEAD_SHARES);
        }
    }

    function testFuzz_donationRoundTripAndAggregateWithdraw(uint8 decimalSeed, uint96 raw, uint64 rawDonation) public {
        (, Tranche t, MockERC20 token) = _tranche(_decimals(decimalSeed));
        uint256 initial = bound(raw, DEAD_SHARES + 3, 1e24);
        uint256 donation = bound(rawDonation, 0, 1e18);
        vm.prank(alice);
        uint256 shares = t.deposit(initial, alice);
        // Explicit tracked donation, from the same finite actor's custody balance.
        vm.prank(alice);
        vault.transfer(address(t), address(token), donation);
        uint256 left = shares / 2;
        vm.startPrank(alice);
        t.requestRedeem(left, alice, alice);
        t.requestRedeem(shares - left, alice, alice);
        vm.stopPrank();
        uint256 requested = t.convertToAssets(shares) / 2;
        if (requested == 0) requested = 1;
        uint256 burned = _exactQueuedWithdrawal(t, requested);
        uint256 remaining = shares - burned;
        vm.prank(alice);
        uint256 finalPayment = t.redeem(remaining, alice, alice);
        assertLe(requested + finalPayment, initial + donation);
        assertEq(t.redemptionQueue(), 0);
        assertEq(t.totalSupply(), DEAD_SHARES);
        assertEq(vault.totalSupply(vault.id(address(token))), token.balanceOf(address(vault)));
    }

    function _exactQueuedWithdrawal(Tranche t, uint256 requested) internal returns (uint256 burned) {
        uint256 supply = t.totalSupply();
        uint256 assets = t.totalAssets();
        uint256 before = vault.balanceOf(alice, t.asset());
        vm.prank(alice);
        burned = t.withdraw(requested, alice, alice);
        assertEq(vault.balanceOf(alice, t.asset()) - before, requested);
        assertGe(burned * (assets + 1), requested * (supply + 1));
        assertLt((burned - 1) * (assets + 1), requested * (supply + 1));
    }

    function testFuzz_withdrawalPreservesHealthAtCreditBoundary(uint8 decimalSeed, uint96 raw, uint8 offset) public {
        (FloatingMarket market, Tranche t, MockERC20 token) = _tranche(_decimals(decimalSeed));
        uint256 amount = bound(raw, 10_000, 1_000_000) * 10 ** token.decimals();
        vm.prank(alice);
        t.deposit(amount, alice);
        uint256 capital = amount * 1e18 / 10 ** token.decimals();
        uint256 borrowAmount = capital / 2 - uint256(offset % 3);
        assertEq(market.creditLimit(), capital / 2);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, borrowAmount);
        uint256 maxAssets = t.maxInstantWithdraw(alice);
        uint256 before = vault.balanceOf(alice, address(token));
        vm.prank(alice);
        t.instantWithdraw(maxAssets, alice, alice);
        assertEq(vault.balanceOf(alice, address(token)) - before, maxAssets);
        assertGe(market.healthiness(), RAY);
        // Independently check retained collateral covers the lock, including token granularity.
        assertGe(t.totalAssets() * 1e18 / 10 ** token.decimals(), market.lockedValue(address(t)));
    }

    function testFuzz_liquidationTokenGranularity(uint8 decimalSeed, uint96 raw) public {
        (FloatingMarket market, Tranche t, MockERC20 token) = _tranche(_decimals(decimalSeed));
        uint256 capital = 10_000 * 10 ** token.decimals();
        vm.prank(alice);
        t.deposit(capital, alice);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 5000e18);
        _depositStable(defaultLiquidator, 5000e18);
        _setPrice(address(token), 0.4e18);
        uint256 amount = bound(raw, 1, market.maxLiquidatable());
        uint256 debt = market.totalDebt();
        uint256 tokensBefore = token.balanceOf(defaultLiquidator);
        vm.prank(defaultLiquidator);
        (uint256 repaid, uint256 value) = market.liquidate(defaultLiquidator, amount);
        uint256 delivered = token.balanceOf(defaultLiquidator) - tokensBefore;
        assertEq(debt - market.totalDebt(), repaid);
        assertEq(value, delivered * 0.4e18 / 10 ** token.decimals());
        assertLe(value * 100, repaid * 102 + 50, "half-up bonus bound, half of one cUSD wei");
        assertEq(vault.totalSupply(vault.id(address(token))), token.balanceOf(address(vault)));
    }

    function testFuzz_fixedTermGraceAndAggregateDebt(uint32 rawTerm, uint8 side) public {
        (address m, address senior,) = _createFixedMarket("Term boundary");
        FixedMarket market = FixedMarket(m);
        market.setUnderwriterRate(0.2e27);
        _fundTranche(senior, alice, 10_000e18);
        _setMaxCapital(IBaseMarket(m), 10_000e18);
        uint256 term = bound(rawTerm, 1 days, 30 days);
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, 100e18, term);
        uint256 edge = market.expiry(id) + market.grace();
        vm.warp(edge - 1);
        vm.expectRevert(IFixedMarket.StillInGracePeriod.selector);
        market.extendAdmin(id, 1 days);
        vm.warp(edge + side % 2);
        market.extendAdmin(id, 1 days);
        assertEq(market.expiry(id), block.timestamp + 1 days);
        assertEq(market.debt(id), market.totalDebt());
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply());
        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1, 1 days - 1);
        vm.expectRevert(IFixedMarket.InvalidTerm.selector);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1, 30 days + 1);
    }

    function testFuzz_shortfallExactWithdrawUsesMinimalShares(uint96 rawAssets, uint96 rawLoss, uint96 rawCredit)
        public
    {
        // Small integer domain makes an independent exhaustive quote possible.
        (Stablecoin s, MockERC20 token) = _stable(18);
        vm.prank(alice);
        s.deposit(1000, alice);
        uint256 loss = bound(rawLoss, 1, 900);
        // Model an actual reserve loss before recognizing it, not a paper-only shortfall.
        vm.prank(address(s));
        token.transfer(address(0x1055), loss);
        s.recognizeBadDebtInReserve(loss);
        s.mintCreditBacked(defaultBorrower, bound(rawCredit, 1, 10_000));
        uint256 requested = bound(rawAssets, 1, 1000 - loss);
        uint256 expected;
        // Economic exit relation: retainedBacking/remainingSupply =
        // supply*backing/(supply*backing + remainingSupply*loss).
        // Search integer shares and compare rationals without copying the inverse formula.
        for (uint256 n = 1; n <= 1000; ++n) {
            uint256 remaining = 1000 - n;
            uint256 anchor = 1000 * (1000 - loss);
            if ((1000 - loss - requested) * (anchor + remaining * loss) >= remaining * anchor) {
                expected = n;
                break;
            }
        }
        uint256 quoted = s.quoteWithdraw(requested);
        assertEq(quoted, expected, "exhaustive rational inverse");
        if (quoted <= s.maxInstantRedeem(alice)) {
            uint256 before = token.balanceOf(alice);
            vm.prank(alice);
            assertEq(s.instantWithdraw(requested, alice, alice), expected);
            assertEq(token.balanceOf(alice) - before, requested);
            assertEq(s.backing() - s.creditBackedSupply(), token.balanceOf(address(s)));
        }
    }

    function testFuzz_rateKinkNeighbors(uint96 rawReserve, uint8 neighbor) public {
        uint256 reserveAmount = bound(rawReserve, 1e18, 10_000e18);
        _depositStable(alice, reserveAmount);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.01e27, slope0: 0.1e27, slope1: 0.5e27, kink: 0.8e27 })
        );
        // credit/(reserve+credit) reaches .8 when credit == 4*reserve.
        (address m, address senior,) = _createMarket("Kink boundary");
        _fundTranche(senior, alice, reserveAmount * 20);
        _setMaxCapital(FloatingMarket(m), reserveAmount * 20);
        uint256 principal = reserveAmount * 4 + neighbor % 3 - 1;
        vm.prank(defaultBorrower);
        FloatingMarket(m).borrow(defaultBorrower, principal);
        vm.warp(block.timestamp + 1 hours);
        uint256 live = FloatingMarket(m).totalDebt();
        FloatingMarket(m).chargePremium();
        assertEq(FloatingMarket(m).totalDebt(), live, "checkpoint preserves debt at kink");
        assertEq(stablecoin.creditBackedSupply(), live);
    }
}
