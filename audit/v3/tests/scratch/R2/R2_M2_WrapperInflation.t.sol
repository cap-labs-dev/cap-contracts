// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../contracts/cap/Wrapper.sol";
import { IStablecoin } from "../../../../../contracts/interfaces/IStablecoin.sol";
import { DeadShares } from "../../../../../contracts/utils/DeadShares.sol";
import { BaseTest } from "../../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../../test/shared/mocks/MockIRM.sol";

/// Round-3 port of round-2 R2-M2 (verify/R2-MED-WRAPPER-INFLATION). HEAD Wrapper carries
/// DeadShares (Wrapper.sol:61-74, :81-85) and `script/deploy/service/DeployInfra.sol:193-201`
/// seeds 1e18 cUSD to `DeadShares.HOLDER` at deploy. The 1-wei first depositor is refused
/// (DepositBelowSeed) and a 1001-wei one holds 1/1001 of supply.
contract R2_M2_WrapperInflation is BaseTest {
    Stablecoin internal s;
    Wrapper internal w;
    MockERC20 internal usdc;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

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
                    (address(accessManager), address(usdc), "Cap USD", "cUSD", address(irm), address(0))
                )
            )
        );
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = IStablecoin.mintCreditBacked.selector;
        sels[1] = IStablecoin.fundCreditBacked.selector;
        accessManager.setTargetFunctionRole(address(s), sels, 0); // ADMIN = this
        w = Wrapper(
            _deployProxy(
                address(new Wrapper()), abi.encodeCall(Wrapper.initialize, (address(accessManager), address(s)))
            )
        );
        _dep(alice, 1000e18);
        _dep(bob, 1000e18);
    }

    function _dep(address a, uint256 amt) internal {
        usdc.mint(a, amt);
        vm.startPrank(a);
        usdc.approve(address(s), amt);
        s.deposit(amt, a);
        s.approve(address(w), type(uint256).max);
        vm.stopPrank();
    }

    function _wdep(address a, uint256 amt) internal returns (uint256 sh) {
        vm.prank(a);
        sh = w.deposit(amt, a);
    }

    function _wred(address a) internal returns (uint256 out) {
        uint256 bal = w.balanceOf(a);
        vm.prank(a);
        out = w.redeem(bal, a, a);
    }

    function _attackerIn(uint256 wei_) internal {
        s.mintCreditBacked(carol, wei_);
        vm.prank(carol);
        s.approve(address(w), wei_);
        _wdep(carol, wei_);
    }

    function test_oneWeiFirstDepositRefused() public {
        s.mintCreditBacked(carol, 1);
        vm.prank(carol);
        s.approve(address(w), 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(DeadShares.DepositBelowSeed.selector, 1, 1000));
        w.deposit(1, carol);
    }

    /// Round-2 reproduction with the smallest admissible first deposit: the victim is no longer
    /// zeroed and the attacker's take is 1/1001 of the pot.
    function test_repro_victimKeepsShares_attackerTakesDust() public {
        _attackerIn(1001);
        assertEq(w.balanceOf(carol), 1);
        s.fundCreditBacked(1_000e18);
        vm.warp(block.timestamp + 2 days);
        uint256 assetsBefore = w.totalAssets();
        uint256 vs = _wdep(alice, 400e18);
        uint256 fair = 400e18 * (w.totalSupply() - vs) / assetsBefore;
        uint256 out = _wred(carol);
        emit log_named_uint("wrapper assets before victim", assetsBefore);
        emit log_named_uint("victim shares", vs);
        emit log_named_uint("victim fair shares", fair);
        emit log_named_uint("attacker out (1001 wei in)", out);
        emit log_named_uint("victim redeemable", w.convertToAssets(vs));
        assertGe(vs, fair - 1, "victim gets fair shares");
        assertGe(w.convertToAssets(vs), 399e18, "victim keeps her deposit");
        assertLe(out, assetsBefore / 1000, "attacker take bounded to ~1/1001 of the pot");
        // no residual zero-share trap
        uint256 vs2 = _wdep(bob, 100e18);
        assertGt(vs2, 0, "next depositor mints shares");
    }

    /// Pre-funded (frozen) premium and a late 1001-wei first depositor: the pot goes 1000/1001 to
    /// DeadShares.HOLDER, i.e. it is burned rather than captured.
    function test_prefundedPremium_burnedToDeadShares() public {
        s.fundCreditBacked(1_000e18); // nobody staked: frozen
        vm.warp(block.timestamp + 30 days);
        _attackerIn(1001);
        vm.warp(block.timestamp + 2 days);
        uint256 total = w.totalAssets();
        uint256 dead = w.convertToAssets(w.balanceOf(DeadShares.HOLDER));
        uint256 out = _wred(carol);
        emit log_named_uint("wrapper totalAssets after late deposit", total);
        emit log_named_uint("value held by DeadShares.HOLDER (burned)", dead);
        emit log_named_uint("attacker out", out);
        assertLe(out, total / 1000, "attacker cannot capture the frozen pot");
        assertGt(dead, total * 99 / 100, "premium that vests while only the seed is staked is burned");
    }
}
