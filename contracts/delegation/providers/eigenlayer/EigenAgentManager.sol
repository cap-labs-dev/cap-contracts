// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IDelegation } from "../../../interfaces/IDelegation.sol";
import { IEigenAgentManager } from "../../../interfaces/IEigenAgentManager.sol";
import { IEigenServiceManager } from "../../../interfaces/IEigenServiceManager.sol";
import { ILender } from "../../../interfaces/ILender.sol";
import { IOracle } from "../../../interfaces/IOracle.sol";
import { IRateOracle } from "../../../interfaces/IRateOracle.sol";
import { IVault } from "../../../interfaces/IVault.sol";

import { EigenAgentManagerStorageUtils } from "../../../storage/EigenAgentManagerStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract EigenAgentManager is IEigenAgentManager, UUPSUpgradeable, Access, EigenAgentManagerStorageUtils {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IEigenAgentManager
    function initialize(
        address _accessControl,
        address _lender,
        address _cusd,
        address _delegation,
        address _serviceManager,
        address _oracle
    ) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        EigenAgentManagerStorage storage $ = getEigenAgentManagerStorage();
        $.lender = _lender;
        $.cusd = _cusd;
        $.delegation = _delegation;
        $.serviceManager = _serviceManager;
        $.oracle = _oracle;
    }

    /// @inheritdoc IEigenAgentManager
    function addEigenAgent(AgentConfig calldata _agentConfig) external checkAccess(this.addEigenAgent.selector) {
        EigenAgentManagerStorage storage $ = getEigenAgentManagerStorage();

        /// 1. Add the agent to the delegation
        IDelegation($.delegation).addAgent(
            _agentConfig.agent, $.serviceManager, _agentConfig.ltv, _agentConfig.liquidationThreshold
        );

        /// 2. Add the agent to the network
        IEigenServiceManager($.serviceManager).registerStrategy(
            _agentConfig.strategy,
            _agentConfig.agent,
            _agentConfig.restaker,
            _agentConfig.avsMetadata,
            _agentConfig.operatorMetadata
        );

        /// 3. Add the agent to the rate oracle
        IRateOracle($.oracle).setRestakerRate(_agentConfig.agent, _agentConfig.delegationRate);
    }

    /// @inheritdoc IEigenAgentManager
    function setRestakerRate(address _agent, uint256 _delegationRate)
        external
        checkAccess(this.setRestakerRate.selector)
    {
        EigenAgentManagerStorage storage $ = getEigenAgentManagerStorage();
        address[] memory assets = IVault($.cusd).assets();
        for (uint256 i; i < assets.length; ++i) {
            (, uint256 unrealizedInterest) = ILender($.lender).maxRestakerRealization(_agent, assets[i]);
            if (unrealizedInterest > 0) {
                ILender($.lender).realizeRestakerInterest(_agent, assets[i]);
            }
        }

        IRateOracle($.oracle).setRestakerRate(_agent, _delegationRate);
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
