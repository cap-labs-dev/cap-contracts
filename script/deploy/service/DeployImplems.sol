// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { InterestRateModel } from "../../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../contracts/cap/Underwriter.sol";
import { Vault } from "../../../contracts/cap/Vault.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { FixedMarket } from "../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../contracts/cap/market/FloatingMarket.sol";
import { Oracle } from "../../../contracts/cap/oracle/Oracle.sol";
import { ImplementationsConfig } from "../interfaces/DeployConfigs.sol";

contract DeployImplems {
    /// @dev Deploy every implementation the infrastructure proxies and beacons point at
    /// @return implems The implementation addresses
    function _deployImplementations() internal returns (ImplementationsConfig memory implems) {
        implems.vault = address(new Vault());
        implems.stablecoin = address(new Stablecoin());
        implems.irm = address(new InterestRateModel());
        implems.oracle = address(new Oracle());
        implems.registry = address(new Registry());
        implems.floatingMarket = address(new FloatingMarket());
        implems.fixedMarket = address(new FixedMarket());
        implems.tranche = address(new Tranche());
        implems.underwriter = address(new Underwriter());
        implems.wrapper = address(new Wrapper());
    }
}
