// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @dev A collateral with a transfer hook (ERC-777 / ERC-1363 style). Swallows hook failures.
contract HookToken is ERC20 {
    constructor() ERC20("Hook", "HOOK") { }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to.code.length > 0) {
            (bool ok,) = to.call(abi.encodeWithSignature("onTokenReceived(address,uint256)", from, value));
            ok;
        }
    }
}

contract ReentrantLiquidator {
    FloatingMarket public market;
    uint256 public depth;
    uint256 public maxDepth;
    uint256 public attempts;
    uint256 public successes;
    bytes public lastRevert;

    constructor(FloatingMarket m, uint256 d) {
        market = m;
        maxDepth = d;
    }

    function go() external {
        market.liquidate(address(this), type(uint256).max);
    }

    function onTokenReceived(address, uint256) external {
        if (depth < maxDepth) {
            depth++;
            attempts++;
            try market.liquidate(address(this), type(uint256).max) {
                successes++;
            } catch (bytes memory r) {
                lastRevert = r;
            }
        }
    }
}

/// @notice R2 port of round-1 WS-D D8 (finding L-2). Round 1: debt fell once, cUSD burned and
/// collateral slashed N times; I3 (debt cleared == cUSD burned) failed. Expected now: guard refuses
/// every nested liquidate, so the assertions hold.
contract L2_D8_LiquidateReentry is CapDeployer {
    bytes internal guardError = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    HookToken hook;

    function setUp() public {
        _deployCap();
        hook = new HookToken();
        _setPrice(address(hook), 1e18);
    }

    function test_L2_D8_reenteredLiquidation_refused_I3Holds() public {
        address[] memory assets = new address[](1);
        assets[0] = address(hook);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e27;
        (address m, address[] memory tranches) =
            _createMarket("R", defaultMarketOwner, defaultBorrower, assets, weights);
        FloatingMarket market = FloatingMarket(m);
        market.setUnderwriterRate(0);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(tranches[0], address(hook), makeAddr("uw"), 10_000e18);

        MarketBundle memory other = _createReadyMarket("Other");
        _fundTranche(other.tranche0Addr, makeAddr("uw2"), 100_000e18);
        other.market.setFixedCreditLimit(type(uint256).max);
        vm.prank(defaultBorrower);
        other.market.borrow(defaultBorrower, 40_000e18);

        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max); // 5_000
        _setPrice(address(hook), 0.6e18); // C = 6_000, threshold 4_800 < 5_000

        ReentrantLiquidator atk = new ReentrantLiquidator(market, 3);
        _grantLiquidator(address(atk));
        _depositStable(address(atk), 10_000e18);

        uint256 debt0 = market.totalDebt();
        uint256 cbs0 = stablecoin.creditBackedSupply();
        uint256 cap0 = market.totalCapital();
        uint256 maxLiq = market.maxLiquidatable();
        emit log_named_uint("maxLiquidatable (single call)", maxLiq);

        atk.go();

        uint256 burned = cbs0 - stablecoin.creditBackedSupply();
        emit log_named_uint("nested attempts       ", atk.attempts());
        emit log_named_uint("nested successes      ", atk.successes());
        emit log_named_bytes("nested revert data    ", atk.lastRevert());
        emit log_named_uint("debt cleared          ", debt0 - market.totalDebt());
        emit log_named_uint("cUSD burned           ", burned);
        emit log_named_uint("collateral value taken", cap0 - market.totalCapital());
        emit log_named_uint("liquidator hook tokens", hook.balanceOf(address(atk)));
        emit log_named_uint("health after          ", market.healthiness());
        emit log_named_uint("sum of market debt    ", market.totalDebt() + other.market.totalDebt());
        emit log_named_uint("creditBackedSupply    ", stablecoin.creditBackedSupply());

        assertEq(atk.attempts(), 1, "hook re-entered once (only one tranche pays out)");
        assertEq(atk.successes(), 0, "nested liquidate refused");
        assertEq(atk.lastRevert(), guardError, "refused by ReentrancyGuardReentrantCall");
        assertEq(debt0 - market.totalDebt(), burned, "I3: debt cleared must equal cUSD burned");
        assertLe(burned, maxLiq + 2, "a single liquidation must not clear more than maxLiquidatable");
        assertEq(burned, maxLiq, "exactly one liquidation, at the cap");
        assertEq(
            market.totalDebt() + other.market.totalDebt(),
            stablecoin.creditBackedSupply(),
            "sum of market debt == creditBackedSupply"
        );
        assertGe(market.healthiness(), 1e27, "single liquidation restored health");
    }
}
