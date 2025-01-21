// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { DataTypes } from "./libraries/types/DataTypes.sol";
import { AccessUpgradeable } from "../access/AccessUpgradeable.sol";
import { DelegationStorage } from "./libraries/DelegationStorage.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IProvider } from "./interfaces/IProvider.sol";

/// @title Cap Delegation Contract
/// @author Cap Labs
/// @notice This contract manages delegation and slashing.
contract Delegation is UUPSUpgradeable, AccessUpgradeable {
    event SlashProvider(address provider, uint256 amount);
    event AddAgent(address agent, DataTypes.AgentData agentData);
    event ModifyAgent(address agent, DataTypes.AgentData agentData);
    event RegisterProvider(address provider);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    function initialize(address _accessControl, address _oracle) external initializer {
        __Access_init(_accessControl);
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.oracle = _oracle;
    }

    /// @notice How much global delegation we have in the system
    /// @return delegation Delegation in USD
    function globalDelegation() external view returns (uint256 delegation) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        for (uint i; i < $.agents.length; ++i) {
            delegation += coverage($.agents[i]);
        }
    }

    /// @notice How much delegation and agent has available to back their borrows
    /// @param _agent The agent address
    /// @return delegation Amount in USD that a agent has provided as delegation from the providers
    function coverage(address _agent) public view returns (uint256 delegation) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        for (uint i; i < $.providers.length; ++i) {
            address provider = $.providers[i];
            delegation += coverageByProvider(_agent, provider);
        }
    }

    /// @notice How much delegation and agent has available to back their borrows
    /// @param _agent The agent addres
    /// @param _provider The provider covering the agent
    /// @return delegation Amount in USD that a agent has as delegation from the providers
    function coverageByProvider(address _agent, address _provider) public view returns (uint256 delegation) {
        delegation = IProvider(_provider).coverage(_agent);
    }

    /// @notice Fetch active provider addresses
    /// @return providerAddresses Provider addresses
    function providers() external view returns (address[] memory providerAddresses) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        providerAddresses = $.providers;
    }

    /// @notice Fetch active agent addresses
    /// @return agentAddresses Agent addresses
    function agents() external view returns (address[] memory agentAddresses) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        agentAddresses = $.agents;
    }

    /// @notice The LTV of a specific agent
    /// @param _agent Agent who we are querying 
    /// @return currentLtv Loan to value ratio of the agent
    function ltv(address _agent) external view returns (uint256 currentLtv) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        currentLtv = $.agentData[_agent].ltv;
    }

    /// @notice Liquidation threshold of the agent
    /// @param _agent Agent who we are querying
    /// @return lt Liquidation threshold of the agent
    function liquidiationThreshold(address _agent) external view returns (uint256 lt) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        lt = $.agentData[_agent].liquidationThreshold;
    }

    /// @notice The slash function. Calls the underlying providers to slash the delegated capital
    /// @dev Called only by the lender during liquidation
    /// @param _agent The agent who is unhealthy
    /// @param _liquidator The liquidator who receives the funds
    /// @param _amount The USD value of the delegation needed to cover the debt
    function slash(address _agent, address _liquidator, uint256 _amount) external checkAccess(this.slash.selector) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        uint256 agentsDelegation = coverage(_agent);

        uint256 divisor = _amount * 1e18 / agentsDelegation;

        for (uint i; i < $.providers.length; ++i) {
            address provider = $.providers[i];
            uint256 providersDelegation = coverageByProvider(_agent, provider);
            uint256 slashAmount = providersDelegation * 1e18 / divisor;

            IProvider(provider).slash(_agent, _liquidator, slashAmount);
            emit SlashProvider(provider, slashAmount);
        }
    }

    /// @notice Add agent to be delegated to
    /// @param _agent Agent address
    /// @param _agentData Agent data
    function addAgent(address _agent, DataTypes.AgentData calldata _agentData) external checkAccess(this.addAgent.selector) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.agents.push(_agent);
        $.agentData[_agent] = _agentData;
        emit AddAgent(_agent, _agentData);
    }

    /// @notice Modify an agents config only callable by the operator 
    /// @param _agent the agent to modify
    /// @param _agentData the struct of data
    function modifyAgent(address _agent, DataTypes.AgentData calldata _agentData) external checkAccess(this.modifyAgent.selector) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.agentData[_agent] = _agentData;
        emit ModifyAgent(_agent, _agentData);
    }

    /// @notice Register a new provider
    /// @param _provider Provider address
    function registerProvider(address _provider) external checkAccess(this.registerProvider.selector) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.providers.push(_provider);
        emit RegisterProvider(_provider);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) {}
}
