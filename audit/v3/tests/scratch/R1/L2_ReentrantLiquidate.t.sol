// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface ITokensReceived {
    function tokensReceived(address from, uint256 amount) external;
}

interface ITokensToSend {
    function tokensToSend(address to, uint256 amount) external;
}

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
            market.liquidate(address(this), innerAmount);
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

/// Round-3 re-check of round-1 L-2 (FIXED in round 2 by `ReentrancyGuardTransient`,
/// BaseMarket.sol:21; `liquidate` is `nonReentrant`, FloatingMarket.sol:83-96).
contract R1_L2_ReentrantLiquidate is CapDeployer {
    bytes internal guardError = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);

    HookERC20 hook;
    FloatingMarket market;
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
        _fundTranche(tranches[0], address(hook), alice, 950e18);
        _fundTranche(tranches[1], address(hook), bob, 50e18);
        attacker = new ReentrantLiquidator(market);
        _grantLiquidator(address(attacker));
        vm.prank(address(attacker));
        hook.setHook(true);
        _depositStable(address(attacker), 400e18);
    }

    function _borrowAndCrash() internal {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        _setPrice(address(hook), 0.5e18);
        assertLt(market.healthiness(), 1e27);
    }

    function test_L2_innerRefusedByGuard_I3Holds() public {
        _borrowAndCrash();
        uint256 cusdBefore = stablecoin.balanceOf(address(attacker));
        uint256 collateralBefore = hook.balanceOf(address(attacker));
        attacker.liquidate(100e18, 100e18, true);
        uint256 burned = cusdBefore - stablecoin.balanceOf(address(attacker));
        uint256 received = hook.balanceOf(address(attacker)) - collateralBefore;
        emit log_named_uint("cUSD burned by liquidator", burned);
        emit log_named_uint("collateral received (tokens)", received);
        assertTrue(attacker.innerAttempted(), "hook fired and re-entered");
        assertFalse(attacker.innerSucceeded(), "inner liquidation refused");
        assertEq(attacker.innerRevert(), guardError, "refused by ReentrancyGuardReentrantCall");
        assertEq(burned, 100e18, "one liquidation paid for");
        assertEq(received, 204e18, "100 debt * 1.02 / 0.5 = 204 tokens, once");
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "I3");
    }

    function test_L2_bubbles_wholeCallReverts() public {
        _borrowAndCrash();
        vm.expectRevert(guardError);
        attacker.liquidate(100e18, 100e18, false);
        assertEq(market.totalDebt(), 500e18, "debt untouched");
    }
}
