// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SymbioticUtils } from "../../../../../contracts/deploy/utils/SymbioticUtils.sol";
import { MockERC20 } from "../../../../mocks/MockERC20.sol";
import { TestEnvConfig } from "../../../interfaces/TestDeployConfig.sol";
import { TimeUtils } from "../../../utils/TimeUtils.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

contract InitSymbioticVaultLiquidity is SymbioticUtils, TimeUtils {
    function _initSymbioticVaultsLiquidity(TestEnvConfig memory env) internal {
        for (uint256 i = 0; i < env.symbiotic.vaults.length; i++) {
            address vault = env.symbiotic.vaults[i];
            for (uint256 j = 0; j < env.testUsers.agents.length; j++) {
                address agent = env.testUsers.agents[j];
                _initSymbioticVaultLiquidityForAgent(vault, agent, 30_000);
            }
        }

        _timeTravel(7 days);
    }

    function _initSymbioticVaultLiquidityForAgent(address vault, address agent, uint256 amountNoDecimals)
        internal
        returns (uint256 depositedAmount, uint256 mintedShares)
    {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

        address collateral = IVault(vault).collateral();
        uint256 amount = amountNoDecimals * 10 ** MockERC20(collateral).decimals();
        MockERC20(collateral).mint(agent, amount);

        vm.startPrank(agent);
        MockERC20(collateral).approve(address(vault), amount);
        (depositedAmount, mintedShares) = IVault(vault).deposit(agent, amount);
    }
}
