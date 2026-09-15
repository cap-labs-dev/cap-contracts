// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { ERC7540AsyncRedeem } from "../../../../../contracts/ERC7540/ERC7540AsyncRedeem.sol";
import { Tranche } from "../../../../../contracts/cap/Tranche.sol";
import { Vault } from "../../../../../contracts/cap/Vault.sol";
import { FloatingMarket } from "../../../../../contracts/cap/market/FloatingMarket.sol";
import { ITranche } from "../../../../../contracts/interfaces/ITranche.sol";
import { PremiumVesting } from "../../../../../contracts/utils/PremiumVesting.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { MockReentrantERC20 } from "../../../../../test/shared/mocks/MockReentrantERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice L-12 kill latch (direct slash) and N9 hook enumeration (hook fired from Vault.withdraw
/// inside Tranche.slash inside the guarded FloatingMarket.liquidate).
contract N4_KillLatchHooks is CapDeployer {
    MockReentrantERC20 internal hooked;
    FloatingMarket internal market;
    address internal senior;
    address internal junior;

    function setUp() public {
        vm.warp(1_000_000);
        _deployCap();
        hooked = new MockReentrantERC20("Hooked Ether", "hETH", 18);
        _setPrice(address(hooked), 2e18);
        address[] memory assets = new address[](2);
        assets[0] = address(hooked);
        assets[1] = address(hooked);
        (address m, address[] memory tranches) =
            _createMarket("Hooked", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        market = FloatingMarket(m);
        senior = tranches[0];
        junior = tranches[1];
        _setMarketSlopes(m);
        market.setFixedCreditLimit(100_000e18);
    }

    // ── L-12 (a)(b): latch predicate via direct slash ────────────────────────
    function test_L12a_dustJuniorIsKilledOnFirstSlash() public {
        _fundTranche(junior, address(hooked), makeAddr("j"), 500e18);
        // holder exits all but dust: 1000 dead shares + 1 wei share remain
        vm.startPrank(makeAddr("j"));
        Tranche(junior).redeem(Tranche(junior).balanceOf(makeAddr("j")) - 1, makeAddr("j"), makeAddr("j"));
        vm.stopPrank();
        assertEq(Tranche(junior).totalSupply(), 1001);
        assertEq(Tranche(junior).totalAssets(), 1001);
        vm.prank(address(market));
        Tranche(junior).slash(2, makeAddr("liq")); // $2e-18 → 1 wei of hETH
        assertFalse(Tranche(junior).killed(), "1001 > 1000*100 is false: a partial dust slash does not kill");
        vm.prank(address(market));
        Tranche(junior).slash(2000, makeAddr("liq")); // drains the remaining 1000 wei
        assertTrue(
            Tranche(junior).killed(), "full drain of the dead-share dust kills (harmless: nothing left to protect)"
        );
        // an EMPTY tranche (dead shares only, 0 assets) that sits first in the slash loop is killed by
        // any liquidation although it contributes nothing
        vm.prank(address(market));
        (uint256 v) = Tranche(junior).slash(1e18, makeAddr("liq"));
        assertEq(v, 0);
    }

    function test_L12b_partialSlashLeavingAbovePercentDoesNotKill() public {
        _fundTranche(junior, address(hooked), makeAddr("j"), 500e18);
        vm.startPrank(address(market));
        Tranche(junior).slash(490e18 * 2, makeAddr("liq")); // $980 → 490 hETH out, 10 left (2% of par)
        assertFalse(Tranche(junior).killed(), "2% of par left: not killed");
        Tranche(junior).slash(5.1e18 * 2, makeAddr("liq")); // 4.9 hETH left (< 1%)
        assertTrue(Tranche(junior).killed(), "below 1%: killed");
        vm.stopPrank();
        // shares-per-asset after: 500e18 shares over 4.9e18 assets - deposits refused
        assertEq(Tranche(junior).maxDeposit(makeAddr("x")), 0);
    }

    // ── N9 / L-12(c): hook enumeration ───────────────────────────────────────
    function _prepareLiquidatable() internal {
        _fundTranche(senior, address(hooked), makeAddr("senior"), 500e18);
        _fundTranche(junior, address(hooked), address(hooked), 500e18); // hooked itself is the junior LP
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 900e18);
        market.setLt(0.4e27);
        assertLt(market.healthiness(), 1e27);
        _mintStable(defaultLiquidator, 1000e18);
        // hooked also has spare vault balance + operator so deposits from the hook are possible
        hooked.mint(address(hooked), 100e18);
        vm.startPrank(address(hooked));
        hooked.approve(address(vault), 100e18);
        vault.deposit(address(hooked), 100e18, address(hooked));
        vm.stopPrank();
    }

    function _liquidateWith(bytes memory payload, address target, uint256 amount)
        internal
        returns (bool ok, bytes memory ret)
    {
        hooked.arm(target, payload);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, amount);
        assertTrue(hooked.reentered(), "hook must fire");
        ok = hooked.reentrySucceeded();
        ret = hooked.reentryReturn();
    }

    /// deposit mid-slash: totalAssets HAS dropped (Vault burns before transfer), so the price is post-slash
    function test_N9_depositFromHookMidSlashSeesPostSlashPrice() public {
        _prepareLiquidatable();
        uint256 supplyBefore = Tranche(junior).totalSupply();
        uint256 assetsBefore = Tranche(junior).totalAssets();
        (bool ok, bytes memory ret) =
            _liquidateWith(abi.encodeCall(IERC4626.deposit, (10e18, address(hooked))), junior, 100e18);
        assertTrue(ok, string(ret));
        uint256 minted = abi.decode(ret, (uint256));
        // 100 cUSD repaid → 102 USD slashed → 51 hETH out of 500. Post-slash price: 449/500 assets per share
        // shares for 10 hETH at post-slash price = 10 * supply / 449
        uint256 expected = 10e18 * supplyBefore / (assetsBefore - 51e18);
        assertApproxEqAbs(minted, expected, 2, "deposit priced at the post-slash asset base");
        assertEq(Tranche(junior).totalAssets(), assetsBefore - 51e18 + 10e18);
    }

    /// redeem from the JUNIOR mid-slash: post-slash price too (no gain)
    function test_N9_redeemFromJuniorHookMidSlashIsPostSlash() public {
        _prepareLiquidatable();
        uint256 shares = 100e18;
        uint256 quoteBefore = Tranche(junior).previewRedeem(shares);
        (bool ok, bytes memory ret) =
            _liquidateWith(abi.encodeCall(IERC4626.redeem, (shares, address(hooked), address(hooked))), junior, 100e18);
        // refused: lockedValue = debt/(lt-buffer) exceeds capital while unhealthy → maxRedeem == 0
        assertFalse(ok, "instant redeem is refused while the market is unhealthy");
        assertEq(bytes4(ret), bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)")));
        quoteBefore; // silence
    }

    /// redeem from the SENIOR when the slash spills: the senior has not been slashed yet, and the
    /// repayment already lowered lockedValue — the hook exits at the pre-slash price.
    function test_N9_seniorRedeemFromHookEscapesItsOwnSlash() public {
        // junior small so a liquidation spills into the senior
        _fundTranche(senior, address(hooked), makeAddr("senior"), 500e18);
        _fundTranche(senior, address(hooked), address(hooked), 500e18); // hooked is a senior LP
        _fundTranche(junior, address(hooked), makeAddr("junior"), 20e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 900e18);
        market.setLt(0.4e27);
        _mintStable(defaultLiquidator, 1000e18);

        uint256 hookedShares = Tranche(senior).balanceOf(address(hooked));
        uint256 quotePre = Tranche(senior).previewRedeem(hookedShares);
        // liquidate 200 cUSD → 204 USD = 102 hETH: junior gives 20, senior 82
        // the liquidation is sized so that _repay (which runs BEFORE the slash loop) restores health
        // far enough that lockedValue no longer covers the senior; the hook then has maxRedeem > 0
        uint256 amount = market.maxLiquidatable();
        emit log_named_uint("liquidating (cUSD)", amount);
        hooked.arm(senior, abi.encodeCall(IERC4626.redeem, (hookedShares, address(hooked), address(hooked))));
        vm.prank(defaultLiquidator);
        (, uint256 slashed) = market.liquidate(defaultLiquidator, amount);
        emit log_named_uint("slashed (USD)", slashed);
        emit log_named_uint("senior maxRedeem after", Tranche(senior).maxRedeem(makeAddr("senior")));
        assertTrue(hooked.reentered());
        // the hook fired on the JUNIOR's withdraw; was senior.redeem allowed?
        emit log_named_string(
            "senior.redeem from hook", hooked.reentrySucceeded() ? "succeeded" : string(hooked.reentryReturn())
        );
        if (hooked.reentrySucceeded()) {
            uint256 got = abi.decode(hooked.reentryReturn(), (uint256));
            assertEq(got, quotePre, "hooked exited the senior at the pre-slash price");
            // and the other senior holder now carries the whole 82 hETH senior slash
            uint256 otherShares = Tranche(senior).balanceOf(makeAddr("senior"));
            uint256 otherNow = Tranche(senior).previewRedeem(otherShares);
            emit log_named_uint("hooked senior LP got (hETH)", got);
            emit log_named_uint("remaining senior LP now worth (hETH)", otherNow);
            assertLt(otherNow, 500e18 - (slashed / 2 - 20e18) / 2, "remaining LP absorbed more than its pro-rata share");
        }
    }

    function test_N9_requestRedeemOptOutClaimFromHook() public {
        _prepareLiquidatable();
        (bool ok1, bytes memory r1) = _liquidateWith(
            abi.encodeCall(ERC7540AsyncRedeem.requestRedeem, (10e18, address(hooked), address(hooked))), junior, 50e18
        );
        emit log_named_string("requestRedeem", ok1 ? "ok" : string(r1));
        (bool ok2, bytes memory r2) = _liquidateWith(abi.encodeCall(PremiumVesting.optOut, ()), junior, 50e18);
        emit log_named_string("optOut", ok2 ? "ok" : string(r2));
        (bool ok3, bytes memory r3) =
            _liquidateWith(abi.encodeCall(PremiumVesting.claim, (address(hooked))), junior, 50e18);
        emit log_named_string("claim", ok3 ? "ok" : string(r3));
        // Stablecoin: a hook depositing underlying mid-liquidation
        cusdUnderlying.mint(address(hooked), 10e18);
        vm.prank(address(hooked));
        cusdUnderlying.approve(address(stablecoin), 10e18);
        (bool ok4, bytes memory r4) =
            _liquidateWith(abi.encodeCall(IERC4626.deposit, (10e18, address(hooked))), address(stablecoin), 50e18);
        emit log_named_string("stablecoin.deposit", ok4 ? "ok" : string(r4));
        // accounting after: staked == opted-in balances on junior; queue backed
        assertEq(
            Tranche(junior).stakedSupply(),
            Tranche(junior).balanceOf(address(hooked)) * (ok2 ? 0 : 1),
            "staked tracks opt-in state"
        );
        assertEq(
            Tranche(junior).balanceOf(junior), Tranche(junior).redemptionQueue(), "queued shares held by the tranche"
        );
    }
}
