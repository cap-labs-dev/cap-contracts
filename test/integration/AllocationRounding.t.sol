// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

/// @notice Default-tranche allocation buys whole tranche shares and keeps the change idle, so a
/// tranche whose share price has been inflated by a donation cannot collect the rounding remainder
/// of every Underwriter deposit at the expense of the pool's other holders.
contract AllocationRoundingTest is CapDeployer {
    uint256 internal constant HONEST_CAPITAL = 100_000e18;
    uint256 internal constant SEED = 10_000;
    uint256 internal constant DONATION = 100_000e18;

    address internal attacker = makeAddr("attacker");
    address internal honest = makeAddr("honest");
    Underwriter internal pool;
    Tranche internal target;

    /// @dev The audit's setup: idle honest capital in a pool whose default is a fresh tranche the
    /// attacker seeds and then inflates to ~10 tokens per share unit with a plain donation.
    function setUp() public {
        _deployCap();
        (, address t,) = _createMarket("pump");
        target = Tranche(t);

        pool = _deployUnderwriter();
        _fundUnderwriter(address(pool), honest, HONEST_CAPITAL);
        pool.addTranche(t);
        _admitDepositor(t, address(pool));
        pool.setDefaultTranche(t);

        _fundTranche(t, attacker, SEED);
        _mintCollateral(attacker, DONATION + 1_000e18);
        vm.startPrank(attacker);
        assertTrue(collateral.transfer(t, DONATION));
        collateral.approve(address(pool), type(uint256).max);
        vm.stopPrank();
        _admitDepositor(address(pool), attacker);
    }

    function _attackerValue() internal view returns (uint256) {
        return collateral.balanceOf(attacker) + pool.convertToAssets(pool.balanceOf(attacker))
            + target.convertToAssets(target.balanceOf(attacker));
    }

    function _honestValue() internal view returns (uint256) {
        uint256 poolLive = collateral.balanceOf(address(pool)) + target.convertToAssets(target.balanceOf(address(pool)));
        return poolLive * pool.balanceOf(honest) / pool.totalSupply();
    }

    /// @dev The audit's remainder pump: deposit `2p - 1` so allocation buys one tranche share, then
    /// redeem the pool shares straight back out of idle. Each round used to leave ~`p` of the pool's
    /// idle capital inside the tranche for its holders. Now the change stays in the pool.
    function test_remainderPumpNoLongerDrainsThePool() public {
        uint256 attackerStart = _attackerValue();
        uint256 honestStart = _honestValue();
        uint256 price = target.previewMint(1);
        assertGt(price, 9e18, "the donation inflated the tranche to ~10 tokens per share unit");

        uint256 rounds = 200;
        for (uint256 i; i < rounds; ++i) {
            uint256 x = target.previewMint(2) - 1;
            vm.startPrank(attacker);
            uint256 got = pool.deposit(x, attacker);
            uint256 out = pool.maxInstantRedeem(attacker);
            if (out > got) out = got;
            pool.instantRedeem(out, attacker, attacker);
            vm.stopPrank();
        }

        // ~200 * p = ~2,000 tokens moved per run before; now only wei-level rounding
        assertApproxEqAbs(_honestValue(), honestStart, rounds * 4, "honest holders keep their capital");
        assertLe(_attackerValue(), attackerStart, "the pump is not profitable");
    }

    /// @dev One allocation of `2p - 1`: the tranche is paid exactly for the one share it mints,
    /// the change stays idle in the pool, and no allowance is left behind.
    function test_allocationKeepsTheChangeIdle() public {
        uint256 x = target.previewMint(2) - 1;
        uint256 cost = target.previewMint(target.previewDeposit(x));
        uint256 trancheBefore = collateral.balanceOf(address(target));
        uint256 idleBefore = collateral.balanceOf(address(pool));

        vm.prank(attacker);
        pool.deposit(x, attacker);

        assertEq(target.balanceOf(address(pool)), 1, "one tranche share bought");
        assertEq(collateral.balanceOf(address(target)) - trancheBefore, cost, "tranche paid only its price");
        assertEq(collateral.balanceOf(address(pool)) - idleBefore, x - cost, "the change stays idle");
        assertGt(x - cost, 9e18, "and the change is ~p, not dust");
        assertEq(collateral.allowance(address(pool), address(target)), 0, "no allowance left");
    }
}
