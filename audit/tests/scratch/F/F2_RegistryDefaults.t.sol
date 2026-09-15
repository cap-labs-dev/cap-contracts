// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { console } from "forge-std/Test.sol";

import { Registry } from "../../../../contracts/cap/Registry.sol";
import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { IRegistry } from "../../../../contracts/interfaces/IRegistry.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// WS-F. Registry.initialize stores lt / buffer / targetHealth with no validation, there is no
/// setter for them afterwards, and every market created copies them verbatim in
/// __BaseMarket_init. BaseMarket's own setters enforce lt > buffer, lt <= 1e27 and
/// targetHealth >= 1.25e27, so a registry default outside that range produces markets that the
/// setters themselves would have refused.
contract F2_RegistryDefaults is CapDeployer {
    address alice = makeAddr("alice");

    function _createRawMarket() internal returns (address market, address tranche) {
        address[] memory assets = new address[](1);
        assets[0] = address(collateral);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1e27;
        address[] memory tranches;
        (market, tranches) = registry.createMarket(assets, weights, "raw", defaultMarketOwner, defaultBorrower);
        tranche = tranches[0];
    }

    /// FAILS on current code: Registry.initialize accepts lt == buffer (and lt < buffer, lt > 1e27)
    function test_F2_registryRejectsLtEqualBuffer() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultLt = 0.1e27;
        cfg.defaultBuffer = 0.1e27;
        vm.expectRevert();
        _deployCapWithConfig(cfg);
    }

    /// FAILS on current code: a market created with lt == buffer accepts deposits but every
    /// redemption path reverts (lockedValue divides by lt - buffer == 0 -> WadRayMath.rayDiv
    /// reverts), until a GUARDIAN notices and calls setLt.
    function test_F2_marketWithLtEqualBuffer_depositorCanRedeem() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultLt = 0.1e27;
        cfg.defaultBuffer = 0.1e27;
        _deployCapWithConfig(cfg);

        (address market, address tranche) = _createRawMarket();
        assertEq(FloatingMarket(market).lt(), 0.1e27);
        assertEq(FloatingMarket(market).buffer(), 0.1e27);

        _fundTranche(tranche, alice, 100e18); // deposit works
        assertGt(Tranche(tranche).balanceOf(alice), 0);

        // but the redemption side is dead: maxRedeem / redeem / requestRedeem-claim all route
        // through unlockedSupply -> lockedValue -> rayDiv(lt - buffer = 0)
        vm.prank(alice);
        Tranche(tranche).redeem(1e18, alice, alice);
    }

    /// FAILS on current code: a market whose registry default targetHealth is below
    /// 1 + liquidationBonus * lt is unhealthy but cannot be liquidated (maxLiquidatable underflows),
    /// until GOVERNOR calls setTargetHealth.
    function test_F2_marketWithLowTargetHealth_isLiquidatable() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultTargetHealth = 0.5e27; // setTargetHealth would refuse anything < 1.25e27
        _deployCapWithConfig(cfg);

        (address marketAddr, address tranche) = _createRawMarket();
        FloatingMarket market = FloatingMarket(marketAddr);
        market.setLtv(cfg.defaultLtv);
        market.setFixedCreditLimit(1_000e18);
        assertEq(market.targetHealth(), 0.5e27);

        _fundTranche(tranche, alice, 1000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);

        oracle.setPrice(address(collateral), 0.5e18);
        assertLt(market.healthiness(), 1e27, "unhealthy");

        _mintStable(defaultLiquidator, 500e18);
        vm.prank(defaultLiquidator);
        market.liquidate(defaultLiquidator, 100e18);
    }
}
