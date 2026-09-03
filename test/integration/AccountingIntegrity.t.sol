// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IFloatingMarket } from "../../contracts/interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapRoles } from "../../contracts/utils/CapRoles.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { MockIRM } from "../shared/mocks/MockIRM.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { stdError } from "forge-std/StdError.sol";

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
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", "", address(mockIrm))
                )
            )
        );
        bytes4[] memory sels = new bytes4[](3);
        sels[0] = Stablecoin.mintCreditBacked.selector;
        sels[1] = Stablecoin.burnCreditBacked.selector;
        sels[2] = Stablecoin.recognizeBadDebt.selector;
        accessManager.setTargetFunctionRole(address(scoin), sels, CapRoles.MINTER);
        accessManager.grantRole(CapRoles.MINTER, address(this), 0);

        usdc.mint(address(this), 10_000e18);
        usdc.approve(address(scoin), type(uint256).max);
    }

    function _writeOffCredit(uint256 amount) internal {
        scoin.mintCreditBacked(makeAddr("defaulted"), amount);
        scoin.recognizeBadDebt(amount);
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
        b.tranche0.setWhitelist(address(uw), true);

        // honest LP funds the underwriter and it underwrites a borrow
        _fundUnderwriter(address(uw), alice, 1_000e18);
        _fundTranche(b.tranche1Addr, bob, 100e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        // let the tranche's own vesting finish so report() pulls the whole premium across
        vm.warp(block.timestamp + 7 hours);
        uw.report(b.tranche0Addr);

        uint256 buffered = stablecoin.balanceOf(address(uw));
        assertGt(buffered, 0, "there is premium at stake");
        assertEq(uw.vestedPremium(), buffered, "the whole buffer is vesting");

        // alice queues her whole position, so activeSupply hits zero
        uint256 aliceShares = uw.balanceOf(alice);
        vm.prank(alice);
        uw.requestRedeem(aliceShares, alice, alice);
        assertEq(uw.activeSupply(), 0, "vault is idle");

        // three of the six hours pass against nobody
        vm.warp(block.timestamp + 3 hours);

        _fundVault(address(this), 1);
        _admitDepositor(address(uw), address(this));
        vault.setOperator(address(uw), true);
        uw.deposit(1, address(this));

        assertEq(uw.claimable(address(this)), 0, "the window it missed is not payable to it");
        assertEq(uw.vestedReward(), buffered, "and none of it was burned either");

        // it earns only as the clock runs, at the original rate
        vm.warp(block.timestamp + 3 hours);
        assertApproxEqAbs(uw.claimable(address(this)), buffered / 2, 1e6, "half the remaining drip");

        vm.warp(block.timestamp + 3 hours);
        assertApproxEqAbs(uw.claimable(address(this)), buffered, 1e6, "and the rest once it is due");

        uw.claim();
        assertApproxEqAbs(stablecoin.balanceOf(address(this)), buffered, 1e6, "payable in full");
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
        assertEq(b.tranche0.vested(), buffered, "the whole buffer is vesting");

        // alice queues out, so the tranche has no active supply
        uint256 aliceShares = b.tranche0.balanceOf(alice);
        vm.prank(alice);
        b.tranche0.requestRedeem(aliceShares, alice, alice);
        assertEq(b.tranche0.activeSupply(), 0, "tranche is idle");

        // the whole epoch runs out against nobody
        uint256 idleEnd = b.tranche0.periodEnd();
        vm.warp(idleEnd);

        _fundVault(address(this), 1);
        b.tranche0.setWhitelist(address(this), true);
        vault.setOperator(b.tranche0Addr, true);
        b.tranche0.deposit(1, address(this));

        assertEq(b.tranche0.claimable(address(this)), 0, "the epoch it missed is not payable to it");
        assertEq(b.tranche0.periodEnd(), idleEnd + 6 hours, "the epoch slid instead of collapsing");
        assertEq(b.tranche0.vested(), buffered, "with nothing burned");

        vm.warp(block.timestamp + 3 hours);
        assertApproxEqAbs(b.tranche0.claimable(address(this)), buffered / 2, 1e6, "half the slid epoch");

        vm.warp(block.timestamp + 3 hours);
        assertApproxEqAbs(b.tranche0.claimable(address(this)), buffered, 1e6, "and the rest at the new end");

        b.tranche0.claim(address(this));
        assertApproxEqAbs(stablecoin.balanceOf(address(this)), buffered, 1e6, "payable in full");
    }

    /// @dev The other half of it: re-vesting on top of an idle window used to strand the idle part
    /// for good. `setVestingPeriod` rebuilds the lump from {PremiumVesting-locked}, which counts
    /// only what is not yet due and so skips time that elapsed without releasing. Under the frozen
    /// clock that was the whole idle window, and since `_storedPremiumBalance` still counted it, no
    /// later notify could pick it back up. Sliding leaves `locked` equal to the full un-released
    /// remainder, so re-vesting carries all of it.
    function test_trancheIdleWindowSurvivesReVesting() public {
        MarketBundle memory b = _createReadyMarket("m");
        _fundTranche(b.tranche0Addr, alice, 1_000e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        uint256 buffered = b.tranche0.vested();

        uint256 aliceShares = b.tranche0.balanceOf(alice);
        vm.prank(alice);
        b.tranche0.requestRedeem(aliceShares, alice, alice);
        assertEq(b.tranche0.activeSupply(), 0, "tranche is idle");

        // half the epoch elapses against nobody, then the schedule is re-vested over it
        vm.warp(block.timestamp + 3 hours);
        b.tranche0.setVestingPeriod(6 hours);

        assertEq(b.tranche0.vested(), buffered, "the idle half is carried, not written off");
        assertEq(stablecoin.balanceOf(b.tranche0Addr), buffered, "and it is all still held");
    }

    /// @dev The underwriter mirror of the above. Here {report} is the reachable re-vest: it is a
    /// curator call with no supply precondition, and it rebuilds `vestedPremium` from
    /// {vestedReward}. Sliding `lastReported` is what makes that read back the un-accrued remainder
    /// rather than only the not-yet-due part.
    function test_underwriterIdleWindowSurvivesTheNextReport() public {
        Underwriter uw = _deployUnderwriter();
        MarketBundle memory b = _createReadyMarket("m");
        uw.addTranche(b.tranche0Addr);
        uw.setDefaultTranche(b.tranche0Addr);
        b.tranche0.setWhitelist(address(uw), true);

        _fundUnderwriter(address(uw), alice, 1_000e18);
        _fundTranche(b.tranche1Addr, bob, 100e18);

        vm.prank(defaultBorrower);
        b.market.borrow(defaultBorrower, 200e18);

        vm.warp(block.timestamp + 30 days);
        b.market.chargePremium();
        vm.warp(block.timestamp + 7 hours);
        uw.report(b.tranche0Addr);

        uint256 buffered = uw.vestedPremium();
        assertGt(buffered, 0, "there is premium at stake");

        uint256 aliceShares = uw.balanceOf(alice);
        vm.prank(alice);
        uw.requestRedeem(aliceShares, alice, alice);
        assertEq(uw.activeSupply(), 0, "vault is idle");

        // half the schedule elapses against nobody, then a report re-vests over it
        vm.warp(block.timestamp + 3 hours);
        uw.report(b.tranche0Addr);

        assertEq(uw.vestedPremium(), buffered, "the idle half is carried, not written off");
        assertEq(stablecoin.balanceOf(address(uw)), buffered, "and it is all still held");
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
        b.tranche0.setWhitelist(address(uw), true);

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
                InterestRateModel.initialize, (address(accessManager), address(stablecoin), 1e27, 2e27, 1e27, 0.2e27)
            )
        );

        vm.expectRevert(IInterestRateModel.InvalidMultiplier.selector);
        _deployProxy(
            address(impl),
            abi.encodeCall(
                InterestRateModel.initialize, (address(accessManager), address(stablecoin), 2e27, 1e27, 1e27, 0.05e27)
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
        b.tranche0.setWhitelist(address(uw), true);

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

        vm.expectEmit(true, false, false, true, address(uw));
        emit IUnderwriter.Claimed(alice, expected);
        vm.prank(alice);
        uint256 claimed = uw.claim();

        assertEq(claimed, expected, "the call reports what it paid");
        assertEq(stablecoin.balanceOf(alice), claimed, "and that is what arrived");
    }
}
