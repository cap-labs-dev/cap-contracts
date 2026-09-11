// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { Tranche } from "../../../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../../../contracts/cap/market/FloatingMarket.sol";
import { IRegistry } from "../../../../../../contracts/interfaces/IRegistry.sol";
import { CapDeployer } from "../../../../../../test/shared/CapDeployer.sol";
import { console } from "forge-std/Test.sol";

/// Port of round-1 F2_RegistryDefaults + D5_RegistrySeeds (L-4)
contract R2_L4_RegistryDefaults is CapDeployer {
    address alice = makeAddr("alice");

    function _one() internal pure returns (uint256[] memory w) {
        w = new uint256[](1);
        w[0] = 1e27;
    }

    function _rawMarket() internal returns (FloatingMarket market, address tranche) {
        if (registry.operatorRole(defaultMarketOwner) == 0) _assignOperator(defaultMarketOwner);
        if (registry.operatorRole(defaultBorrower) == 0) _assignOperator(defaultBorrower);
        (address m, address[] memory tranches) =
            registry.createFloatingMarket(_uniformAssets(1), _one(), "F", defaultMarketOwner, defaultBorrower);
        market = FloatingMarket(m);
        tranche = tranches[0];
    }

    /// F2: Registry.initialize should reject lt == buffer (setBuffer/setLt would)
    function test_L4_registryRejectsLtEqualBuffer() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultLt = 0.1e27;
        cfg.defaultBuffer = 0.1e27;
        (bool ok,) = address(this).call(abi.encodeCall(this.deployWith, (cfg)));
        console.log("deploy with lt==buffer reverted:", !ok);
        assertFalse(ok, "Registry.initialize accepted lt == buffer");
    }

    function deployWith(CapConfig memory cfg) external {
        _deployCapWithConfig(cfg);
    }

    /// F2 + D5: lt == buffer -> depositor can still redeem / unlockedSupply does not revert
    function test_L4_ltEqualBuffer_trancheExit() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultLt = 0.5e27;
        cfg.defaultBuffer = 0.5e27;
        _deployCapWithConfig(cfg);
        (FloatingMarket market, address tranche) = _rawMarket();
        assertEq(market.lt(), 0.5e27);
        assertEq(market.buffer(), 0.5e27);
        _fundTranche(tranche, alice, 1_000e18);
        assertGt(Tranche(tranche).balanceOf(alice), 0);
        (bool ok, bytes memory ret) = tranche.staticcall(abi.encodeWithSignature("unlockedSupply()"));
        console.log("unlockedSupply ok:", ok);
        if (!ok) console.logBytes(ret);
        assertTrue(ok, "unlockedSupply must not revert on registry-seeded parameters");
        vm.startPrank(alice);
        uint256 shares = Tranche(tranche).balanceOf(alice);
        (bool ok2, bytes memory ret2) =
            tranche.call(abi.encodeWithSignature("redeem(uint256,address,address)", shares, alice, alice));
        vm.stopPrank();
        console.log("redeem ok:", ok2);
        if (!ok2) console.logBytes(ret2);
        assertTrue(ok2, "depositor cannot exit when lt == buffer");
    }

    /// F2 + D5: targetHealth < (1+bonus)*lt -> unhealthy market must still be liquidatable
    function test_L4_lowTargetHealth_liquidatable() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultTargetHealth = 1e27;
        cfg.defaultLt = 1e27;
        cfg.defaultLiquidationBonus = 0.1e27;
        _deployCapWithConfig(cfg);
        (FloatingMarket market, address tranche) = _rawMarket();
        market.setLtv(0.8e27);
        market.setFixedCreditLimit(type(uint256).max);
        assertEq(market.targetHealth(), 1e27);
        _fundTranche(tranche, alice, 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        _setPrice(address(collateral), 0.4e18);
        assertLt(market.healthiness(), 1e27, "unhealthy");
        (bool ok, bytes memory ret) = address(market).staticcall(abi.encodeWithSignature("maxLiquidatable()"));
        console.log("maxLiquidatable ok:", ok);
        if (!ok) console.logBytes(ret);
        assertTrue(ok, "maxLiquidatable must not revert on registry-seeded parameters");
        _mintStable(defaultLiquidator, 500e18);
        vm.prank(defaultLiquidator);
        (bool ok2, bytes memory ret2) =
            address(market).call(abi.encodeCall(market.liquidate, (defaultLiquidator, 100e18)));
        console.log("liquidate ok:", ok2);
        if (!ok2) console.logBytes(ret2);
        assertTrue(ok2, "unhealthy market is un-liquidatable");
    }
}
