// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IFloatingMarket } from "../../contracts/interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IPremiumVesting } from "../../contracts/interfaces/IPremiumVesting.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapRoles } from "../../contracts/utils/CapRoles.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { MockIRM } from "../shared/mocks/MockIRM.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @notice Pins the accounting the protocol has to get exactly right: that a redemption retires
/// the shortfall it absorbed, that premium reaches the capital which was exposed while it vested,
/// that a repayment clears exactly the debt it burns, and that debt never outruns the cUSD minted
/// against it. Each test below is a bug that was real once, so a regression is a repeat rather
/// than a novelty. The tail of the file covers parameter and interface hardening on the same
/// paths.
contract AccountingIntegrityTest is CapDeployer, ERC1155Holder {
    Stablecoin internal scoin;
    MockERC20 internal usdc;
    MockIRM internal mockIrm;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _deployCap();

        usdc = new MockERC20("USD Coin", "USDC", 18);
        mockIrm = new MockIRM();
        Stablecoin impl = new Stablecoin();
        scoin = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", "", address(mockIrm), address(0))
                )
            )
        );
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = Stablecoin.mintCreditBacked.selector;
        sels[1] = Stablecoin.burnCreditBacked.selector;
        sels[2] = Stablecoin.recognizeBadDebtInCredit.selector;
        accessManager.setTargetFunctionRole(address(scoin), sels, CapRoles.MARKET);
        accessManager.grantRole(CapRoles.MARKET, address(this), 0);

        usdc.mint(address(this), 10_000e18);
        usdc.approve(address(scoin), type(uint256).max);
    }

    function _writeOffCredit(uint256 amount) internal {
        scoin.mintCreditBacked(makeAddr("defaulted"), amount);
        scoin.recognizeBadDebtInCredit(amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // BAD DEBT IS RETIRED ON EVERY REDEMPTION PATH
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A queued redemption must retire the shortfall it absorbed, exactly like an instant one.
    /// Overriding only ERC4626's `_withdraw` reached the instant path alone, so the queue paid the
    /// haircut and dropped it.
    function test_asyncRedeemRetiresBadDebt() public {
        scoin.deposit(1_000e18, address(this));
        _writeOffCredit(100e18);

        uint256 badBefore = scoin.badDebt();
        uint256 ratioBefore = scoin.totalAssets() * 1e27 / scoin.totalSupply();

        uint256 quoted = scoin.previewRedeem(100e18);
        uint256 id = scoin.requestRedeem(100e18, address(this), address(this));
        uint256 paid = scoin.redeem(id, 100e18, address(this), address(this));

        assertEq(paid, quoted, "queued payout matches the curve");
        assertLt(paid, 100e18, "redeemer took a haircut");

        // the haircut retires the shortfall rather than stranding in the reserve
        assertEq(scoin.badDebt(), badBefore - (100e18 - paid), "shortfall retires by exactly the haircut");
        assertGt(scoin.totalAssets() * 1e27 / scoin.totalSupply(), ratioBefore, "redeeming heals the peg");
        assertEq(scoin.totalAssets(), usdc.balanceOf(address(scoin)), "no reserve stranded off the books");
    }

    /// @dev Queueing a redemption must be worth exactly what taking it instantly would have been.
    /// Redeems the same size from the same state down each path and compares the outcomes, so
    /// neither route is a cheaper way out of the shortfall than the other.
    function testFuzz_asyncAndInstantRedeemSettleIdentically(uint256 shares) public {
        scoin.deposit(1_000e18, address(this));
        _writeOffCredit(100e18);
        shares = bound(shares, 1e18, 500e18);

        uint256 snapshot = vm.snapshotState();

        uint256 instantPaid = scoin.redeem(shares, address(this), address(this));
        uint256 instantBad = scoin.badDebt();
        uint256 instantAssets = scoin.totalAssets();
        uint256 instantReserve = usdc.balanceOf(address(scoin));

        vm.revertToState(snapshot);

        uint256 id = scoin.requestRedeem(shares, address(this), address(this));
        uint256 queuedPaid = scoin.redeem(id, shares, address(this), address(this));

        assertEq(queuedPaid, instantPaid, "same payout");
        assertEq(scoin.badDebt(), instantBad, "same shortfall retired");
        assertEq(scoin.totalAssets(), instantAssets, "same backing");
        assertEq(usdc.balanceOf(address(scoin)), instantReserve, "same reserve");
        assertEq(scoin.totalAssets(), usdc.balanceOf(address(scoin)), "books match the reserve");
    }

    function test_instantRedeemRetiresBadDebt() public {
        scoin.deposit(1_000e18, address(this));
        _writeOffCredit(100e18);

        uint256 badBefore = scoin.badDebt();
        uint256 ratioBefore = scoin.totalAssets() * 1e27 / scoin.totalSupply();

        scoin.redeem(100e18, address(this), address(this));

        assertLt(scoin.badDebt(), badBefore, "instant path retires shortfall");
        assertGt(scoin.totalAssets() * 1e27 / scoin.totalSupply(), ratioBefore, "instant path heals");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PREMIUM VESTING THROUGH AN IDLE WINDOW: THE UNDERWRITER
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev An idle stretch must not compress the vest into a cliff. Freezing the clock while
    /// nothing was staked meant the whole idle window accrued the instant supply returned, so a one
    /// wei deposit could sweep the buffer having borne no risk for a second of it. Sliding the
    /// schedule instead keeps the drip on the clock: the dust holder can claim nothing at the
    /// instant it arrives, and thereafter only what vests while it is the one exposed.
    function test_underwriterIdleWindowIsNotACliff() public {
        Underwriter uw = _deployUnderwriter();
        MarketBundle memory b = _createReadyMarket("m");
        uw.addTranche(b.tranche0Addr);
        uw.setDefaultTranche(b.tranche0Addr);
        _admitDepositor(address(b.tranche0), address(uw));

        // honest LP funds the underwriter and it underwrites a borrow
        _fundUnderwriter(address(uw), alice, 1_000e18);
        _fundTranche(b.tranche1Addr, bob, 100e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        // let the tranche vest long enough that report() pulls essentially the whole premium
        vm.warp(block.timestamp + 20 * uw.vestingPeriod());
        uw.report(b.tranche0Addr);

        uint256 buffered = stablecoin.balanceOf(address(uw));
        assertGt(buffered, 0, "there is premium at stake");
        assertEq(uw.remaining(), buffered, "the whole buffer is vesting");

        // alice queues her whole position, so activeSupply hits zero
        uint256 aliceShares = uw.balanceOf(alice);
        vm.prank(alice);
        uw.requestRedeem(aliceShares, alice, alice);
        assertEq(uw.stakedSupply(), 0, "vault is idle");

        // a few hours pass against nobody
        vm.warp(block.timestamp + 3 hours);

        _fundVault(address(this), 1);
        _admitDepositor(address(uw), address(this));
        vault.setOperator(address(uw), true);
        uw.deposit(1, address(this));
        uw.optIn();

        assertEq(uw.claimable(address(this)), 0, "the window it missed is not payable to it");
        assertEq(uw.remaining(), buffered, "and none of it was burned either");

        vm.warp(block.timestamp + uw.vestingPeriod());
        assertApproxEqRel(uw.claimable(address(this)), buffered * 632 / 1000, 0.02e18, "one window vests about 63%");
        assertLt(uw.claimable(address(this)), buffered, "and not the rest");

        vm.warp(block.timestamp + 20 * uw.vestingPeriod());
        assertApproxEqRel(uw.claimable(address(this)), buffered, 1e12, "the tail comes out over more windows");

        uw.claim(address(this));
        assertApproxEqRel(stablecoin.balanceOf(address(this)), buffered, 1e12, "payable in full, dust aside");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A FLOATING REPAYMENT CLEARS EXACTLY WHAT IT BURNS
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A repayment must clear exactly the debt it burns. The scaled reduction used to be
    /// rounded half up and the burn taken at the requested amount, so at an index of 1.4907 a 1-wei
    /// payment cleared 2 wei of debt, leaving credit-backed supply with nothing behind it.
    function test_repayClearsExactlyWhatItBurns() public {
        FloatingMarket market = _grownIndexMarket();
        emit log_named_uint("index", market.index());

        // minting is itself credit-backed, so references have to be taken after it
        _mintStable(defaultBorrower, 100e18);

        // Consecutive amounts, because the old rounding only overshot on some residues and a
        // single amount can land exactly by luck. Repaying does not move the clock, so the index
        // is the same on every pass and only the residue changes.
        for (uint256 amount = 1e18; amount < 1e18 + 8; ++amount) {
            uint256 debtBefore = market.totalDebt();
            uint256 creditBefore = stablecoin.creditBackedSupply();

            vm.prank(defaultBorrower);
            uint256 repaid = market.repay(amount);

            assertEq(debtBefore - market.totalDebt(), repaid, "debt cleared matches the settlement");
            assertEq(creditBefore - stablecoin.creditBackedSupply(), repaid, "credit burned matches it too");
            assertLe(repaid, amount, "never settles above the request");
        }
    }

    /// @dev A payment too small to move a whole scaled unit clears nothing, so it must not be
    /// accepted. Flooring is what stops the leak, and the honest consequence of flooring is that
    /// sub-unit dust is rejected rather than taken for a no-op. chargePremium is the poke.
    function test_subUnitRepayIsRejected() public {
        FloatingMarket market = _grownIndexMarket();

        _mintStable(defaultBorrower, 10);
        vm.prank(defaultBorrower);
        vm.expectRevert(IFloatingMarket.InvalidScaledAmount.selector);
        market.repay(1);
    }

    /// @dev The invariant across an arbitrary sequence of partial repayments at an arbitrary index.
    /// The old leak was a wei or two per call, so a single-call test understates it; what matters is
    /// that it cannot accumulate.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_repaymentsNeverDriftFromCredit(uint96 rawAmount, uint32 elapsed, uint8 rounds) public {
        FloatingMarket market = _grownIndexMarket();
        rounds = uint8(bound(rounds, 1, 8));

        _mintStable(defaultBorrower, 10_000e18);

        for (uint256 i; i < rounds; ++i) {
            vm.warp(block.timestamp + bound(elapsed, 1, 30 days));
            market.chargePremium();

            uint256 debt = market.totalDebt();
            if (debt == 0) break;
            uint256 amount = bound(rawAmount, 1, debt);

            uint256 creditBefore = stablecoin.creditBackedSupply();
            // the gap between credit and debt, which only a leaking repay could move. Premium
            // accrual has its own rounding, so this is measured across the repay alone
            uint256 gapBefore = creditBefore - debt;

            vm.prank(defaultBorrower);
            uint256 repaid;
            try market.repay(amount) returns (uint256 settled) {
                repaid = settled;
            } catch {
                // sub-scaled-unit dust, nothing to assert beyond the state not moving
                assertEq(market.totalDebt(), debt, "a rejected repay changes nothing");
                assertEq(stablecoin.creditBackedSupply(), creditBefore, "and burns nothing");
                continue;
            }

            assertEq(debt - market.totalDebt(), repaid, "cleared matches settled");
            assertEq(creditBefore - stablecoin.creditBackedSupply(), repaid, "burned matches settled");
            assertLe(repaid, amount, "never above the request");
            assertEq(stablecoin.creditBackedSupply() - market.totalDebt(), gapBefore, "no drift, ever");
        }
    }

    /// @dev Liquidation settles through the same flooring, and its ordering is more delicate: the
    /// health gate and maxLiquidatable are both read off totalDebt, so the entitlement has to be
    /// taken before scaledDebt moves or the market reads as healthy mid-liquidation.
    function test_liquidationClearsExactlyWhatItBurns() public {
        MarketBundle memory b = _createReadyMarket("liq");
        _fundTranche(b.tranche0Addr, alice, 400e18);
        _fundTranche(b.tranche1Addr, bob, 600e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 500e18);

        // run the debt past the liquidation threshold and let the index grow well above one ray
        vm.warp(block.timestamp + 3650 days);
        b.market.chargePremium();
        assertLt(b.market.healthiness(), 1e27, "market must be liquidatable");

        _mintStable(defaultLiquidator, 5_000e18);
        uint256 debtBefore = b.market.totalDebt();
        uint256 creditBefore = stablecoin.creditBackedSupply();

        vm.prank(defaultLiquidator);
        (uint256 repaid,) = b.market.liquidate(defaultLiquidator, 100e18);

        assertGt(repaid, 0, "something was liquidated");
        assertEq(debtBefore - b.market.totalDebt(), repaid, "debt cleared matches the settlement");
        assertEq(creditBefore - stablecoin.creditBackedSupply(), repaid, "credit burned matches it too");
    }

    /// @dev A market whose index has grown well above one ray, which is what exposes the rounding.
    function _grownIndexMarket() internal returns (FloatingMarket market) {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        vm.warp(block.timestamp + 730 days);
        b.market.chargePremium();
        market = b.market;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PREMIUM CHARGING SURVIVES ANY TRANCHE WEIGHT SPLIT
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The exact counterexample the fuzzer originally found: a zero senior weight leaves no
    /// slack for the half-up rounding on two 50% juniors, and four seconds of accrual was enough
    /// to underflow _chargePremium and brick every borrow, repay and liquidation for good.
    function test_zeroWeightSeniorSurvives() public {
        uint256[] memory weights = new uint256[](3);
        weights[0] = 0;
        weights[1] = 0.5e27;
        weights[2] = 0.5e27;

        FloatingMarket market = _readyMarketWithWeights("zero-senior", weights);

        vm.warp(block.timestamp + 4);
        (uint256 liquidityPremium, uint256 underwriterPremium) = market.premium();
        emit log_named_uint("underwriter premium (odd)", underwriterPremium);
        assertEq(underwriterPremium % 2, 1, "the odd premium is what triggers the overrun");

        uint256 creditBefore = stablecoin.creditBackedSupply();
        market.chargePremium();

        // the whole premium is still minted, so the debt stays repayable
        assertEq(
            stablecoin.creditBackedSupply() - creditBefore, liquidityPremium + underwriterPremium, "full premium minted"
        );
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "debt matches credit");

        // and the market keeps working
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 1e18);
    }

    /// @dev No split that sums to one ray may brick a market, whatever the rounding does.
    ///
    /// The weights are drawn on a coarse grid of twentieths deliberately. Fuzzing them uniformly
    /// over [0, 1e27] reads as more thorough but is useless here: the overruns live exactly on the
    /// degenerate splits, and a uniform draw essentially never lands on a round zero or a clean
    /// half. A grid version of this test passes without the clamp, which is worse than no test.
    /// forge-config: default.fuzz.runs = 2048
    function testFuzz_anyWeightSplitCharges(uint8 rawA, uint8 rawB, uint32 elapsed) public {
        elapsed = uint32(bound(elapsed, 1, 30 days));

        uint256 a = bound(rawA, 0, 20);
        uint256 b = bound(rawB, 0, 20 - a);
        uint256[] memory weights = new uint256[](3);
        weights[0] = a * 1e27 / 20;
        weights[1] = b * 1e27 / 20;
        weights[2] = 1e27 - weights[0] - weights[1];

        FloatingMarket market = _readyMarketWithWeights("fuzz-weights", weights);

        vm.warp(block.timestamp + elapsed);
        (uint256 liquidityPremium, uint256 underwriterPremium) = market.premium();
        uint256 creditBefore = stablecoin.creditBackedSupply();

        market.chargePremium();

        assertEq(
            stablecoin.creditBackedSupply() - creditBefore,
            liquidityPremium + underwriterPremium,
            "premium fully minted for every split"
        );
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "debt stays repayable");
    }

    function _readyMarketWithWeights(string memory name, uint256[] memory weights)
        internal
        returns (FloatingMarket market)
    {
        (address marketAddr, address[] memory tranches) =
            _createMarket(name, defaultMarketOwner, defaultBorrower, weights);
        market = FloatingMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        market.setFixedCreditLimit(1_000e18);

        _fundTranche(tranches[0], alice, 400e18);
        _fundTranche(tranches[1], bob, 400e18);
        _fundTranche(tranches[2], makeAddr("carol"), 400e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PREMIUM VESTING THROUGH AN IDLE WINDOW: THE TRANCHE
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev The tranche mirror of the underwriter case above. Here the whole epoch elapses idle,
    /// which under the frozen clock left the entire buffer claimable by the first dust deposit.
    /// Sliding the epoch end pushes the untouched remainder out over the time it had left instead.
    function test_trancheIdleWindowIsNotACliff() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();

        uint256 buffered = stablecoin.balanceOf(b.tranche0Addr);
        assertGt(buffered, 0, "there is premium at stake");
        assertEq(b.tranche0.remaining(), buffered, "the whole buffer is vesting");

        // alice queues out, so the tranche has no active supply
        uint256 aliceShares = b.tranche0.balanceOf(alice);
        vm.prank(alice);
        b.tranche0.requestRedeem(aliceShares, alice, alice);
        assertEq(b.tranche0.stakedSupply(), 0, "tranche is idle");

        // a window runs against nobody; the remainder freezes rather than dumping on the next deposit
        vm.warp(block.timestamp + b.tranche0.vestingPeriod());

        _fundVault(address(this), 1);
        _admitDepositor(address(b.tranche0), address(this));
        vault.setOperator(b.tranche0Addr, true);
        b.tranche0.deposit(1, address(this));
        b.tranche0.optIn();

        assertEq(b.tranche0.claimable(address(this)), 0, "the window it missed is not payable to it");
        assertEq(b.tranche0.remaining(), buffered, "with nothing burned");

        vm.warp(block.timestamp + b.tranche0.vestingPeriod());
        assertApproxEqRel(
            b.tranche0.claimable(address(this)), buffered * 632 / 1000, 0.02e18, "one window vests about 63%"
        );

        vm.warp(block.timestamp + 20 * b.tranche0.vestingPeriod());
        assertApproxEqRel(b.tranche0.claimable(address(this)), buffered, 1e12, "the tail comes out over more windows");

        b.tranche0.claim(address(this));
        assertApproxEqRel(stablecoin.balanceOf(address(this)), buffered, 1e12, "payable in full, dust aside");
    }

    /// @dev {ITranche-fund} used to sit on PUBLIC_ROLE, where `restricted` is a no-op, so
    /// anyone could donate dust and poke it. The selector now sits with {CapRoles-MARKET}.
    function test_dustCannotStallPremiumRelease() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();

        uint256 buffered = stablecoin.balanceOf(b.tranche0Addr);
        assertGt(buffered, 0, "there is premium at stake");
        uint256 leftoverBefore = b.tranche0.remaining() + b.tranche0.vested();

        address griefer = makeAddr("griefer");
        _depositStable(griefer, 1e18);

        vm.startPrank(griefer);
        assertTrue(stablecoin.transfer(b.tranche0Addr, 1));
        vm.expectRevert();
        b.tranche0.fund(1);
        vm.stopPrank();

        uint256 until = block.timestamp + b.tranche0.vestingPeriod();
        while (block.timestamp < until) {
            vm.warp(block.timestamp + 12);
            vm.startPrank(griefer);
            assertTrue(stablecoin.transfer(b.tranche0Addr, 1));
            vm.expectRevert();
            b.tranche0.fund(1);
            vm.stopPrank();
        }

        assertEq(
            b.tranche0.remaining() + b.tranche0.vested(), leftoverBefore, "the pot is untouched until someone accrues"
        );
        assertApproxEqRel(b.tranche0.claimable(alice), buffered * 632 / 1000, 0.02e18, "but the view still leaks");

        // the donated dust is not stranded either: the next legitimate charge sweeps it in
        uint256 donated = stablecoin.balanceOf(b.tranche0Addr) - buffered;
        assertGt(donated, 0, "the dust is sitting there");

        vm.prank(alice);
        b.tranche0.claim(alice);

        uint256 fundedBefore = b.tranche0.remaining() + b.tranche0.vested();
        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        assertGe(
            (b.tranche0.remaining() + b.tranche0.vested()) - fundedBefore, donated, "and is swept into the next epoch"
        );
    }

    /// @dev The end-to-end read on the rounding direction. Both conversions in the per-share
    /// arithmetic round down, so a wei that will not divide is retained rather than promised
    /// twice: two holders of a single share each, splitting a single wei, are owed nothing and the
    /// wei stays in the tranche. Rounding half up owed each of them the whole wei, and the second
    /// one out underflowed `_storedPremiumBalance` and could never collect at all.
    ///
    /// The clamp behind that underflow is still there and still needed. It is not reachable from
    /// here — see test_roundingDownStillLetsEntitlementsPassThePot for the case that does reach
    /// it, which needs a debt rounded down against a mid-epoch balance change.
    function test_roundingLeavesUndividableDustInTheTranche() public {
        MarketBundle memory b = _createReadyMarket("dust");

        // a thousand of the first deposit is the dead-share seed, so 1002 leaves two live shares
        _fundTranche(b.tranche0Addr, alice, 1_002);
        assertEq(b.tranche0.stakedSupply(), 2, "two shares between the pair of them");

        vm.prank(alice);
        b.tranche0.transfer(bob, 1);
        vm.prank(bob);
        b.tranche0.optIn();
        assertEq(b.tranche0.balanceOf(alice), 1, "one each");
        assertEq(b.tranche0.balanceOf(bob), 1, "one each");

        // one wei of premium, halved and then rounded back up on both sides
        address donor = makeAddr("donor");
        _depositStable(donor, 1e18);
        vm.prank(donor);
        assertTrue(stablecoin.transfer(b.tranche0Addr, 1));
        vm.prank(b.tranche0.market());
        b.tranche0.fund(1);

        vm.warp(block.timestamp + b.tranche0.vestingPeriod() + 1);
        assertEq(b.tranche0.claimable(alice) + b.tranche0.claimable(bob), 0, "half a wei each rounds to none");

        vm.prank(alice);
        uint256 toAlice = b.tranche0.claim(alice);
        vm.prank(bob);
        uint256 toBob = b.tranche0.claim(bob);

        assertEq(toAlice + toBob, 0, "so neither takes anything, and neither reverts");
        assertEq(stablecoin.balanceOf(b.tranche0Addr), 1, "the wei is retained rather than promised twice");
    }

    /// @dev Accruing on top of an idle window used to strand the idle part for good. The freeze
    /// leaves the remainder intact, so a later notify picks the whole pot back up rather than only
    /// the not-yet-due slice.
    function test_trancheIdleWindowSurvivesTheNextNotify() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        uint256 buffered = b.tranche0.remaining();

        uint256 aliceShares = b.tranche0.balanceOf(alice);
        vm.prank(alice);
        b.tranche0.requestRedeem(aliceShares, alice, alice);
        assertEq(b.tranche0.stakedSupply(), 0, "tranche is idle");

        // half the window elapses against nobody, then a zero-amount fund accrues with a zero supply
        vm.warp(block.timestamp + 3 hours);
        vm.prank(b.tranche0.market());
        b.tranche0.fund(0);

        assertEq(b.tranche0.remaining(), buffered, "the idle half is carried, not written off");
        assertEq(stablecoin.balanceOf(b.tranche0Addr), buffered, "and it is all still held");
    }

    /// @dev The underwriter mirror of the above. Here {report} is the reachable re-vest: it is a
    /// curator call with no supply precondition, and it rebuilds the remainder from
    /// {remaining}. Sliding `lastReported` is what makes that read back the un-accrued remainder
    /// rather than only the not-yet-due part.
    function test_underwriterIdleWindowSurvivesTheNextReport() public {
        Underwriter uw = _deployUnderwriter();
        MarketBundle memory b = _createReadyMarket("m");
        uw.addTranche(b.tranche0Addr);
        uw.setDefaultTranche(b.tranche0Addr);
        _admitDepositor(address(b.tranche0), address(uw));

        _fundUnderwriter(address(uw), alice, 1_000e18);
        _fundTranche(b.tranche1Addr, bob, 100e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        vm.warp(block.timestamp + 7 hours);
        uw.report(b.tranche0Addr);

        uint256 buffered = uw.remaining();
        assertGt(buffered, 0, "there is premium at stake");

        uint256 aliceShares = uw.balanceOf(alice);
        vm.prank(alice);
        uw.requestRedeem(aliceShares, alice, alice);
        assertEq(uw.stakedSupply(), 0, "vault is idle");

        vm.warp(block.timestamp + 3 hours);
        uw.report(b.tranche0Addr);

        assertGe(uw.remaining(), buffered, "the idle leftover is carried, and a report may add to it");
        assertGe(stablecoin.balanceOf(address(uw)), buffered, "none of what was held was burned");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // THE QUEUE COUNTERS AND THE STAKED SUPPLY STAY IN STEP
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Premium is divided by the opted-in supply, and the share transfer inside
    /// `requestRedeem` is what drops the requester out of it. Bumping a queue counter before the
    /// transfer dropped them out of the divisor while they still held the shares and were a line
    /// away from being checkpointed at the rate it produced, so two equal holders splitting one
    /// vested epoch were each owed the whole pot the moment either of them queued. The staked
    /// figure has to move with the shares.
    function test_queueingDoesNotInflateTheRequestersPremiumShare() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 500e18);
        _fundTranche(b.tranche0Addr, bob, 500e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 100e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();

        // the epoch runs out with nobody touching the tranche, so all of it is still pending and
        // the accrual inside `requestRedeem` is the one that hands it out
        vm.warp(block.timestamp + 20 * b.tranche0.vestingPeriod());
        uint256 held = stablecoin.balanceOf(b.tranche0Addr);
        assertGt(held, 0, "there is premium at stake");

        uint256 aliceShares = b.tranche0.balanceOf(alice);
        vm.prank(alice);
        b.tranche0.requestRedeem(aliceShares, alice, alice);

        emit log_named_uint("alice claimable", b.tranche0.claimable(alice));
        emit log_named_uint("bob claimable  ", b.tranche0.claimable(bob));
        emit log_named_uint("premium held   ", held);

        assertLe(b.tranche0.claimable(alice) + b.tranche0.claimable(bob), held, "entitlements stay covered");
        assertApproxEqRel(b.tranche0.claimable(alice), held / 2, 0.001e18, "queueing buys the requester nothing");
        assertApproxEqRel(b.tranche0.claimable(bob), held / 2, 0.001e18, "and costs the holder who stayed nothing");
    }

    /// @dev The settlement mirror. `settledQueue` rising before the burn left the shares about to
    /// vanish still counted in the divisor with nobody holding them, so the slice apportioned to
    /// them was credited to no one and stranded in the tranche for good. Only the remaining holder
    /// was exposed across this epoch, so all of it has to be payable to him.
    function test_settlingAQueuedRedemptionStrandsNoPremium() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 500e18);
        _fundTranche(b.tranche0Addr, bob, 500e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 100e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();

        // queued in the same block the premium was funded, so she is checkpointed against none of
        // it and the epoch that follows is bob's alone
        uint256 aliceShares = b.tranche0.balanceOf(alice);
        vm.prank(alice);
        uint256 id = b.tranche0.requestRedeem(aliceShares, alice, alice);
        assertEq(b.tranche0.claimable(alice), 0, "she earned nothing before queueing");

        vm.warp(block.timestamp + 20 * b.tranche0.vestingPeriod());
        uint256 held = stablecoin.balanceOf(b.tranche0Addr);

        // the burn inside her settlement is the accrual that releases the epoch
        assertEq(b.tranche0.claimableRedeemRequest(id, alice), aliceShares, "her whole request is settleable");
        vm.prank(alice);
        b.tranche0.redeem(id, aliceShares, alice, alice);

        emit log_named_uint("bob claimable", b.tranche0.claimable(bob));
        emit log_named_uint("premium held ", held);

        assertEq(b.tranche0.claimable(alice), 0, "a settled request earns nothing either");
        assertApproxEqRel(b.tranche0.claimable(bob), held, 0.001e18, "and none of it was released to nobody");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // THE LOCKED-COLLATERAL GATE COVERS withdraw() AS WELL AS redeem()
    // ─────────────────────────────────────────────────────────────────────────

    function test_withdrawRespectsLockedValue() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        // collateral is now backing live debt, so most of it must not be withdrawable
        uint256 balance = b.tranche0.balanceOf(alice);
        uint256 gated = b.tranche0.maxWithdraw(alice);
        emit log_named_uint("share balance ", balance);
        emit log_named_uint("maxWithdraw   ", gated);
        assertLt(gated, balance, "gate must bite");

        // ERC4626Upgradeable.maxWithdraw is previewRedeem(maxRedeem(owner)) in OZ 5.7, and
        // maxRedeem is the override that applies instantUnlockedSupply. Only that delegation
        // keeps withdraw() behind the same gate as redeem()
        vm.prank(alice);
        vm.expectRevert();
        b.tranche0.withdraw(balance, alice, alice);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DEBT NEVER OUTRUNS THE CREDIT MINTED AGAINST IT
    // ─────────────────────────────────────────────────────────────────────────

    function test_debtNeverExceedsCreditBackedSupply() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 400e18);

        for (uint256 i; i < 20; ++i) {
            vm.warp(block.timestamp + 13);
            b.market.chargePremium();
        }

        emit log_named_uint("totalDebt         ", b.market.totalDebt());
        emit log_named_uint("creditBackedSupply", stablecoin.creditBackedSupply());
        assertLe(b.market.totalDebt(), stablecoin.creditBackedSupply(), "debt must stay repayable");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // THE UNDERWRITER'S CACHED VALUATION SURVIVES A SLASH
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `totalAssets` is the idle balance plus a cached valuation of the tranche positions, and
    /// a slash the cache has not seen prices shares above what backs them. Writing a deallocation
    /// down by whatever came back was not enough to keep it honest: a slashed tranche returns less
    /// than was allocated, so the shortfall stayed recorded as debt against a position that had
    /// already been fully exited, and that same call released the idle assets which made the phantom
    /// extractable. A depositor could redeem at the pre-slash price in that very block — there was
    /// no window for a report to land in. Deriving the mark from the shares that remain is what
    /// closes it: a full exit can only leave nothing recorded.
    function test_deallocatingASlashedPositionLeavesNoPhantomDebt() public {
        (Underwriter uw, Tranche t) = _underwriterOnATranche();
        _fundUnderwriter(address(uw), alice, 1_000e18);
        _fundUnderwriter(address(uw), bob, 1_000e18);

        // the deposits were allocated straight on, so no one can exit before the curator acts
        assertEq(uw.unlockedSupply(), 0, "everything is deployed");

        _slashTranche(t, 1_000e18);

        // the curator exits the whole position, which is what frees the liquidity to redeem against
        uw.deallocate(address(t), t.balanceOf(address(uw)));

        assertEq(t.balanceOf(address(uw)), 0, "the position is gone");
        assertEq(uw.totalDebt(), 0, "so nothing may still be recorded against it");
        assertEq(uw.totalAssets(), vault.balanceOf(address(uw), address(collateral)), "the books match the assets held");

        uint256 pool = uw.totalAssets();
        uint256 aliceRedeemable = uw.maxRedeem(alice);
        vm.prank(alice);
        uint256 paid = uw.redeem(aliceRedeemable, alice, alice);

        emit log_named_uint("pool after the slash", pool);
        emit log_named_uint("alice took          ", paid);
        emit log_named_uint("bob left with       ", uw.previewRedeem(uw.balanceOf(bob)));

        assertApproxEqRel(paid, pool / 2, 0.001e18, "a half holder takes half the slashed pool, not all of it");
        assertApproxEqRel(uw.previewRedeem(uw.balanceOf(bob)), pool / 2, 0.001e18, "the rest stays bob's");
    }

    /// @dev The invariant underneath it. Once the underwriter has touched a tranche its books must
    /// value that position at exactly what it could realise, whatever the slash did. Fuzzed over
    /// how deep the slash goes and how much of the position is exited, because the old write-down
    /// happened to be exact when nothing had been slashed and drifted by the shortfall when it had.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_underwriterBooksMatchWhatItCanRealise(uint96 rawSlash, uint16 rawFraction) public {
        (Underwriter uw, Tranche t) = _underwriterOnATranche();
        _fundUnderwriter(address(uw), alice, 1_000e18);

        uint256 slash = bound(rawSlash, 0, 900e18);
        if (slash > 0) {
            _slashTranche(t, slash);
        }

        uint256 held = t.balanceOf(address(uw));
        uw.deallocate(address(t), held * bound(rawFraction, 0, 10_000) / 10_000);

        uint256 realisable =
            vault.balanceOf(address(uw), address(collateral)) + t.previewRedeem(t.balanceOf(address(uw)));
        assertEq(uw.totalAssets(), realisable, "the books must equal what the underwriter could realise");
    }

    /// @dev A queued deallocation has left this vault's balance for the tranche's own, so a mark
    /// derived from the balance alone read the position as wiped out while its assets were still in
    /// flight. Every deposit re-marks the default tranche, so a depositor arriving in that window
    /// would have minted against a valuation of nearly nothing and captured the rebound the moment
    /// the request settled — a worse hole than the phantom debt above, and unprivileged.
    function test_aQueuedDeallocationIsNotAWriteOff() public {
        (Underwriter uw, Tranche t) = _underwriterOnATranche();
        _fundUnderwriter(address(uw), alice, 1_000e18);

        uint256 valued = uw.totalAssets();
        uint256 requestId = uw.deallocateAsync(address(t), t.balanceOf(address(uw)));

        assertEq(t.balanceOf(address(uw)), 0, "the shares have moved to the tranche");
        assertGt(uw.queuedShares(address(t)), 0, "so the position has to carry them itself");
        assertEq(uw.totalAssets(), valued, "requesting gives up nothing, so the mark must not move");

        // a report is the sharpest way to force a mark while the request is still outstanding
        uw.report(address(t));
        assertEq(uw.totalAssets(), valued, "and re-marking mid-queue must not write the position off");

        uw.finalizeDeallocateAsync(address(t), requestId, uw.queuedShares(address(t)));

        assertEq(uw.queuedShares(address(t)), 0, "nothing is left queued");
        assertEq(uw.totalDebt(), 0, "nor recorded against a tranche this vault has exited");
        assertApproxEqAbs(uw.totalAssets(), valued, 2, "and the assets came home at the value carried");
    }

    /// @dev Queueing an exit changes the position's value not at all — the shares move from one
    /// column to the other — but it marks for the reason {deallocate} does even when it pulls
    /// nothing out: touching a tranche is the chance to catch a slash the cache has not seen. Left
    /// out, it was the one curator path that could queue an exit against a stale valuation.
    function test_queueingADeallocationCatchesAnUnseenSlash() public {
        (Underwriter uw, Tranche t) = _underwriterOnATranche();
        _fundUnderwriter(address(uw), alice, 1_000e18);

        _slashTranche(t, 500e18);
        assertApproxEqRel(uw.totalAssets(), 1_000e18, 0.001e18, "nothing has re-marked it yet");

        uw.deallocateAsync(address(t), t.balanceOf(address(uw)));

        assertApproxEqRel(uw.totalAssets(), 500e18, 0.001e18, "queueing the exit re-values the position");
        assertApproxEqRel(uw.debt(address(t)), 500e18, 0.001e18, "against the tranche it belongs to");
        assertEq(uw.totalDebt(), uw.debt(address(t)), "and the aggregate still agrees with the entry");
    }

    /// @dev The other half of carrying them: they are valued at the tranche's live price, not at
    /// what was allocated, so a slash landing mid-queue is felt exactly as it would be on shares
    /// still held rather than deferred to settlement.
    function test_aSlashDuringAQueuedDeallocationStillLands() public {
        (Underwriter uw, Tranche t) = _underwriterOnATranche();
        _fundUnderwriter(address(uw), alice, 1_000e18);

        uint256 requestId = uw.deallocateAsync(address(t), t.balanceOf(address(uw)));

        _slashTranche(t, 500e18);

        uw.report(address(t));
        assertApproxEqRel(uw.totalAssets(), 500e18, 0.001e18, "half the book is gone and the books say so");

        uw.finalizeDeallocateAsync(address(t), requestId, uw.queuedShares(address(t)));
        assertApproxEqRel(uw.totalAssets(), 500e18, 0.001e18, "settling changes nothing about that");
    }

    /// @dev Anyone may name this vault as the controller of a redemption they request against their
    /// own shares, which mints a receipt here that no allocation of this vault's backs. Settling one
    /// of those down against the aggregate would retire shares still genuinely queued and take the
    /// mark below the position, so an unrecognised id is refused and the gift left alone.
    function test_aDonatedQueueReceiptCannotBeSettled() public {
        (Underwriter uw, Tranche t) = _underwriterOnATranche();
        _fundUnderwriter(address(uw), alice, 1_000e18);
        uw.deallocateAsync(address(t), t.balanceOf(address(uw)));

        _fundTranche(address(t), bob, 100e18);
        uint256 bobShares = t.balanceOf(bob);
        vm.prank(bob);
        uint256 donated = t.requestRedeem(bobShares, address(uw), bob);

        assertEq(uw.queuedRequest(address(t), donated), 0, "this vault never opened that id");
        assertGt(uw.queuedShares(address(t)), 0, "and it has real shares queued to protect");

        vm.expectRevert(IUnderwriter.UnknownQueuedRequest.selector);
        uw.finalizeDeallocateAsync(address(t), donated, 1);
    }

    /// @dev An underwriter holding a single tranche as its default, so deposits allocate straight
    /// through and the vault runs with nothing idle — the state the cache is designed around.
    function _underwriterOnATranche() internal returns (Underwriter uw, Tranche tranche) {
        uw = _deployUnderwriter();
        MarketBundle memory b = _createReadyMarket("uw");
        tranche = b.tranche0;
        uw.addTranche(b.tranche0Addr);
        uw.setDefaultTranche(b.tranche0Addr);
        _admitDepositor(b.tranche0Addr, address(uw));
    }

    /// @dev A tranche takes a slash from its own market and no other, so speak as that market
    /// rather than granting this contract the shared role. Lets a slash of an exact depth be aimed
    /// at the tranche without steering the market into liquidation to get there.
    function _slashTranche(Tranche tranche, uint256 value) internal {
        vm.prank(tranche.market());
        tranche.slash(value, makeAddr("attacker"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A FIXED BORROW STAYS INSIDE THE LIMIT IT PRICED AGAINST
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev A fixed loan mints its principal and only then prices the term premium, so the premium
    /// is charged at the rate its own mint created. Charging that higher rate is deliberate — the
    /// borrower causes the utilization and should pay for it — but `availableCredit` used to
    /// discount the draw at the rate standing before the mint, so the debt landed above the very
    /// limit it was sized to fit inside. Sizing against the projected rate is what closes it.
    function test_fixedBorrowStaysInsideTheCreditLimit() public {
        FixedMarket market = _fixedMarketOnSlope(0.1e27);

        uint256 limit = market.creditLimit();
        vm.prank(defaultBorrower);
        (uint256 id, uint256 principal) = market.borrow(defaultBorrower, type(uint256).max, 30 days);

        emit log_named_uint("credit limit", limit);
        emit log_named_uint("principal   ", principal);
        emit log_named_uint("debt        ", market.debt(id));

        assertGt(principal, 0, "the loan is real");
        assertLe(market.debt(id), limit, "principal plus premium must fit inside the limit");
    }

    /// @dev The same overshoot on a steeper curve does not merely breach the credit limit, it
    /// carries the debt past the liquidation threshold, so the borrow hands a liquidator a
    /// profitable position the moment it settles. The borrower keeps the cUSD and the tranches take
    /// the slashing. Nothing here is privileged: one call from the market's own borrower.
    function test_fixedBorrowCannotLeaveTheMarketLiquidatable() public {
        FixedMarket market = _fixedMarketOnSlope(2e27);

        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, 30 days);

        emit log_named_uint("debt                 ", market.debt(id));
        emit log_named_uint("liquidation threshold", market.debtLiquidationThreshold());
        emit log_named_uint("healthiness          ", market.healthiness());

        assertGe(market.healthiness(), 1e27, "a borrow must not leave the market liquidatable");
    }

    /// @dev The bound has to hold across the whole curve, not just where it was first noticed. The
    /// reserve is what decides how far the borrow moves utilization: at zero the draw pins it at
    /// one ray and the projection is exact, while a deep reserve barely moves it and the discount
    /// carries real slack. Both ends and everything between have to stay inside the limit.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_fixedBorrowNeverOutrunsItsLimit(uint96 rawReserve, uint32 rawTerm, uint8 rawSlope) public {
        FixedMarket market = _fixedMarketOnSlope(bound(rawSlope, 0, 20) * 0.1e27);

        uint256 reserve = bound(rawReserve, 0, 20_000e18);
        if (reserve > 0) _depositStable(makeAddr("saver"), reserve);
        uint256 term = bound(rawTerm, capConfig.defaultMinimumTermLimit, capConfig.defaultMaximumTermLimit);

        uint256 limit = market.creditLimit();
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, type(uint256).max, term);

        assertLe(market.debt(id), limit, "debt must fit the limit at every reserve, term and slope");
        assertGe(market.healthiness(), 1e27, "and must never arrive liquidatable");
    }

    /// @dev A fixed market whose liquidity rate genuinely responds to utilization, on the tightest
    /// ltv the buffer allows so that the ltv-to-lt corridor is as thin as governance can make it.
    /// The steepness of the second slope is what scales the rate move a borrow causes.
    /// @param slope1 The post-kink slope of the liquidity curve
    function _fixedMarketOnSlope(uint256 slope1) internal returns (FixedMarket market) {
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: slope1, kink: 0.8e27 })
        );

        (address marketAddr, address tranche,) = _createFixedMarket("fixed");
        market = FixedMarket(marketAddr);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        // let the collateral-backed limit bind rather than the flat cap
        market.setFixedCreditLimit(type(uint256).max);
        market.setLtv(capConfig.defaultLt - capConfig.defaultBuffer);
        _fundTranche(tranche, alice, 10_000e18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // A FIXED PREMIUM CANNOT BE PRICED OFF A SINGLE BLOCK'S UTILIZATION
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev {Stablecoin-deposit} and {Stablecoin-redeem} are permissionless and round-trip at par
    /// with no fee, so utilization could be moved and moved back inside one transaction for the
    /// cost of the gas. A floating loan shrugs that off because its index re-accrues, but a fixed
    /// loan mints its whole term's premium upfront at whatever it reads in that block, so a single
    /// observation was charged for up to a month. Pricing off the time-weighted supplies closes it:
    /// a reading that has stood for no time carries no weight.
    function test_aFlashDepositCannotSuppressAFixedPremium() public {
        FixedMarket market = _fixedMarketOnSlope(0.9e27);
        _depositStable(makeAddr("saver"), 1_000e18);
        vm.warp(block.timestamp + 2 hours);

        uint256 honest = _quotedPremium(market);

        // the borrower flashes in a deposit deep enough to halve utilization, borrows against the
        // suppressed reading, and takes every wei back out again — all in one transaction
        _depositStable(defaultBorrower, 4_000e18);
        uint256 manipulated = _quotedPremium(market);

        emit log_named_uint("honest premium     ", honest);
        emit log_named_uint("manipulated premium", manipulated);

        assertGt(honest, 0, "there is a premium to suppress");
        assertEq(manipulated, honest, "a deposit that has stood for no time may not move the price");
    }

    /// @dev And the mirror, which is the direction that lets a third party grief rather than the
    /// borrower save: burning supply spikes utilization, and the victim locks that in for a month.
    function test_aFlashRedeemCannotInflateAVictimsFixedPremium() public {
        FixedMarket market = _fixedMarketOnSlope(0.9e27);
        address saver = makeAddr("saver");
        _depositStable(saver, 4_000e18);
        vm.warp(block.timestamp + 2 hours);

        uint256 honest = _quotedPremium(market);

        vm.prank(saver);
        stablecoin.redeem(3_000e18, saver, saver);
        uint256 griefed = _quotedPremium(market);

        emit log_named_uint("honest premium", honest);
        emit log_named_uint("griefed premium", griefed);

        assertEq(griefed, honest, "a redemption that has stood for no time may not move it either");
    }

    /// @dev Smoothing must not become a way to never pay. A shift that is real, and held, ends up
    /// fully priced.
    ///
    /// "Fully" takes several windows rather than one. The averaging period is a time constant: the
    /// average closes a fixed fraction of the remaining distance per second, which is what stops
    /// the result depending on how often the accrual is run, and the price of that is that no
    /// finite wait closes the distance exactly. One period gets about 63% of the way.
    function test_aSustainedShiftIsPricedInFullOnceTheAverageHasSettled() public {
        FixedMarket market = _fixedMarketOnSlope(0.9e27);
        _depositStable(makeAddr("saver"), 1_000e18);
        vm.warp(block.timestamp + 2 hours);

        uint256 before = _quotedPremium(market);

        _depositStable(defaultBorrower, 4_000e18);
        assertEq(_quotedPremium(market), before, "not felt at all in the block it lands");

        vm.warp(block.timestamp + irm.averagingPeriod() / 2);
        uint256 halfway = _quotedPremium(market);

        vm.warp(block.timestamp + 20 * irm.averagingPeriod());
        uint256 settled = _quotedPremium(market);

        emit log_named_uint("before ", before);
        emit log_named_uint("halfway", halfway);
        emit log_named_uint("settled", settled);

        assertLt(halfway, before, "a held deposit starts being felt as time passes");
        assertLt(settled, halfway, "and keeps being felt");
        assertApproxEqRel(
            settled,
            _premiumAt(market, stablecoin.utilizationRateAfterMint(QUOTED_PRINCIPAL)),
            0.001e18,
            "until the average has fully caught up with the live reading"
        );
    }

    /// @dev The averaging must not swallow the borrower's own draw. Utilization is smoothed, but
    /// the principal about to be minted is added to the smoothed supplies rather than waiting an
    /// hour to be noticed, so a borrower still pays for the crowding they cause.
    function test_theBorrowersOwnMintStillRaisesTheirPremium() public {
        FixedMarket market = _fixedMarketOnSlope(0.9e27);
        _depositStable(makeAddr("saver"), 1_000e18);
        vm.warp(block.timestamp + 2 hours);

        (uint256 withoutLiquidity, uint256 withoutUnderwriter) = market.premiumForExtension(QUOTED_PRINCIPAL, 30 days);
        (uint256 withLiquidity, uint256 withUnderwriter) = market.premiumForBorrow(QUOTED_PRINCIPAL, 30 days);

        emit log_named_uint("premium ignoring the draw", withoutLiquidity + withoutUnderwriter);
        emit log_named_uint("premium counting the draw", withLiquidity + withUnderwriter);

        assertGt(withLiquidity, withoutLiquidity, "the draw's own effect on utilization is still charged");
    }

    /// @dev A borrow of this size against the reserves used above lands above the kink, which is
    /// where the curve is steep enough for a manipulation to be worth attempting.
    uint256 internal constant QUOTED_PRINCIPAL = 1_000e18;

    /// @dev What a 30 day borrow of {QUOTED_PRINCIPAL} would be charged as things stand
    function _quotedPremium(FixedMarket market) internal view returns (uint256 premium) {
        (uint256 liquidity, uint256 underwriter) = market.premiumForBorrow(QUOTED_PRINCIPAL, 30 days);
        premium = liquidity + underwriter;
    }

    /// @dev The same premium recomputed from a utilization supplied directly, to check what the
    /// average settles on rather than only that it moved
    function _premiumAt(FixedMarket market, uint256 utilization) internal view returns (uint256 premium) {
        (uint256 base, uint256 slope0, uint256 slope1, uint256 kink) = irm.liquiditySlopes();
        uint256 rate = utilization <= kink
            ? base + slope0 * utilization / kink
            : base + slope0 + slope1 * (utilization - kink) / (1e27 - kink);
        rate = rate * irm.termMultiplier(uint256(30 days) * 1e27 / market.maximumTermLimit()) / 1e27;
        premium = QUOTED_PRINCIPAL * (rate + irm.underwriterRate(address(market))) * 30 days / (1e27 * 365 days);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PARAMETER AND INTERFACE HARDENING
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev `deallocate` clamped the request to the tranche's unlocked supply but not to the
    /// underwriter's own holding. Since unlocked supply is a tranche-wide figure, any other
    /// depositor's shares raised the ceiling above what the underwriter actually held, and an
    /// oversized request died inside the tranche's burn instead of coming back as a short fill the
    /// way {deallocateAsync} does.
    function test_deallocateShortFillsRatherThanReverting() public {
        Underwriter uw = _deployUnderwriter();
        MarketBundle memory b = _createReadyMarket("m");
        uw.addTranche(b.tranche0Addr);
        uw.setDefaultTranche(b.tranche0Addr);
        _admitDepositor(address(b.tranche0), address(uw));

        _fundUnderwriter(address(uw), alice, 400e18);
        // a second depositor, so unlocked supply is no longer the binding constraint
        _fundTranche(b.tranche0Addr, bob, 600e18);

        uint256 held = b.tranche0.balanceOf(address(uw));
        assertGt(b.tranche0.instantUnlockedSupply(), held * 2, "the old ceiling is above the holding");

        uint256 deallocated = uw.deallocate(b.tranche0Addr, held * 2);
        assertEq(deallocated, held, "clamped to the holding");
        assertEq(b.tranche0.balanceOf(address(uw)), 0, "position fully exited");
        assertEq(uw.debt(b.tranche0Addr), 0, "and the recorded debt went with it");
    }

    /// @dev `initialize` accepted a liquidation bonus `setLiquidationBonus` would refuse and an
    /// inverted multiplier band. The band has no setter at all, so an inverted one left
    /// {updateMarketMultiplier} unsatisfiable with nothing able to repair it.
    function test_irmInitRejectsWhatTheSettersReject() public {
        InterestRateModel impl = new InterestRateModel();

        vm.expectRevert(IInterestRateModel.InvalidLiquidationBonus.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                InterestRateModel.initialize,
                (address(accessManager), address(stablecoin), 1e27, 2e27, 1e27, 0.2e27, 1 hours)
            )
        );

        vm.expectRevert(IInterestRateModel.InvalidMultiplier.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                InterestRateModel.initialize,
                (address(accessManager), address(stablecoin), 2e27, 1e27, 1e27, 0.05e27, 1 hours)
            )
        );

        // a period of zero would divide by nothing in the weighting, and any period short enough to
        // fit inside a transaction is spot pricing wearing a time-weighted name
        vm.expectRevert(IInterestRateModel.InvalidAveragingPeriod.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                InterestRateModel.initialize,
                (address(accessManager), address(stablecoin), 1e27, 2e27, 1e27, 0.05e27, 0)
            )
        );

        vm.expectRevert(IInterestRateModel.InvalidAveragingPeriod.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                InterestRateModel.initialize,
                (address(accessManager), address(stablecoin), 1e27, 2e27, 1e27, 0.05e27, 8 days)
            )
        );
    }

    /// @dev Utilization is a ratio of supplies and so never passes one ray, which makes a kink
    /// above it unreachable: the second slope goes dead and the curve tops out below where it was
    /// meant to. A kink typed as 8e27 rather than 0.8e27 would have under-charged silently.
    function test_kinkAboveFullUtilizationIsRejected() public {
        vm.expectRevert(IInterestRateModel.InvalidSlopes.selector);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 8e27 })
        );

        // the boundary itself stays legal, because utilization can sit at exactly one ray
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 1e27 })
        );
    }

    /// @dev `setLtv` rejects `ltv + buffer > lt` while `setBuffer` only checks `buffer < lt`, so
    /// the buffer can be raised into a pair `setLtv` would have refused. That asymmetry is
    /// deliberate and this pins the reason: every direction it opens up locks more capital per unit
    /// of debt, so a guardian reaching for it cannot loosen anything, and the one bound that does
    /// matter — the divisor in `lockedValue` — still bites.
    function test_raisingBufferPastLtvIsAPermittedTightening() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        uint256 lockedBefore = b.market.lockedValue(b.tranche0Addr);
        uint256 lt = b.market.lt();

        b.market.setBuffer(lt - b.market.ltv() + 0.01e27);
        assertGt(b.market.ltv() + b.market.buffer(), lt, "the pair setLtv would reject");
        assertGt(b.market.lockedValue(b.tranche0Addr), lockedBefore, "and it locks more, never less");

        vm.expectRevert(IBaseMarket.InvalidBuffer.selector);
        b.market.setBuffer(lt);
    }

    /// @dev {Tranche-claim} emits and returns; the underwriter's equivalent moved cUSD and said
    /// nothing, leaving no way to index a depositor's premium.
    function test_underwriterClaimIsObservable() public {
        Underwriter uw = _deployUnderwriter();
        MarketBundle memory b = _createReadyMarket("m");
        uw.addTranche(b.tranche0Addr);
        uw.setDefaultTranche(b.tranche0Addr);
        _admitDepositor(address(b.tranche0), address(uw));

        _fundUnderwriter(address(uw), alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        // the tranche vests before it can be reported, and the underwriter vests after
        vm.warp(block.timestamp + 7 hours);
        uw.report(b.tranche0Addr);
        vm.warp(block.timestamp + 7 hours);
        uw.report(b.tranche0Addr);

        uint256 expected = uw.claimable(alice);
        assertGt(expected, 0, "there is premium to claim");

        vm.expectEmit(true, true, false, true, address(uw));
        emit IPremiumVesting.Claimed(alice, alice, expected);
        vm.prank(alice);
        uint256 claimed = uw.claim(alice);

        assertEq(claimed, expected, "the call reports what it paid");
        assertEq(stablecoin.balanceOf(alice), claimed, "and that is what arrived");
    }
}
