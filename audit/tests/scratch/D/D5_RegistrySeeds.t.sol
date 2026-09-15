// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";

/// @notice WS-D / H8. Registry.initialize stores lt/buffer/targetHealth with no validation and has
/// no setters; BaseMarket copies them at init. Values the market's own setters reject therefore
/// reach every market: targetHealth below perDebt*lt makes maxLiquidatable underflow (liquidation
/// bricked until GOVERNOR repairs each market); lt == buffer makes lockedValue divide by zero
/// (every tranche withdrawal bricked until GUARDIAN repairs each market).
contract D5_RegistrySeeds is CapDeployer {
    function test_targetHealthBelowFloor_bricksLiquidation() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultTargetHealth = 1e27; // setTargetHealth would reject (< 1.25e27)
        cfg.defaultLt = 1e27;
        cfg.defaultLiquidationBonus = 0.1e27; // perDebt*lt = 1.1e27 > targetHealth
        _deployCapWithConfig(cfg);

        // build the market without _applyMarketDefaults (which would call setTargetHealth)
        (address m, address[] memory tranches) =
            registry.createMarket(_uniformAssets(1), _one(), "F", defaultMarketOwner, defaultBorrower);
        FloatingMarket market = FloatingMarket(m);
        market.setLtv(0.8e27);
        market.setFixedCreditLimit(type(uint256).max);
        _fundTranche(tranches[0], makeAddr("uw"), 1_000e18);
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, type(uint256).max);
        oracle.setPrice(address(collateral), 0.5e18);
        assertLt(market.healthiness(), 1e27, "unhealthy");

        // maxLiquidatable reverts on `targetHealth - perDebt*lt` underflow
        (bool ok,) = address(market).staticcall(abi.encodeWithSignature("maxLiquidatable()"));
        assertTrue(ok, "maxLiquidatable must not revert on registry-seeded parameters");
    }

    function test_ltEqualsBuffer_bricksTrancheWithdrawals() public {
        CapConfig memory cfg = _defaultCapConfig();
        cfg.defaultLt = 0.5e27;
        cfg.defaultBuffer = 0.5e27; // setBuffer would reject (>= lt)
        _deployCapWithConfig(cfg);
        (address m, address[] memory tranches) =
            registry.createMarket(_uniformAssets(1), _one(), "F", defaultMarketOwner, defaultBorrower);
        _fundTranche(tranches[0], makeAddr("uw"), 1_000e18);
        (bool ok,) = tranches[0].staticcall(abi.encodeWithSignature("unlockedSupply()"));
        assertTrue(ok, "unlockedSupply must not revert on registry-seeded parameters");
    }

    function _one() internal pure returns (uint256[] memory w) {
        w = new uint256[](1);
        w[0] = 1e27;
    }
}
