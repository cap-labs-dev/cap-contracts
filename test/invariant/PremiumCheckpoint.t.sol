// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { DeadShares } from "../../contracts/utils/DeadShares.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";

contract PremiumCheckpointTest is CapDeployer {
    function setUp() public {
        _deployCap();
    }

    function testFuzz_explicitPremiumCheckpointAccountsForRetainedAndCappedAmounts(uint96 rawFund, uint32 elapsed)
        public
    {
        (, address a,) = _createMarket("Premium checkpoint");
        Tranche t = Tranche(a);
        address[3] memory actors = [makeAddr("premium alice"), makeAddr("premium bob"), makeAddr("premium carol")];
        for (uint256 i; i < 3; ++i) {
            _fundTranche(a, actors[i], 1001 + i);
        }
        uint256 funded = bound(rawFund, 1, 1e24);
        _depositStable(address(this), funded);
        stablecoin.transfer(a, funded);
        t.fund(funded);
        assertEq(t.remaining(), funded);
        vm.warp(block.timestamp + bound(elapsed, 1, 12 hours));
        uint256 unwritten = t.vested();
        assertEq(t.remaining() + unwritten, funded);
        // Explicit allocation checkpoint, with an independently conserved input pot.
        vm.prank(actors[0]);
        t.optOut();
        uint256 unvested = t.remaining();
        uint256 allocated = funded - unvested;
        assertEq(allocated, unwritten);
        vm.prank(actors[1]);
        t.transfer(actors[2], 1);
        vm.prank(actors[0]);
        t.optIn();
        uint256 paid;
        uint256 clearedShortPayment;
        for (uint256 i; i < 3; ++i) {
            uint256 entitlement = t.claimable(actors[i]);
            uint256 before = stablecoin.balanceOf(actors[i]);
            vm.prank(actors[i]);
            uint256 actual = t.claim(actors[i]);
            assertEq(stablecoin.balanceOf(actors[i]) - before, actual);
            assertLe(actual, entitlement);
            paid += actual;
            clearedShortPayment += entitlement - actual;
        }
        // No percent tolerance: pay can consume the pot under the accepted cap policy.
        assertEq(paid + stablecoin.balanceOf(a), funded);
        emit log_named_uint("funded", funded);
        emit log_named_uint("allocated at first checkpoint", allocated);
        emit log_named_uint("unvested at first checkpoint", unvested);
        emit log_named_uint("cleared short payments", clearedShortPayment);
        vm.warp(block.timestamp + 365 days);
        for (uint256 i; i < 3; ++i) {
            vm.prank(actors[i]);
            paid += t.claim(actors[i]);
        }
        uint256 retained = stablecoin.balanceOf(a);
        assertEq(t.remaining(), 0, "explicit full vesting checkpoint");
        assertEq(paid + retained, funded);
        assertEq(t.balanceOf(DeadShares.HOLDER), DEAD_SHARES);
        emit log_named_uint("actually paid after full vesting", paid);
        emit log_named_uint("explicitly retained integer rounding", retained);
    }

    function testFuzz_wrapperCompletedRoundTrip(uint96 rawDeposit, uint64 rawDonation) public {
        address actor = makeAddr("wrapper actor");
        uint256 deposited = bound(rawDeposit, DEAD_SHARES + 1, 1e24);
        uint256 donation = bound(rawDonation, 0, 1e18);
        _depositStable(actor, deposited + donation);
        vm.startPrank(actor);
        stablecoin.approve(address(wrapper), deposited);
        uint256 shares = wrapper.deposit(deposited, actor);
        stablecoin.transfer(address(wrapper), donation);
        uint256 out = wrapper.redeem(shares, actor, actor);
        vm.stopPrank();
        assertLe(out, deposited + donation);
        assertEq(out + stablecoin.balanceOf(address(wrapper)), deposited + donation);
        assertEq(wrapper.totalSupply(), DEAD_SHARES);
        assertEq(wrapper.balanceOf(DeadShares.HOLDER), DEAD_SHARES);
    }
}
