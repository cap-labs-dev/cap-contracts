// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { FixedMarket } from "../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../contracts/cap/market/FloatingMarket.sol";
import { IBaseMarket } from "../../../contracts/interfaces/IBaseMarket.sol";
import { IERC7540AsyncRedeem } from "../../../contracts/interfaces/IERC7540AsyncRedeem.sol";
import { IPremiumVesting } from "../../../contracts/interfaces/IPremiumVesting.sol";
import { IWrapper } from "../../../contracts/interfaces/IWrapper.sol";
import { CapDeployer } from "../../shared/CapDeployer.sol";
import { MockAeraVault } from "../../shared/mocks/MockAeraVault.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Vm } from "forge-std/Vm.sol";

/// @notice Finite-budget, closed-system handler. See ../README.md for the property specification.
/// @dev No low-level catch-all calls, state surgery, or implicit accounting checkpoints.
contract ProtocolHandler is CapDeployer {
    struct Calls {
        uint256 attempted;
        uint256 succeeded;
        uint256 skipped;
        uint256 expectedReverts;
    }

    struct GhostReceipt {
        address token;
        uint256 id;
        address controller;
        uint256 shares;
    }

    mapping(bytes4 => Calls) public calls;
    address[3] public actors;
    FloatingMarket public floating;
    FixedMarket public fixedMarket;
    Underwriter public pool;
    Tranche[4] public ts;
    IERC7540AsyncRedeem[6] public exits;
    MockAeraVault public reserve;
    GhostReceipt[] public receipts;
    mapping(address => mapping(uint256 => uint256)) internal receiptIndex;
    mapping(address => uint256) public ghostFunded;
    mapping(address => uint256) public ghostPaid;
    mapping(address => uint256) public ghostPrincipal;
    mapping(address => uint256) public ghostPremium;
    mapping(address => uint256) public ghostRepaid;
    mapping(address => uint256) public ghostWrittenOff;
    mapping(address => bool) public ghostKilled;
    uint256[2] public ghostMarks;
    uint256 public partialSettlements;
    uint256 public lossActions;
    uint256 public positiveClaims;
    uint256 public unwinds;
    uint256 public initialTimestamp;
    uint256 public collateralCreated;
    bytes32 public sequenceHash;

    modifier counted() {
        calls[msg.sig].attempted++;
        sequenceHash = keccak256(abi.encode(sequenceHash, msg.data));
        vm.recordLogs();
        _;
        _harvest();
    }

    constructor() {
        _deployCap();
        initialTimestamp = block.timestamp;
        (address m, address a, address b) = _createMarket("Stateful floating");
        floating = FloatingMarket(m);
        ts[0] = Tranche(a);
        ts[1] = Tranche(b);
        (m, a, b) = _createFixedMarket("Stateful fixed");
        fixedMarket = FixedMarket(m);
        ts[2] = Tranche(a);
        ts[3] = Tranche(b);
        // _createMarket applies risk defaults, but deliberately does not install rates.
        _configureMarketRates(floating);
        fixedMarket.setUnderwriterRate(capConfig.defaultUnderwriterRate);
        irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        _setMaxCapital(floating, 100_000e18);
        _setMaxCapital(IBaseMarket(address(fixedMarket)), 100_000e18);
        pool = _deployUnderwriter();
        reserve = new MockAeraVault();
        stablecoin.setReserveVault(address(reserve));
        for (uint256 j; j < 4; ++j) {
            exits[j] = IERC7540AsyncRedeem(address(ts[j]));
        }
        exits[4] = IERC7540AsyncRedeem(address(pool));
        exits[5] = IERC7540AsyncRedeem(address(stablecoin));
        for (uint256 j; j < 2; ++j) {
            _admitDepositor(address(ts[j]), address(pool));
            pool.addTranche(address(ts[j]));
        }
        // All capital enters through the ordinary reserve and custody deposit paths.
        for (uint256 i; i < 3; ++i) {
            address actor = makeAddr(string.concat("stateful actor ", vm.toString(i)));
            actors[i] = actor;
            collateral.mint(actor, 1_000_000e18);
            collateralCreated += 1_000_000e18;
            cusdUnderlying.mint(actor, 1_000_000e18);
            vm.startPrank(actor);
            collateral.approve(address(vault), type(uint256).max);
            cusdUnderlying.approve(address(stablecoin), type(uint256).max);
            stablecoin.approve(address(wrapper), type(uint256).max);
            vault.deposit(address(collateral), 100_000e18, actor);
            stablecoin.deposit(100_000e18, actor);
            stablecoin.optIn();
            for (uint256 j; j < 4; ++j) {
                vault.setOperator(address(ts[j]), true);
            }
            vault.setOperator(address(pool), true);
            vm.stopPrank();
            for (uint256 j; j < 5; ++j) {
                _admitDepositor(address(exits[j]), actor);
                vm.startPrank(actor);
                exits[j].deposit(10_000e18, actor);
                IPremiumVesting(address(exits[j])).optIn();
                vm.stopPrank();
            }
        }
        _depositStable(defaultBorrower, 10_000_000e18);
        _depositStable(defaultLiquidator, 10_000_000e18);
        vm.recordLogs();
        pool.allocate(address(ts[0]), 5000e18);
        pool.allocate(address(ts[1]), 5000e18);
        _syncMark(0);
        _syncMark(1);
        _harvest();
    }

    function reserveDeposit(uint256 who, uint256 raw) external counted {
        address actor = actors[who % 3];
        uint256 amount = _amount(raw, cusdUnderlying.balanceOf(actor));
        if (amount == 0) {
            _skip();
            return;
        }
        uint256 before = stablecoin.balanceOf(actor);
        vm.prank(actor);
        assertEq(stablecoin.deposit(amount, actor), amount, "reserve deposit at par");
        assertEq(stablecoin.balanceOf(actor) - before, amount);
        _success();
    }

    function custody(uint256 who, uint256 raw, bool withdraw_) external counted {
        address actor = actors[who % 3];
        uint256 available = withdraw_ ? vault.balanceOf(actor, address(collateral)) : collateral.balanceOf(actor);
        uint256 amount = _amount(raw, available);
        if (amount == 0) {
            _skip();
            return;
        }
        vm.prank(actor);
        if (withdraw_) vault.withdraw(address(collateral), amount, actor);
        else vault.deposit(address(collateral), amount, actor);
        _success();
    }

    function deposit(uint256 which, uint256 who, uint256 raw) external counted {
        uint256 k = which % 5;
        address actor = actors[who % 3];
        if (exits[k].maxDeposit(actor) == 0) {
            _skip();
            return;
        }
        if (!_mayDeposit(address(exits[k]), actor)) {
            _skip();
            return;
        }
        uint256 amount = _amount(raw, vault.balanceOf(actor, address(collateral)));
        if (amount == 0) {
            _skip();
            return;
        }
        vm.prank(actor);
        exits[k].deposit(amount, actor);
        _success();
    }

    function transferShares(uint256 which, uint256 who, uint256 raw) external counted {
        IERC7540AsyncRedeem token = exits[which % 6];
        address from = actors[who % 3];
        address to = actors[(who % 3 + 1) % 3];
        uint256 amount = _amount(raw, token.balanceOf(from));
        if (amount == 0) {
            _skip();
            return;
        }
        vm.prank(from);
        token.transfer(to, amount);
        _success();
    }

    function wrap(uint256 who, uint256 raw, bool unwrap_) external counted {
        address actor = actors[who % 3];
        uint256 available = unwrap_ ? wrapper.balanceOf(actor) : stablecoin.balanceOf(actor);
        uint256 amount = _amount(raw, available);
        if (amount == 0 || (!unwrap_ && wrapper.totalSupply() == 0 && amount <= DEAD_SHARES)) {
            _skip();
            return;
        }
        // Accrued yield can make a positive dust deposit round below one share.
        if (!unwrap_ && wrapper.previewDeposit(amount) == 0) {
            vm.expectRevert(IWrapper.ZeroShares.selector);
            vm.prank(actor);
            wrapper.deposit(amount, actor);
            assertEq(stablecoin.balanceOf(actor), available, "zero-share deposit preserves assets");
            calls[msg.sig].expectedReverts++;
            return;
        }
        vm.prank(actor);
        if (unwrap_) wrapper.redeem(amount, actor, actor);
        else wrapper.deposit(amount, actor);
        _success();
    }

    function invest(uint256 raw, bool recall_) external counted {
        uint256 amount = _amount(raw, cusdUnderlying.balanceOf(recall_ ? address(reserve) : address(stablecoin)));
        if (amount == 0) {
            _skip();
            return;
        }
        if (recall_) stablecoin.recall(amount);
        else stablecoin.invest(amount);
        _success();
    }

    function allocate(uint256 which, uint256 raw) external counted {
        uint256 k = which % 2;
        uint256 amount = _amount(raw, vault.balanceOf(address(pool), address(collateral)));
        if (amount == 0 || ts[k].killed()) {
            _skip();
            return;
        }
        pool.allocate(address(ts[k]), amount);
        _syncMark(k);
        _success();
    }

    function deallocate(uint256 which, uint256 raw, bool async_) external counted {
        uint256 k = which % 2;
        uint256 amount = _amount(raw, ts[k].balanceOf(address(pool)));
        if (amount == 0) {
            _skip();
            return;
        }
        if (async_) pool.deallocateAsync(address(ts[k]), amount);
        else pool.deallocate(address(ts[k]), amount);
        _syncExistingMark(k);
        _success();
    }

    function finalize(uint256 rawId, uint256 raw) external counted {
        if (receipts.length == 0) {
            _skip();
            return;
        }
        GhostReceipt memory r = receipts[rawId % receipts.length];
        if (r.controller != address(pool) || r.shares == 0) {
            _skip();
            return;
        }
        uint256 amount = _amount(raw, IERC7540AsyncRedeem(r.token).claimableRedeemRequest(r.id, r.controller));
        if (amount == 0) {
            _skip();
            return;
        }
        pool.finalizeDeallocateAsync(r.token, r.id, amount);
        _syncExistingMark(r.token == address(ts[0]) ? 0 : 1);
        if (amount < r.shares) partialSettlements++;
        _success();
    }

    function report(uint256 which) external counted {
        uint256 k = which % 2;
        pool.report(address(ts[k]));
        _syncExistingMark(k);
        _success();
    }

    function borrow(uint256 raw, bool fixed_, uint256 rawTerm) external counted {
        IBaseMarket market = fixed_ ? IBaseMarket(address(fixedMarket)) : IBaseMarket(address(floating));
        // Independent capital calculation below validates the advertised available-credit view.
        uint256 limit = _referenceCredit(market);
        assertEq(market.creditLimit(), limit, "independent capital/credit reference");
        uint256 debt = market.totalDebt();
        uint256 room = limit > debt ? limit - debt : 0;
        assertEq(market.availableCredit(), room);
        // Conservative debt headroom, not the availableCredit(term) solver under test.
        uint256 amount = _amount(raw, room / 4);
        if (amount < 1e9 || market.healthiness() < RAY) {
            _skip();
            return;
        }
        uint256 before = stablecoin.balanceOf(defaultBorrower);
        uint256 actual;
        vm.prank(defaultBorrower);
        if (fixed_) (, actual) = fixedMarket.borrow(defaultBorrower, amount, bound(rawTerm, 1 days, 30 days));
        else actual = floating.borrow(defaultBorrower, amount);
        assertEq(stablecoin.balanceOf(defaultBorrower) - before, actual);
        assertLe(actual, amount);
        _success();
    }

    function repay(uint256 rawId, uint256 raw, bool fixed_, bool full) external counted {
        uint256 debt;
        uint256 id;
        if (fixed_) {
            if (fixedMarket.loanCount() == 0) {
                _skip();
                return;
            }
            id = rawId % fixedMarket.loanCount();
            debt = fixedMarket.debt(id);
        } else {
            debt = floating.totalDebt();
        }
        uint256 amount = full ? debt : _amount(raw, debt);
        if (amount == 0 || (!full && amount < 1e9) || stablecoin.balanceOf(defaultBorrower) < amount) {
            _skip();
            return;
        }
        uint256 before = stablecoin.balanceOf(defaultBorrower);
        vm.prank(defaultBorrower);
        uint256 actual = fixed_ ? fixedMarket.repay(id, amount) : floating.repay(amount);
        assertEq(before - stablecoin.balanceOf(defaultBorrower), actual);
        assertLe(actual, amount);
        assertEq(debt - (fixed_ ? fixedMarket.debt(id) : floating.totalDebt()), actual);
        _success();
    }

    function extend(uint256 rawId, uint256 rawTerm) external counted {
        if (fixedMarket.loanCount() == 0) {
            _skip();
            return;
        }
        uint256 id = rawId % fixedMarket.loanCount();
        if (fixedMarket.debt(id) == 0) {
            _skip();
            return;
        }
        uint256 expiry = fixedMarket.expiry(id);
        uint256 term = bound(rawTerm, 1 days, 7 days);
        if (block.timestamp >= expiry + fixedMarket.grace()) {
            fixedMarket.extendAdmin(id, term);
        } else {
            if (block.timestamp < expiry && expiry - block.timestamp + term > 30 days) {
                _skip();
                return;
            }
            // A deliberately conservative valid-health regime for borrower extensions.
            if (fixedMarket.healthiness() < 1.5e27) {
                _skip();
                return;
            }
            vm.prank(defaultBorrower);
            fixedMarket.extend(id, term);
        }
        _success();
    }

    function advance(uint256 raw) external counted {
        uint256 step = bound(raw, 1, 7 days);
        if (block.timestamp + step > initialTimestamp + 5 * 365 days) {
            _skip();
            return;
        }
        vm.warp(block.timestamp + step);
        _success();
    }

    function price(uint256 raw) external counted {
        _setPrice(address(collateral), bound(raw, 1, 200) * 1e16);
        _success();
    }

    function risk(uint256 raw, bool fixed_) external counted {
        IBaseMarket market = fixed_ ? IBaseMarket(address(fixedMarket)) : IBaseMarket(address(floating));
        market.setLiquidationThreshold(bound(raw, 20, 95) * 1e25);
        _success();
    }

    function charge() external counted {
        floating.chargePremium();
        _success();
    }

    function liquidate(uint256 rawId, uint256 raw, bool fixed_) external counted {
        IBaseMarket market = fixed_ ? IBaseMarket(address(fixedMarket)) : IBaseMarket(address(floating));
        if (market.healthiness() >= RAY) {
            _skip();
            return;
        }
        uint256 available = market.maxLiquidatable();
        uint256 id;
        if (fixed_) {
            if (fixedMarket.loanCount() == 0) {
                _skip();
                return;
            }
            id = rawId % fixedMarket.loanCount();
            available = _min(available, fixedMarket.debt(id));
        }
        uint256 amount = _amount(raw, _min(available, stablecoin.balanceOf(defaultLiquidator)));
        if (amount < 1e9) {
            _skip();
            return;
        }
        uint256 debt = market.totalDebt();
        uint256 balance = stablecoin.balanceOf(defaultLiquidator);
        uint256 collateralBefore = collateral.balanceOf(defaultLiquidator);
        uint256 repaid;
        uint256 slashed;
        vm.prank(defaultLiquidator);
        if (fixed_) (repaid, slashed) = fixedMarket.liquidate(id, defaultLiquidator, amount);
        else (repaid, slashed) = floating.liquidate(defaultLiquidator, amount);
        assertEq(balance - stablecoin.balanceOf(defaultLiquidator), repaid);
        assertEq(debt - market.totalDebt(), repaid);
        uint256 delivered = collateral.balanceOf(defaultLiquidator) - collateralBefore;
        // Two waterfall legs each floor their dollar value. Aggregate value differs by <=1 wei.
        uint256 value = delivered * oracle.price(address(collateral)) / 1e18;
        assertLe(slashed, value);
        assertLe(value - slashed, 1);
        if (delivered > 0) lossActions++;
        _success();
    }

    function writeOff(uint256 rawId, bool fixed_) external counted {
        IBaseMarket market = fixed_ ? IBaseMarket(address(fixedMarket)) : IBaseMarket(address(floating));
        if (market.healthiness() >= RAY || market.unrecoverableDebt() < 1e9) {
            _skip();
            return;
        }
        uint256 amount;
        if (fixed_) {
            if (fixedMarket.loanCount() == 0) {
                _skip();
                return;
            }
            uint256 id = rawId % fixedMarket.loanCount();
            if (fixedMarket.debt(id) == 0) {
                _skip();
                return;
            }
            amount = fixedMarket.writeOff(id);
        } else {
            amount = floating.writeOff();
        }
        assertGt(amount, 0);
        assertEq(market.availableCredit(), 0, "write-off cannot reopen borrowing");
        lossActions++;
        _success();
    }

    function cover(uint256 raw) external counted {
        uint256 amount = _amount(raw, _min(stablecoin.badDebt(), stablecoin.balanceOf(defaultBorrower)));
        if (amount == 0) {
            _skip();
            return;
        }
        uint256 before = stablecoin.badDebt();
        vm.prank(defaultBorrower);
        assertEq(stablecoin.coverBadDebt(amount), amount);
        assertEq(before - stablecoin.badDebt(), amount);
        _success();
    }

    function premium(uint256 which, uint256 who, uint256 mode, uint256 raw) external counted {
        IPremiumVesting token = IPremiumVesting(address(exits[which % 6]));
        address actor = actors[who % 3];
        if (mode % 4 == 0) {
            uint256 amount = _amount(raw, cusdUnderlying.balanceOf(actor));
            if (amount == 0) {
                _skip();
                return;
            }
            vm.prank(actor);
            stablecoin.fund(amount);
        } else {
            vm.startPrank(actor);
            if (mode % 4 == 1) {
                token.optIn();
            } else if (mode % 4 == 2) {
                token.optOut();
            } else {
                uint256 before = stablecoin.balanceOf(actor);
                uint256 paid = token.claim(actor);
                assertEq(stablecoin.balanceOf(actor) - before, paid);
                if (paid > 0) positiveClaims++;
            }
            vm.stopPrank();
        }
        _success();
    }

    function changeVestingPeriod(uint256 which, uint256 raw) external counted {
        IPremiumVesting token = IPremiumVesting(address(exits[which % 6]));
        uint256 period = bound(raw, 1, 365 days);
        uint256 remainder = token.remaining();
        uint256[3] memory earned;
        for (uint256 i; i < 3; ++i) {
            earned[i] = token.claimable(actors[i]);
        }
        token.setVestingPeriod(period);
        assertEq(token.vestingPeriod(), period);
        assertEq(token.remaining(), remainder, "checkpoint keeps the unvested pot");
        assertEq(token.vested(), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(token.claimable(actors[i]), earned[i], "past earnings survive rate changes");
        }
        _success();
    }

    function request(uint256 which, uint256 who, uint256 raw) external counted {
        IERC7540AsyncRedeem token = exits[which % 6];
        address actor = actors[who % 3];
        uint256 amount = _amount(raw, token.balanceOf(actor));
        if (amount == 0) {
            _skip();
            return;
        }
        uint256 wallet = token.balanceOf(actor);
        uint256 escrow = token.balanceOf(address(token));
        vm.prank(actor);
        token.requestRedeem(amount, actor, actor);
        assertEq(wallet - token.balanceOf(actor), amount);
        assertEq(token.balanceOf(address(token)) - escrow, amount);
        _success();
    }

    function transferRequest(uint256 rawId, uint256 who) external counted {
        if (receipts.length == 0) {
            _skip();
            return;
        }
        GhostReceipt memory r = receipts[rawId % receipts.length];
        if (r.shares == 0 || r.controller == address(pool)) {
            _skip();
            return;
        }
        vm.prank(r.controller);
        IERC7540AsyncRedeem(r.token).transferRequest(r.id, actors[who % 3]);
        _success();
    }

    function settle(uint256 which, uint256 who, uint256 raw, uint256 mode) external counted {
        uint256 k = which % 6;
        IERC7540AsyncRedeem token = exits[k];
        address actor = actors[who % 3];
        uint256 available = mode % 3 == 0 ? token.maxInstantWithdraw(actor) : token.maxWithdraw(actor);
        uint256 amount = _amount(raw, available);
        if (amount == 0) {
            _skip();
            return;
        }
        uint256 id;
        if (mode % 3 == 2) {
            bool found;
            for (uint256 i; i < receipts.length; ++i) {
                GhostReceipt memory r = receipts[i];
                if (r.token == address(token) && r.controller == actor && r.shares > 0) {
                    id = r.id;
                    found = true;
                    break;
                }
            }
            if (!found) {
                _skip();
                return;
            }
            amount = _min(amount, token.convertToAssets(token.claimableRedeemRequest(id, actor)));
            if (amount == 0) {
                _skip();
                return;
            }
        }
        uint256 health = k < 4 ? IBaseMarket(ts[k].market()).healthiness() : 0;
        uint256 liquid = k == 5
            ? cusdUnderlying.balanceOf(address(stablecoin))
            : vault.balanceOf(address(token), address(collateral));
        uint256 before = _assetBalance(k, actor);
        uint256 supply = token.totalSupply();
        uint256 quote = token.quoteWithdraw(amount);
        if (k != 5) _checkCeil(amount, quote, token.totalAssets() + 1, supply + 1);
        uint256 burned;
        vm.prank(actor);
        if (mode % 3 == 0) burned = token.instantWithdraw(amount, actor, actor);
        else if (mode % 3 == 1) burned = token.withdraw(amount, actor, actor);
        else burned = token.withdraw(id, amount, actor, actor);
        assertEq(_assetBalance(k, actor) - before, amount, "exact asset payment");
        assertEq(burned, quote);
        assertEq(supply - token.totalSupply(), burned);
        assertLe(amount, liquid, "current cash bounds settlement");
        if (health >= RAY) assertGe(IBaseMarket(ts[k].market()).healthiness(), RAY, "withdrawal preserves health");
        if (mode % 3 != 0 && token.redemptionQueue() > 0) partialSettlements++;
        _success();
    }

    function permission(uint256 which, uint256 who, bool admit) external counted {
        address target = address(exits[which % 5]);
        address actor = actors[who % 3];
        if (admit) _admitDepositor(target, actor);
        else _expelDepositor(target, actor);
        assertEq(_mayDeposit(target, actor), admit);
        _success();
    }

    /// @notice Separate invalid-operation selector. Exact auth error, no swallowed reverts.
    function unauthorized(uint256 which) external counted {
        address outsider = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, outsider));
        vm.prank(outsider);
        exits[which % 5].deposit(1e18, outsider);
        calls[msg.sig].expectedReverts++;
    }

    function checkAccounting() public view {
        assertEq(vault.totalSupply(vault.id(address(collateral))), collateral.balanceOf(address(vault)));
        uint256 held = collateral.balanceOf(address(vault)) + collateral.balanceOf(defaultLiquidator);
        for (uint256 i; i < 3; ++i) {
            held += collateral.balanceOf(actors[i]);
        }
        assertEq(held, collateralCreated, "external collateral conserved");
        uint256 sum;
        for (uint256 i; i < fixedMarket.loanCount(); ++i) {
            sum += fixedMarket.debt(i);
        }
        assertEq(sum, fixedMarket.totalDebt(), "fixed loan sum");
        (uint256 lp, uint256 up) = floating.premium();
        assertEq(floating.totalDebt() + sum, stablecoin.creditBackedSupply() + lp + up, "live versus realized credit");
        uint256 realized;
        address[2] memory markets = [address(floating), address(fixedMarket)];
        for (uint256 i; i < 2; ++i) {
            address m = markets[i];
            uint256 book = ghostPrincipal[m] + ghostPremium[m] - ghostRepaid[m] - ghostWrittenOff[m];
            realized += book;
            assertEq(book + (i == 0 ? lp + up : 0), IBaseMarket(m).totalDebt(), "flow ledger versus debt");
        }
        assertEq(realized, stablecoin.creditBackedSupply());
        assertEq(
            cusdUnderlying.balanceOf(address(stablecoin)) + cusdUnderlying.balanceOf(address(reserve)) + realized,
            stablecoin.totalSupply() - stablecoin.badDebt(),
            "physical reserve plus debt backing"
        );
        assertEq(pool.totalDebt(), ghostMarks[0] + ghostMarks[1]);
        assertEq(pool.totalAssets(), vault.balanceOf(address(pool), address(collateral)) + pool.totalDebt());
        for (uint256 i; i < 2; ++i) {
            assertEq(pool.debt(address(ts[i])), ghostMarks[i]);
        }
        for (uint256 k; k < 6; ++k) {
            address token = address(exits[k]);
            if (k < 5) {
                bool retired = k < 4 ? ts[k].killed() : pool.killed();
                assertEq(retired, ghostKilled[token], "retirement follows a permanent Killed event");
                if (retired) {
                    assertEq(exits[k].maxDeposit(actors[0]), 0);
                    assertEq(exits[k].maxMint(actors[0]), 0);
                }
            }
            if (k < 4 && ts[k].totalAssets() * 100 < ts[k].totalSupply()) {
                assertTrue(ts[k].killed(), "a below-threshold tranche must be retired after slash or exit");
            }
            uint256 queue;
            uint256 poolQueue;
            for (uint256 i; i < receipts.length; ++i) {
                GhostReceipt memory r = receipts[i];
                if (r.token != token) continue;
                queue += r.shares;
                uint256 claimable = exits[k].claimableRedeemRequest(r.id, r.controller);
                uint256 pending = exits[k].pendingRedeemRequest(r.id, r.controller);
                assertEq(claimable + pending, r.shares, "ghost receipt versus pending/claimable");
                assertEq(exits[k].controllerOf(r.id), r.shares == 0 ? address(0) : r.controller);
                if (r.controller == address(pool)) {
                    poolQueue += r.shares;
                    assertEq(pool.queuedRequest(token, r.id), r.shares);
                }
            }
            assertEq(exits[k].redemptionQueue(), queue, "ghost queue");
            if (k < 2) assertEq(pool.queuedShares(token), poolQueue);
            if (k != 5) assertEq(exits[k].balanceOf(token), queue, "escrow");
            uint256 pot = stablecoin.balanceOf(token) - (k == 5 ? queue : 0);
            assertEq(ghostFunded[token] - ghostPaid[token], pot, "funded minus actual payments");
            IPremiumVesting vest = IPremiumVesting(token);
            assertLe(vest.remaining() + vest.vested(), ghostFunded[token], "unallocated funding");
            uint256 staked;
            for (uint256 i; i < 3; ++i) {
                if (vest.optedIn(actors[i])) staked += exits[k].balanceOf(actors[i]);
            }
            if (k < 2) staked += exits[k].balanceOf(address(pool));
            if (k == 5) staked += stablecoin.balanceOf(address(wrapper));
            assertEq(vest.stakedSupply(), staked, "earning supply");
        }
        uint256 idle = vault.balanceOf(address(pool), address(collateral));
        assertLe(pool.convertToAssets(pool.unlockedSupply()), idle, "pool redemption limit is payable");
        if (pool.totalAssets() * 100 < pool.totalSupply()) {
            assertEq(pool.maxDeposit(actors[0]), 0, "a depleted pool cannot recapitalize through new shares");
            assertEq(pool.maxMint(actors[0]), 0);
        }
    }

    /// @notice Explicit end-of-sequence checkpoint: no new capital, no price/risk repair.
    function unwind() external counted {
        checkAccounting();
        if (floating.totalDebt() > 0) {
            vm.prank(defaultBorrower);
            floating.repay(type(uint256).max);
        }
        for (uint256 i; i < fixedMarket.loanCount(); ++i) {
            if (fixedMarket.debt(i) > 0) {
                vm.prank(defaultBorrower);
                fixedMarket.repay(i, type(uint256).max);
            }
        }
        stablecoin.recall(cusdUnderlying.balanceOf(address(reserve)));
        // Settle in creation order; no dust request is left as a FIFO obstacle.
        for (uint256 i; i < receipts.length; ++i) {
            GhostReceipt memory r = receipts[i];
            if (r.shares == 0 || r.token == address(pool) || r.token == address(stablecoin)) continue;
            if (r.controller == address(pool)) {
                pool.finalizeDeallocateAsync(r.token, r.id, r.shares);
            } else {
                vm.prank(r.controller);
                IERC7540AsyncRedeem(r.token).redeem(r.id, r.shares, r.controller, r.controller);
            }
        }
        for (uint256 k; k < 2; ++k) {
            pool.deallocate(address(ts[k]), type(uint256).max);
            _syncExistingMark(k);
        }
        for (uint256 i; i < receipts.length; ++i) {
            GhostReceipt memory r = receipts[i];
            if (r.shares == 0 || (r.token != address(pool) && r.token != address(stablecoin))) continue;
            uint256 n = IERC7540AsyncRedeem(r.token).claimableRedeemRequest(r.id, r.controller);
            // Loss-bearing cUSD can remain economically locked; do not invent reserve to exit it.
            if (n > 0) {
                vm.prank(r.controller);
                IERC7540AsyncRedeem(r.token).redeem(r.id, n, r.controller, r.controller);
            }
        }
        for (uint256 k; k < 5; ++k) {
            assertEq(exits[k].redemptionQueue(), 0, "collateral queue drains after debt repayment");
            for (uint256 i; i < 3; ++i) {
                uint256 n = exits[k].maxInstantRedeem(actors[i]);
                if (n > 0) {
                    vm.prank(actors[i]);
                    exits[k].instantRedeem(n, actors[i], actors[i]);
                }
            }
        }
        assertEq(floating.totalDebt() + fixedMarket.totalDebt(), 0);
        assertEq(pool.totalDebt(), 0);
        unwinds++;
        _success();
    }

    function _harvest() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            bytes32 sig = l.topics[0];
            if (sig == keccak256("Killed()")) {
                assertFalse(ghostKilled[l.emitter], "retirement event only occurs once");
                ghostKilled[l.emitter] = true;
            } else if (sig == keccak256("Fund(uint256)")) {
                ghostFunded[l.emitter] += abi.decode(l.data, (uint256));
            } else if (sig == keccak256("Claimed(address,address,uint256)")) {
                ghostPaid[l.emitter] += abi.decode(l.data, (uint256));
            } else if (sig == keccak256("Borrow(address,uint256)")) {
                (, uint256 n) = abi.decode(l.data, (address, uint256));
                ghostPrincipal[l.emitter] += n;
            } else if (sig == keccak256("Repay(address,uint256)")) {
                (, uint256 n) = abi.decode(l.data, (address, uint256));
                ghostRepaid[l.emitter] += n;
            } else if (sig == keccak256("ChargePremium(address,uint256)")) {
                ghostPremium[l.emitter] += abi.decode(l.data, (uint256));
            } else if (sig == keccak256("WriteOff(address,uint256,uint256)")) {
                (uint256 n,) = abi.decode(l.data, (uint256, uint256));
                ghostWrittenOff[l.emitter] += n;
            } else if (sig == keccak256("RedeemRequest(address,address,uint256,address,uint256)")) {
                (, uint256 n) = abi.decode(l.data, (address, uint256));
                uint256 id = uint256(l.topics[3]);
                receiptIndex[l.emitter][id] = receipts.length;
                receipts.push(GhostReceipt(l.emitter, id, address(uint160(uint256(l.topics[1]))), n));
            } else if (sig == keccak256("RedeemRequestConsumed(uint256,address,uint256,uint256)")) {
                (uint256 n, uint256 remaining) = abi.decode(l.data, (uint256, uint256));
                GhostReceipt storage r = receipts[receiptIndex[l.emitter][uint256(l.topics[1])]];
                r.shares -= n;
                assertEq(r.shares, remaining);
            } else if (sig == keccak256("TransferRequest(address,address,uint256)")) {
                receipts[receiptIndex[l.emitter][uint256(l.topics[3])]].controller =
                    address(uint160(uint256(l.topics[2])));
            }
        }
    }

    function _syncMark(uint256 k) internal {
        uint256 shares = ts[k].balanceOf(address(pool)) + pool.queuedShares(address(ts[k]));
        uint256 assets = vault.balanceOf(address(ts[k]), address(collateral));
        ghostMarks[k] = shares * (assets + 1) / (ts[k].totalSupply() + 1);
        assertEq(pool.debt(address(ts[k])), ghostMarks[k], "mark includes queued position");
    }

    function _syncExistingMark(uint256 k) internal {
        if (ghostMarks[k] > 0) _syncMark(k);
    }

    function _referenceCredit(IBaseMarket market) internal view returns (uint256) {
        IBaseMarket.Tranche[] memory tranches = market.tranches();
        uint256 capital;
        for (uint256 i; i < tranches.length; ++i) {
            Tranche t = Tranche(tranches[i].tranche);
            uint256 activeShares = t.totalSupply() - t.redemptionQueue();
            uint256 activeAssets = activeShares * (t.totalAssets() + 1) / (t.totalSupply() + 1);
            uint256 value = activeAssets * oracle.price(t.asset()) / (10 ** t.decimals());
            capital += _min(value, t.maxCapital());
        }
        return (capital * _min(market.loanToValue(), market.liquidationThreshold() - market.buffer()) + RAY / 2) / RAY;
    }

    function _checkCeil(uint256 assets, uint256 shares, uint256 numerator, uint256 denominator) internal pure {
        assertGe(shares * numerator, assets * denominator, "ceil covers assets");
        if (shares > 0) assertLt((shares - 1) * numerator, assets * denominator, "ceil burns minimum shares");
    }

    function _assetBalance(uint256 k, address actor) internal view returns (uint256) {
        return k == 5 ? cusdUnderlying.balanceOf(actor) : vault.balanceOf(actor, address(collateral));
    }

    function _amount(uint256 raw, uint256 available) internal pure returns (uint256) {
        if (available == 0) return 0;
        uint256 cap = _min(available, 1000e18);
        // Exact 1, near-empty/full, and interior amounts all have substantial probability.
        if (raw % 5 == 0) return 1;
        if (raw % 5 == 1) return cap;
        if (raw % 5 == 2) return cap > 1 ? cap - 1 : 1;
        return 1 + raw % cap;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _skip() internal {
        calls[msg.sig].skipped++;
    }

    function _success() internal {
        calls[msg.sig].succeeded++;
    }
}
