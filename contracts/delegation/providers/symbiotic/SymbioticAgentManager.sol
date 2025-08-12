// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { Access } from "../../../access/Access.sol";

import { IDelegation } from "../../../interfaces/IDelegation.sol";

import { IOracle } from "../../../interfaces/IOracle.sol";
import { IRateOracle } from "../../../interfaces/IRateOracle.sol";
import { ISymbioticAgentManager } from "../../../interfaces/ISymbioticAgentManager.sol";
import { ISymbioticNetworkMiddleware } from "../../../interfaces/ISymbioticNetworkMiddleware.sol";

import { SymbioticAgentManagerStorageUtils } from "../../../storage/SymbioticAgentManagerStorageUtils.sol";

contract SymbioticAgentManager is ISymbioticAgentManager, UUPSUpgradeable, Access, SymbioticAgentManagerStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ISymbioticAgentManager
    function initialize(address _accessControl, address _delegation, address _networkMiddleware, address _oracle)
        external
        initializer
    {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        SymbioticAgentManagerStorage storage $ = getSymbioticAgentManagerStorage();
        $.delegation = _delegation;
        $.networkMiddleware = _networkMiddleware;
        $.oracle = _oracle;
    }

    /// @inheritdoc ISymbioticAgentManager
    function addAgent(AgentConfig calldata _agentConfig) external checkAccess(this.addAgent.selector) {
        SymbioticAgentManagerStorage storage $ = getSymbioticAgentManagerStorage();

        /// 1. Add the agent to the delegation
        IDelegation($.delegation).addAgent(
            _agentConfig.agent, $.networkMiddleware, _agentConfig.ltv, _agentConfig.liquidationThreshold
        );

        /// 2. Add the agent to the network
        ISymbioticNetworkMiddleware($.networkMiddleware).registerVault(
            _agentConfig.vault, _agentConfig.rewarder, _agentConfig.agent
        );

        /// 3. Add the agent to the rate oracle
        IRateOracle($.oracle).setRestakerRate(_agentConfig.agent, _agentConfig.delegationRate);
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
