// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessUpgradeable } from "../access/AccessUpgradeable.sol";
import { INetwork } from "../interfaces/INetwork.sol";
import { DelegationStorage } from "./libraries/DelegationStorage.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Cap Delegation Contract
/// @author Cap Labs
/// @notice This contract manages delegation and slashing.
contract Delegation is UUPSUpgradeable, AccessUpgradeable {
    event SlashNetwork(address network, uint256 slashShare);
    event AddAgent(address agent, DataTypes.AgentData agentData);
    event ModifyAgent(address agent, DataTypes.AgentData agentData);
    event RegisterNetwork(address agent, address network);

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
    /// @return delegation Amount in USD that a agent has provided as delegation from the delegators
    function coverage(address _agent) public view returns (uint256 delegation) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        for (uint i; i < $.networks[_agent].length; ++i) {
            address network = $.networks[_agent][i];
            delegation += coverageByNetwork(_agent, network);
        }
    }

    /// @notice How much delegation and agent has available to back their borrows
    /// @param _agent The agent addres
    /// @param _network The network covering the agent
    /// @return delegation Amount in USD that a agent has as delegation from the networks
    function coverageByNetwork(address _agent, address _network) public view returns (uint256 delegation) {
        delegation = INetwork(_network).coverage(_agent);
    }

    /// @notice Fetch active network addresses
    /// @param _agent Agent address
    /// @return networkAddresses network addresses
    function networks(address _agent) external view returns (address[] memory networkAddresses) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        networkAddresses = $.networks[_agent];
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
    function liquidationThreshold(address _agent) external view returns (uint256 lt) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        lt = $.agentData[_agent].liquidationThreshold;
    }

    /// @notice The slash function. Calls the underlying networks to slash the delegated capital
    /// @dev Called only by the lender during liquidation
    /// @param _agent The agent who is unhealthy
    /// @param _liquidator The liquidator who receives the funds
    /// @param _amount The USD value of the delegation needed to cover the debt
    function slash(address _agent, address _liquidator, uint256 _amount) external checkAccess(this.slash.selector) {
        uint256 agentsDelegation = coverage(_agent);

        uint256 slashShare = _amount * 1e18 / agentsDelegation;

        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        for (uint i; i < $.networks[_agent].length; ++i) {
            address network = $.networks[_agent][i];
            INetwork(network).slash(_agent, _liquidator, slashShare);
            emit SlashNetwork(network, slashShare);
        }
    }

    /// @notice Add agent to be delegated to
    /// @param _agent Agent address
    /// @param _agentData Agent data
    function addAgent(address _agent, DataTypes.AgentData calldata _agentData)
        external
        checkAccess(this.addAgent.selector)
    {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.agents.push(_agent);
        $.agentData[_agent] = _agentData;
        emit AddAgent(_agent, _agentData);
    }

    /// @notice Modify an agents config only callable by the operator
    /// @param _agent the agent to modify
    /// @param _agentData the struct of data
    function modifyAgent(address _agent, DataTypes.AgentData calldata _agentData)
        external
        checkAccess(this.modifyAgent.selector)
    {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.agentData[_agent] = _agentData;
        emit ModifyAgent(_agent, _agentData);
    }

    /// @notice Register a new delagator
    /// @param _agent Agent address
    /// @param _network Network address
    function registerNetwork(address _agent, address _network)
        external
        checkAccess(this.registerNetwork.selector)
    {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.networks[_agent].push(_network);

        emit RegisterNetwork(_agent, _network);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
