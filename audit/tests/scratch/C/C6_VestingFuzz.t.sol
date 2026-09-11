// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { PremiumVesting } from "../../../../contracts/utils/PremiumVesting.sol";
import { Test } from "forge-std/Test.sol";

/// WS-C / I14: stateful fuzz over accrue / fund / checkpoint / settle / setPeriod / warp sequences.
/// Checks (1) total settled never exceeds total funded, (2) an account's entitlement never falls
/// because of another account's action, (3) lastUpdate <= end() always.
contract VestingHarness {
    using PremiumVesting for PremiumVesting.Schedule;
    PremiumVesting.Schedule internal s;
    mapping(address => uint256) public bal;
    address[3] public accts;
    uint256 public supply;
    uint256 public funded;
    uint256 public settled;

    constructor() {
        s.open(6 hours);
        accts = [address(0xA1), address(0xB2), address(0xC3)];
    }

    function accrue() external {
        s.accrue(supply);
    }

    function fund(uint256 amt) external {
        s.accrue(supply);
        s.fund(amt);
        funded += amt;
    }

    function setPeriod(uint256 p) external {
        s.accrue(supply);
        s.setPeriod(p);
    }

    function move(uint8 i, uint256 newBal) external {
        address a = accts[i % 3];
        s.accrue(supply);
        s.checkpoint(a, bal[a], newBal);
        supply = supply - bal[a] + newBal;
        bal[a] = newBal;
    }

    function settle(uint8 i) external returns (uint256 p) {
        address a = accts[i % 3];
        s.accrue(supply);
        p = s.settle(a, bal[a]);
        settled += p;
    }

    function claimable(uint8 i) external view returns (uint256) {
        address a = accts[i % 3];
        return s.claimable(a, bal[a], supply);
    }

    function lastUpdate() external view returns (uint256) {
        return s.lastUpdate;
    }

    function end_() external view returns (uint256) {
        return s.end();
    }

    function locked() external view returns (uint256) {
        return s.locked();
    }
}

contract C6_VestingFuzz is Test {
    VestingHarness h;

    function setUp() public {
        vm.warp(1_700_000_000);
        h = new VestingHarness();
    }

    function testFuzz_I14_sequence(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 8, 40));
        for (uint256 k; k < steps; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            uint8 op = uint8(r % 7);
            uint8 who = uint8((r >> 8) % 3);
            uint256 v = (r >> 16) % 1e24;
            uint256 c0 = h.claimable(0);
            uint256 c1 = h.claimable(1);
            uint256 c2 = h.claimable(2);

            if (op == 0) h.accrue();
            else if (op == 1) h.fund(v);
            else if (op == 2) h.setPeriod(1 + (v % 30 days));
            else if (op == 3) h.move(who, v);
            else if (op == 4) h.settle(who);
            else vm.warp(block.timestamp + (v % 12 hours));

            // (3) cursor never passes the epoch end
            assertLe(h.lastUpdate(), h.end_(), "lastUpdate > end");
            // (2) nobody else's action lowers an account's entitlement (moves/settles on self excluded)
            if (op != 3 && op != 4) {
                assertGe(h.claimable(0) + 1, c0, "A entitlement fell");
                assertGe(h.claimable(1) + 1, c1, "B entitlement fell");
                assertGe(h.claimable(2) + 1, c2, "C entitlement fell");
            } else {
                if (who % 3 != 0) assertGe(h.claimable(0) + 1, c0, "A entitlement fell by other's action");
                if (who % 3 != 1) assertGe(h.claimable(1) + 1, c1, "B entitlement fell by other's action");
                if (who % 3 != 2) assertGe(h.claimable(2) + 1, c2, "C entitlement fell by other's action");
            }
            // (1) conservation, allowing the documented 1-wei-per-checkpoint slack
            uint256 outstanding = h.claimable(0) + h.claimable(1) + h.claimable(2);
            assertLe(h.settled() + outstanding, h.funded() + steps, "claims exceed funding");
        }
    }
}
