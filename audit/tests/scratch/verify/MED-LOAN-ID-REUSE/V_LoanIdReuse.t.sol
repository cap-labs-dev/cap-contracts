// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FixedMarket } from "../../../../../contracts/cap/market/FixedMarket.sol";
import { IFixedMarket } from "../../../../../contracts/interfaces/IFixedMarket.sol";
import { IInterestRateModel } from "../../../../../contracts/interfaces/IInterestRateModel.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// Adversarial verification of MED-LOAN-ID-REUSE (D9).
/// Production wiring (Registry._configureMarketRoles): extend = owner operator role, extendAdmin = KEEPER,
/// borrow/borrowMore = borrower operator role. CapDeployer makes address(this) the owner AND grants it KEEPER,
/// so every privileged call below is pranked explicitly to the single role being tested.
contract V_LoanIdReuse is CapDeployer {
    FixedMarket market;
    address tranche0;
    address owner = makeAddr("owner-only");
    address keeper = makeAddr("keeper-only");

    function setUp() public {
        _deployCap();
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        irm.setTermMultiplierSlope(1e27);
        _assignOperator(owner);
        uint256[] memory w = new uint256[](1);
        w[0] = 1e27;
        (address m, address[] memory ts) =
            registry.createFixedMarket(_uniformAssets(1), w, "X", owner, defaultBorrower, 30 days, 1 days, 1 days);
        market = FixedMarket(m);
        tranche0 = ts[0];
        // owner-role setters, pranked as the owner only
        vm.startPrank(owner);
        market.setLtv(capConfig.defaultLtv);
        market.setMarketMultiplier(1e27);
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        vm.stopPrank();
        // GUARDIAN / GOVERNOR = address(this)
        market.setBuffer(capConfig.defaultBuffer);
        market.setLt(capConfig.defaultLt);
        market.setTargetHealth(capConfig.defaultTargetHealth);
        market.setFixedCreditLimit(type(uint256).max);
        _grantKeeper(keeper);
        // fund the tranche; depositor admission is the owner's (role admin) call
        address uw = makeAddr("uw");
        uint256 amt = 40_000_000e18;
        collateral.mint(uw, amt);
        vm.startPrank(uw);
        collateral.approve(address(vault), amt);
        vault.deposit(address(collateral), amt, uw);
        vault.setOperator(tranche0, true);
        vm.stopPrank();
        uint64 depRole = _depositorRole(tranche0);
        vm.prank(owner);
        accessManager.grantRole(depRole, uw, 0);
        vm.prank(uw);
        Tranche(tranche0).deposit(amt, uw);
        _depositStable(makeAddr("saver"), 40_000_000e18);
    }

    // ── (a) which roles are needed ───────────────────────────────────────────────────────────

    function test_borrowerAloneCannotSeedPhantomId() public {
        uint256 id = market.loanCount();
        vm.startPrank(defaultBorrower);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, defaultBorrower));
        market.extend(id, 1 days);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, defaultBorrower));
        market.extendAdmin(id, 1 days);
        // expiry 0 reads as expired, so the borrower's own path is closed
        vm.expectRevert(IFixedMarket.LoanExpired.selector);
        market.borrowMore(id, defaultBorrower, 1e18);
        vm.stopPrank();
    }

    function test_ownerAloneCannotDraw() public {
        uint256 id = market.loanCount();
        vm.startPrank(owner);
        market.extend(id, 1 days); // seeds, zero premium
        assertEq(market.expiry(id), block.timestamp + 1 days);
        assertEq(market.debt(id), 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        market.borrowMore(id, owner, 1e18);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, owner));
        market.borrow(owner, 1e18, 30 days);
        vm.stopPrank();
    }

    function test_keeperCanSeedInsteadOfOwner_noHealthCheck() public {
        // foundry's clock starts at 1 < grace; any real chain is past `grace` since the epoch
        vm.warp(1_800_000_000);
        uint256 id = market.loanCount();
        vm.prank(keeper);
        uint256 ext = market.extendAdmin(id, 1 days); // expiry 0 + grace <= now, so not "in grace"
        assertEq(market.expiry(id), block.timestamp + 1 days);
        assertEq(ext, 1 days + block.timestamp, "arrears since the epoch are folded into the extension");
        assertEq(market.debt(id), 0);
        // borrower can now proceed exactly as with the owner-seeded id
        vm.startPrank(defaultBorrower);
        market.borrowMore(id, defaultBorrower, 1_000e18);
        (uint256 newId,) = market.borrow(defaultBorrower, 1, 30 days);
        vm.stopPrank();
        assertEq(newId, id);
        assertEq(market.expiry(id), block.timestamp + 30 days);
    }

    // ── (b)/(c) arithmetic and who loses, at $10M ─────────────────────────────────────────────

    function test_quantify_10M_splitByRecipient() public {
        uint256 P = 10_000_000e18;
        uint256 id = market.loanCount();
        (uint256 hl, uint256 hu) = market.premiumForBorrow(P, 30 days);
        emit log_named_uint("honest 30d liquidity premium (stcUSD)", hl);
        emit log_named_uint("honest 30d underwriter premium (tranche)", hu);

        uint256 stcBefore = stablecoin.balanceOf(capConfig.stablecoinYield);
        uint256 trBefore = stablecoin.balanceOf(tranche0);

        vm.prank(owner);
        market.extend(id, 1 days);
        vm.startPrank(defaultBorrower);
        (uint256 got) = market.borrowMore(id, defaultBorrower, P);
        assertEq(got, P, "credit check did not clip the draw");
        (uint256 newId,) = market.borrow(defaultBorrower, 1, 30 days);
        vm.stopPrank();
        assertEq(newId, id);
        assertEq(market.expiry(id), block.timestamp + 30 days);

        uint256 paidL = stablecoin.balanceOf(capConfig.stablecoinYield) - stcBefore;
        uint256 paidU = stablecoin.balanceOf(tranche0) - trBefore;
        emit log_named_uint("paid liquidity premium (stcUSD)", paidL);
        emit log_named_uint("paid underwriter premium (tranche)", paidU);
        emit log_named_uint("stcUSD shortfall", hl - paidL);
        emit log_named_uint("tranche shortfall", hu - paidU);
        emit log_named_uint("avoided bps of honest total", ((hl + hu) - (paidL + paidU)) * 10_000 / (hl + hu));

        // debt and credit-backed supply agree to the wei: nothing unbacked, purely an underpayment
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "I3 intact");
        assertEq(market.totalDebt(), P + 1 + paidL + paidU);

        // the loan really is live for the full term
        vm.warp(block.timestamp + 29 days);
        vm.prank(defaultBorrower);
        market.borrowMore(id, defaultBorrower, 1); // still live at day 29 (1 day remaining >= min term)
    }

    /// The owner can already zero the underwriter premium openly. What is left after that lever is the
    /// liquidity premium, which minimumMarketMultiplier (1e27) stops the owner from lowering by any
    /// legitimate call — that is the loss no configuration can reproduce.
    function test_ownerOpenLever_underwriterRateZero_leavesLiquidityPremium() public {
        uint256 P = 10_000_000e18;
        vm.prank(owner);
        market.setUnderwriterRate(0);
        (uint256 hl, uint256 hu) = market.premiumForBorrow(P, 30 days);
        assertEq(hu, 0);
        assertGt(hl, 0);
        vm.prank(owner);
        vm.expectRevert(); // below minimumMarketMultiplier
        market.setMarketMultiplier(0.5e27);
        emit log_named_uint("liquidity premium owner cannot waive (30d, 10M)", hl);
    }

    // ── repeatability: roll the whole position every month for a day's premium ───────────────

    function test_repeatable_monthlyRollover() public {
        uint256 P = 10_000_000e18;
        uint256 id = market.loanCount();
        vm.prank(owner);
        market.extend(id, 1 days);
        vm.startPrank(defaultBorrower);
        market.borrowMore(id, defaultBorrower, P);
        market.borrow(defaultBorrower, 1, 30 days);
        vm.stopPrank();
        uint256 paidFirst = market.totalDebt() - (P + 1);

        // day 29: seed the next id, draw on it, repay the old id with the fresh cUSD, re-term
        vm.warp(block.timestamp + 29 days);
        uint256 id2 = market.loanCount();
        assertEq(id2, id + 1);
        vm.prank(owner);
        market.extend(id2, 1 days);
        uint256 debtBefore = market.totalDebt();
        vm.startPrank(defaultBorrower);
        // credit headroom is 20M at ltv 0.5, so migrate in 2M chunks: draw on id2, repay id
        for (uint256 i; i < 5; ++i) {
            market.borrowMore(id2, defaultBorrower, P / 5);
            market.repay(id, P / 5);
        }
        (uint256 newId,) = market.borrow(defaultBorrower, 1, 30 days);
        vm.stopPrank();
        assertEq(newId, id2);
        assertEq(market.expiry(id2), block.timestamp + 30 days);
        uint256 paidSecond = market.totalDebt() - debtBefore - 1; // draw and repay net to zero; the rest is premium
        (uint256 hl, uint256 hu) = market.premiumForBorrow(P, 30 days);
        emit log_named_uint("honest 30d premium", hl + hu);
        emit log_named_uint("round 1 premium", paidFirst);
        emit log_named_uint("round 2 premium", paidSecond);
        assertLt(paidSecond * 10, hl + hu, "every month costs under a tenth of the honest premium");
    }

    /// The proposed fix (`id >= loanCount` revert) would block step 1; check nothing legitimate touches an
    /// id before borrow creates it, by confirming loanCount is the only id source in normal flow.
    function test_honestPathsAllChargeFullTerm() public {
        uint256 P = 10_000_000e18;
        (uint256 hl, uint256 hu) = market.premiumForBorrow(P, 30 days);
        // honest alternative A: borrow at min term then extend 29 days — extend charges the whole debt
        vm.prank(defaultBorrower);
        (uint256 id,) = market.borrow(defaultBorrower, P, 1 days);
        uint256 afterBorrow = market.debt(id);
        vm.prank(owner);
        market.extend(id, 29 days);
        uint256 total = market.debt(id) - P;
        emit log_named_uint("honest 30d premium", hl + hu);
        emit log_named_uint("borrow 1d + extend 29d premium", total);
        // extend charges on the WHOLE debt for the WHOLE extension (the liquidity leg is priced at the
        // pre-mint time-weighted utilization, which is why this is below the after-mint quote); what
        // matters here is that no honest path re-terms existing debt for free
        assertGt(total - (afterBorrow - P), hu * 29 / 30, "extend charged the full debt for 29 days");
    }
}
