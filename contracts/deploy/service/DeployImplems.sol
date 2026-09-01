// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { InterestRateModel } from "../../cap/InterestRateModel.sol";
import { Registry } from "../../cap/Registry.sol";
import { Stablecoin } from "../../cap/Stablecoin.sol";
import { Tranche } from "../../cap/Tranche.sol";
import { Underwriter } from "../../cap/Underwriter.sol";
import { Vault } from "../../cap/Vault.sol";
import { FixedMarket } from "../../cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../cap/market/FloatingMarket.sol";
import { ImplementationsConfig } from "../interfaces/DeployConfigs.sol";

contract DeployImplems {
    function _deployImplementations() internal returns (ImplementationsConfig memory implems) {
        implems.vault = address(new Vault());
        implems.stablecoin = address(new Stablecoin());
        implems.irm = address(new InterestRateModel());
        implems.registry = address(new Registry());
        implems.floatingMarket = address(new FloatingMarket());
        implems.fixedMarket = address(new FixedMarket());
        implems.tranche = address(new Tranche());
        implems.underwriter = address(new Underwriter());
    }
}
