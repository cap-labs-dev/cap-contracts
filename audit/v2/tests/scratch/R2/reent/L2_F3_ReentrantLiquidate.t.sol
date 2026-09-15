// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { console } from "forge-std/Test.sol";

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { Vault } from "../../../../../../contracts/cap/Vault.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface ITokensReceived {
    function tokensReceived(address from, uint256 amount) external;
}

interface ITokensToSend {
    function tokensToSend(address to, uint256 amount) external;
}

/// ERC-777-style collateral: calls a hook on recipients that opted in (round-1 F3 HookERC20, unchanged)
contract HookERC20 is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Hook", "HOOK") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(bool on) external {
        hooked[msg.sender] = on;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (hooked[from]) ITokensToSend(from).tokensToSend(to, amount);
        super._update(from, to, amount);
        if (hooked[to]) ITokensReceived(to).tokensReceived(from, amount);
    }
}

/// A LIQUIDATOR whose slash recipient is itself. When the first tranche's slash pays it, it
/// re-enters FloatingMarket.liquidate from its `tokensReceived` hook (the LIQUIDATOR-recipient path).
/// R2 port: optionally catches the inner revert so the outer call can finish and the books be inspected.
contract ReentrantLiquidator is ITokensReceived, ITokensToSend {
    function tokensToSend(address, uint256) external { }

    FloatingMarket public market;
    uint256 public innerAmount;
    bool public swallow;
    bool entered;
    bool public innerAttempted;
    bool public innerSucceeded;
    bytes public innerRevert;

    constructor(FloatingMarket _market) {
        market = _market;
    }

    function liquidate(uint256 amount, uint256 _innerAmount, bool _swallow) external {
        innerAmount = _innerAmount;
        swallow = _swallow;
        market.liquidate(address(this), amount);
    }

    function tokensReceived(address, uint256) external {
        if (entered || innerAmount == 0) return;
        entered = true;
        innerAttempted = true;
        if (!swallow) {
            market.liquidate(address(this), innerAmount); // bubbles
            innerSucceeded = true;
            return;
        }
        try market.liquidate(address(this), innerAmount) {
            innerSucceeded = true;
        } catch (bytes memory reason) {
            innerRevert = reason;
        }
    }
}

/// R2 port of round-1 WS-F F3 (finding L-2). Round 1: no guard, the nested liquidate was overwritten
/// by the outer `scaledDebt` store: 200 cUSD burned for 100 of debt reduction, I3 broken.
/// Expected now: BaseMarket is ReentrancyGuardTransient and `liquidate` is nonReentrant.
contract L2_F3_ReentrantLiquidate is CapDeployer {
    bytes internal guardError = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    HookERC20 hook;
    FloatingMarket market;
    Tranche senior;
    Tranche junior;
    ReentrantLiquidator attacker;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _deployCap();
        hook = new HookERC20();
        _setPrice(address(hook), 1e18);

        address[] memory assets = new address[](2);
        assets[0] = address(hook);
        assets[1] = address(hook);
        (address m, address[] memory tranches) =
            _createMarket("hooked", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        market = FloatingMarket(m);
        senior = Tranche(tranches[0]);
        junior = Tranche(tranches[1]);

        _fundTranche(address(senior), address(hook), alice, 950e18);
        _fundTranche(address(junior), address(hook), bob, 50e18);

        attacker = new ReentrantLiquidator(market);
        _grantLiquidator(address(attacker));
        vm.prank(address(attacker));
        hook.setHook(true);
        _depositStable(address(attacker), 400e18); // par mint, not credit-backed
    }

    function _borrowAndCrash() internal {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        assertEq(market.totalDebt(), 500e18);
        assertEq(stablecoin.creditBackedSupply(), 500e18);
        _setPrice(address(hook), 0.5e18); // capital 500, LT 400 < debt 500
        assertLt(market.healthiness(), 1e27);
    }

    /// Round-1 assertion was `burned == 200e18` and I3 broken. Now: the inner liquidate (from the
    /// recipient's receive hook) is refused by the guard, only one liquidation is paid for, I3 holds.
    function test_L2_F3_reentrantLiquidate_innerRefusedByGuard_I3Holds() public {
        _borrowAndCrash();
        uint256 cusdBefore = stablecoin.balanceOf(address(attacker));
        uint256 collateralBefore = hook.balanceOf(address(attacker));

        attacker.liquidate(100e18, 100e18, true);

        uint256 burned = cusdBefore - stablecoin.balanceOf(address(attacker));
        uint256 received = hook.balanceOf(address(attacker)) - collateralBefore;
        console.log("inner liquidate attempted      :", attacker.innerAttempted());
        console.log("inner liquidate succeeded      :", attacker.innerSucceeded());
        console.logBytes(attacker.innerRevert());
        console.log("cUSD burned by liquidator      :", burned);
        console.log("collateral received (tokens)   :", received);
        console.log("market.totalDebt()             :", market.totalDebt());
        console.log("stablecoin.creditBackedSupply():", stablecoin.creditBackedSupply());

        assertTrue(attacker.innerAttempted(), "hook fired and re-entered");
        assertFalse(attacker.innerSucceeded(), "inner liquidation refused");
        assertEq(attacker.innerRevert(), guardError, "refused by ReentrancyGuardReentrantCall");
        assertEq(burned, 100e18, "round-1 over-burn (200e18) no longer holds: one liquidation paid for");
        assertEq(received, 204e18, "100 debt * 1.02 bonus / 0.5 price = 204 tokens, once");
        assertEq(market.totalDebt(), 400e18);
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "I3: market debt == credit-backed supply");
    }

    /// Same attack with a hook that does not swallow: the guard error bubbles and the entire
    /// outer liquidation reverts, leaving the books untouched.
    function test_L2_F3_reentrantLiquidate_bubbles_wholeCallReverts() public {
        _borrowAndCrash();
        uint256 cusdBefore = stablecoin.balanceOf(address(attacker));

        vm.expectRevert(guardError);
        attacker.liquidate(100e18, 100e18, false);

        assertEq(stablecoin.balanceOf(address(attacker)), cusdBefore, "nothing burned");
        assertEq(market.totalDebt(), 500e18, "debt untouched");
        assertEq(stablecoin.creditBackedSupply(), 500e18);
    }

    /// Round 1: after the re-entrancy, debt (400) > creditBackedSupply (300) and full repay
    /// underflowed. Now: 400 == 400 and the borrower repays in full.
    function test_L2_F3_afterReentrancy_borrowerCanRepayInFull() public {
        _borrowAndCrash();
        attacker.liquidate(100e18, 100e18, true);

        assertEq(market.totalDebt(), 400e18);
        assertEq(stablecoin.creditBackedSupply(), 400e18, "round-1 value was 300e18");

        vm.prank(defaultBorrower);
        uint256 repaid = market.repay(type(uint256).max);
        assertEq(repaid, 400e18);
        assertEq(market.totalDebt(), 0);
        assertEq(stablecoin.creditBackedSupply(), 0);
    }
}
