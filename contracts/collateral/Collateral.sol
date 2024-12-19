// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {INetwork} from "./interfaces/INetwork.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/// @title Cap Collateral Contract
/// @author Cap Labs
/// @notice This contract manages collateral and slashing.
contract Collateral is 
    AccessControlEnumerableUpgradeable,
    UUPSUpgradeable
{
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    address public lender;
    address public oracle;
    address[] public activeAgents;

    struct Agent {
        uint maxCollateral;
        uint maxCollateralPerProvider;
        uint ltv;
        uint liquidationThreshold;
        uint rate;
    }

    struct Provider {
        address asset;
        address network;
        uint256 collateral; 
        bool isSlashed;
    }

    mapping(address => Agent) public agents;
    mapping(address => address) public optIns;
    mapping(address => bool) public isNetwork;
    mapping(address => Provider) public providers;
    mapping(address => mapping(address => uint256)) public providerAgentCollateral;
    mapping(address => address[]) public agentCollateralProviders;

    error NotNetwork();
    error NotProvider();
    error NotLender();
    error NotEnoughCollateral();
    error AlreadyOptedIn();
    error MaxCollateralExceeded();
    error MaxCollateralProviderExceeded();
    error NoNetwork();
    error ProviderIsSlashed();

    event ProviderRegistered(address provider);
    event OptIn(address provider, address agent, uint256 amount);
    event OptOut(address provider, address bagent, uint256 amount);
    event SlashProvider(address provider, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the contract. 
     * @param _lender The Lender contract which agents use to borrow funds. 
     */
    function initialize(address _lender, address _oracle) external initializer {
        __AccessControlEnumerable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OWNER_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        lender = _lender;
        oracle = _oracle;
    }

    /**
     * @notice Only Networks can call a certain function. 
     */
    function _onlyNetwork() private view {
        if (!isNetwork[msg.sender]) revert NotNetwork();
    }
    
    /**
     * @notice Only Providers can call a certain function. 
     */
    function _onlyProvider() private view {
        if (providers[msg.sender].asset != address(0)) revert NotProvider();
    }

    /**
     * @notice Only the Lender can call a certain function. 
     */
    function _onlyLender() private view {
        if (msg.sender != lender) revert NotLender();
    }

    /**
     * @notice How much global collateral we have in the system
     * @return _collateral in USD
     */
    function globalCollateral() external view returns (uint256 _collateral) {
        for (uint i; i < activeAgents.length; ++i) {
            address[] memory agentsProviders = agentCollateralProviders[activeAgents[i]];
            for (uint j; j < agentsProviders.length; ++j) {
                _collateral += _convertToUsd(providerAgentCollateral[activeAgents[i]][agentsProviders[i]], providers[agentsProviders[i]].asset);
            }
        }
    }


    function collateralByNetwork(address) external view returns (uint256) {}
    function collateralByProvider(address) external view returns (uint256) {}

    function restakerRate(address) external pure returns (uint256 _rate) {
        /// To do
        uint256 rate = _rate;
        return rate;
    }

    /**
     * @notice How much collateral and agent has available to back their borrows
     * @param _agent The borrower from the lender
     * @return _collateral amount in USD that a agent has provided as collateral from the providers
     */
    function coverage(address _agent) public view returns (uint256 _collateral) {
        address[] memory agentsProviders = agentCollateralProviders[_agent];
        for (uint i; i < agentsProviders.length; ++i) {
            _collateral += _convertToUsd(providerAgentCollateral[_agent][agentsProviders[i]], providers[agentsProviders[i]].asset);
        }
    }

    /**
     * @notice Using the Cap oracle convert to USD
     * @param _amount amount of asset to convert 
     * @param _asset asset to convert 
     * @return value in USD
     */
    function _convertToUsd(uint256 _amount, address _asset) private view returns (uint256) {
        return _amount * IOracle(oracle).price(_asset);
    }

    /**
     * @notice Using the Cap oracle convert from USD
     * @param _amount amount of USD to convert 
     * @param _asset asset to convert 
     * @return value in asset
     */
    function _convertFromUsd(uint256 _amount, address _asset) private view returns (uint256) {
        return _amount * 1e18 / IOracle(oracle).price(_asset); 
    }

    /**
     * The LTV of a specific agent, called by the Lender
     * @param _agent the agent who we are querying 
     * @return _ltv the ltv of the agent
     */
    function ltv(address _agent) external view returns (uint256 _ltv) {
        return agents[_agent].ltv;
    }

    /**
     * @notice the liquidation threshold of the agent
     * @param _agent the agent who we are querying
     * @return _lt the liquidation threshold of the agent
     */
    function liquidiationThreshold(address _agent) external view returns (uint256 _lt) {
        return agents[_agent].liquidationThreshold;
    }

    /**
     * @notice the list of all agents that are registered in the system
     * @return _agents agent list
     */
    function agentsList() external view returns (address[] memory _agents) {
        for (uint i; i < activeAgents.length; ++i) {
            _agents[i] = activeAgents[i];
        }
    }

    /**
     * @notice The slash function. Calls the underlying network to slash the provider.
     * @dev Called only by the lender during liquidation
     * @param _agent The agent who is in bad debt
     * @param _amount The USD value of the collateral needed to cover the bad debt
     */
    function slash(address _agent, uint _amount) external {
        _onlyLender();
        
        address[] memory agentsProviders = agentCollateralProviders[_agent];

        uint256 agentsCollateral = coverage(_agent);

        uint256 divisor = _amount  * 1e18 / agentsCollateral;

        for (uint i; i < agentsProviders.length; ++i) {
            address provider = agentsProviders[i];
            address network = providers[provider].network;
            providers[provider].isSlashed = true;

            uint256 providersCollateral = _convertToUsd(providerAgentCollateral[_agent][provider], providers[provider].asset);

            uint256 slashAmount = _convertFromUsd(providersCollateral * 1e18 / divisor, providers[provider].asset);
            INetwork(network).slashProvider(provider, slashAmount);

            emit SlashProvider(provider, slashAmount);
        }
    }

    /**
     * @notice Ability to opt in to multiple agents at once
     * @param _agents the agents to opt in to
     * @param _amountsCollateral the amount of collateral to opt in with
     */
    function optIn(address[] calldata _agents, uint[] calldata _amountsCollateral) external {
        for (uint i; i < _agents.length; ++i) {
            optIn(_agents[i], _amountsCollateral[i]);
        }
    }

    /**
     * @notice Opt in to an agent
     * @param _agent The agent to opt in to
     * @param _amountCollateral the amount of collateral to opt in with
     */
    function optIn(address _agent, uint _amountCollateral) private {
        _onlyProvider();

        address _network = providers[msg.sender].network;

        Agent memory storedAgent = agents[_agent];

        uint256 amountCollateralInUsd = _convertToUsd(_amountCollateral, providers[msg.sender].asset);
        if (coverage(_agent) + amountCollateralInUsd > storedAgent.maxCollateral) revert MaxCollateralExceeded();
        if (amountCollateralInUsd > storedAgent.maxCollateralPerProvider) revert MaxCollateralProviderExceeded();

        // Store the collateral as the underlying asset value mapped agent -> provider -> underlying collateral
        uint256 current = providerAgentCollateral[_agent][msg.sender]; 

        if (providers[msg.sender].collateral + _amountCollateral > INetwork(_network).collateralByProvider(msg.sender)) revert NotEnoughCollateral();
        if (current > 0) revert AlreadyOptedIn();
        providerAgentCollateral[_agent][msg.sender] = _amountCollateral;
        providers[msg.sender].collateral += _amountCollateral;
        
        agentCollateralProviders[_agent].push(msg.sender);
       
        emit OptIn(msg.sender, _agent, _amountCollateral);
    }


    /**
     * @notice Opt out of multiple agents at once
     * @param _agents the agents to opt out of
     */
    function optOut(address[] calldata _agents) external {
        for (uint i; i < _agents.length; ++i) {
            optOut(_agents[i]);
        }
    }

    /**
     * @notice Opt out of an agent 
     * @param _agent the agent to opt out of
     */
    function optOut(address _agent) public {
        _onlyProvider();

        if (providers[msg.sender].isSlashed) revert ProviderIsSlashed();

        uint256 amount = providerAgentCollateral[msg.sender][_agent];
        providerAgentCollateral[msg.sender][_agent] = 0;

        emit OptOut(msg.sender, _agent, amount);
    }

    /**
     * @notice Modify an agents config only callable by the operator 
     * @param _agent the agent to modify
     * @param _agentData the struct of data
     */
    function modifyAgent(address _agent, Agent calldata _agentData) external onlyRole(OPERATOR_ROLE) {
        agents[_agent] = _agentData;
    }

    /**
     * @notice Register a new provider, callable by the network
     * @param _provider the providers address 
     * @param _asset the asset the provider is using for collateral backing 
     */
    function registerProvider(address _provider, address _asset) external {
        _onlyNetwork();

        Provider memory newProvider = Provider({
            asset: _asset,
            network: msg.sender,
            collateral: 0,
            isSlashed: false
        });

        providers[_provider] = newProvider;

        emit ProviderRegistered(_provider);
    }

    function _authorizeUpgrade(address) internal override onlyRole(OWNER_ROLE) {}
}