// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessUpgradeable } from "../access/AccessUpgradeable.sol";
import { INetwork } from "../delegation/interfaces/INetwork.sol";
import { DelegationStorage } from "./libraries/DelegationStorage.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Cap Delegation Contract
/// @author Cap Labs
/// @notice This contract manages delegation and slashing.
contract Delegation is UUPSUpgradeable, AccessUpgradeable {
    event SlashNetwork(address network, uint256 slashShare);
    event AddAgent(address agent, uint256 ltv, uint256 liquidationThreshold);
    event ModifyAgent(address agent, uint256 ltv, uint256 liquidationThreshold);
    event RegisterNetwork(address agent, address network);

    error AgentDoesNotExist();
    error DuplicateAgent();
    error DuplicateNetwork();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the contract
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _epochLength Epoch length in seconds
    function initialize(address _accessControl, address _oracle, uint256 _epochLength) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.oracle = _oracle;
        $.epochLength = _epochLength;
    }

    /// @notice How much global delegation we have in the system
    /// @return delegation Delegation in USD
    function globalDelegation() external view returns (uint256 delegation) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        for (uint i; i < $.agents.length; ++i) {
            delegation += coverage($.agents[i]);
        }
    }

    /// @notice Get the epoch duration
    /// @return duration Epoch duration in seconds
    function epochDuration() external view returns (uint256 duration) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        duration = $.epochLength;
    }

    /// @notice Get the current epoch
    /// @return currentEpoch Current epoch
    function epoch() external view returns (uint256 currentEpoch) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        currentEpoch = block.timestamp / $.epochLength;
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
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        uint256 agentsDelegation = coverage(_agent);
        
        // Track actual slashed amount
        uint256 totalSlashed;

        // Get the timestamp that is most recent between the last borrow and the epoch -1 
        uint256 slashTimestamp = Math.max((block.timestamp / $.epochLength - 1) * $.epochLength, $.agentData[_agent].lastBorrow);
        
        // Calculate each network's proportion of total delegation
        for (uint i; i < $.networks[_agent].length - 1; ++i) {
            address network = $.networks[_agent][i];
            uint256 networkCoverage = coverageByNetwork(_agent, network);
            
            // Calculate this network's share
            uint256 networkSlash = (_amount * networkCoverage) / agentsDelegation;
            totalSlashed += networkSlash;
            
            INetwork(network).slash(_agent, _liquidator, networkSlash, uint48(slashTimestamp));
            emit SlashNetwork(network, networkSlash);
        }
        
        // Last network gets the remainder to ensure exact total
        if ($.networks[_agent].length > 0) {
            address lastNetwork = $.networks[_agent][$.networks[_agent].length - 1];
            uint256 finalSlash = _amount - totalSlashed;
            
            INetwork(lastNetwork).slash(_agent, _liquidator, finalSlash, uint48(slashTimestamp));
            emit SlashNetwork(lastNetwork, finalSlash);
        }
    }

    function setLastBorrow(address _agent) external checkAccess(this.setLastBorrow.selector) {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();
        $.agentData[_agent].lastBorrow = block.timestamp;
    }

    /// @notice Add agent to be delegated to
    /// @param _agent Agent address
    /// @param _ltv Loan to value ratio
    /// @param _liquidationThreshold Liquidation threshold
    function addAgent(address _agent, uint256 _ltv, uint256 _liquidationThreshold)
        external
        checkAccess(this.addAgent.selector)
    {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();

        // If the agent already exists, we revert
        for (uint i; i < $.agents.length; ++i) {
            if ($.agents[i] == _agent) revert DuplicateAgent();
        }

        $.agents.push(_agent);
        $.agentData[_agent].ltv = _ltv;
        $.agentData[_agent].liquidationThreshold = _liquidationThreshold;
        emit AddAgent(_agent, _ltv, _liquidationThreshold);
    }

    /// @notice Modify an agents config only callable by the operator
    /// @param _agent the agent to modify
    /// @param _ltv Loan to value ratio
    /// @param _liquidationThreshold Liquidation threshold
    function modifyAgent(address _agent, uint256 _ltv, uint256 _liquidationThreshold)
        external
        checkAccess(this.modifyAgent.selector)
    {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();

        // Check that the agent exists
        for (uint i; i < $.agents.length; ++i) {
            if ($.agents[i] == _agent) {
                $.agentData[_agent].ltv = _ltv;
                $.agentData[_agent].liquidationThreshold = _liquidationThreshold;
                emit ModifyAgent(_agent, _ltv, _liquidationThreshold);
                return;
            }
        }
        revert AgentDoesNotExist();
    }

    /// @notice Register a new network
    /// @param _agent Agent address
    /// @param _network Network address
    function registerNetwork(address _agent, address _network)
        external
        checkAccess(this.registerNetwork.selector)
    {
        DataTypes.DelegationStorage storage $ = DelegationStorage.get();

        // Check for duplicates
        for (uint i; i < $.networks[_agent].length; ++i) {
            if ($.networks[_agent][i] == _network) revert DuplicateNetwork();
        }

        $.networks[_agent].push(_network);

        emit RegisterNetwork(_agent, _network);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
