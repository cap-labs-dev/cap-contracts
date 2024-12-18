// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INetwork {
    function collateralByProvider(address _provider) external view returns (uint256);
    function slashProvider(address _provider, uint256 _amount) external;
}

contract CollateralHandler {

    address public lender;
    address[] public activeAgents;

    struct Agent {
        uint maxCollateral;
        uint maxCollateralPerProvider;
        uint collateral;
        uint ltv;
        uint liquidationThreshold;
        uint rate;
    }

    mapping(address => Agent) public agents;
    mapping(address => address) public optIns;
    mapping(address => bool) public network;
    mapping(address => bool) public providers;
    mapping(address => mapping(address => uint256)) public providerAgentCollateral;
    mapping(address => address) public providerToNetwork;
    mapping(address => address[]) public agentProviders;
    mapping(address => bool) public providerIsSlashed;

    error NotNetwork();
    error NotProvider();
    error NotLender();
    error NotEnoughCollateral();
    error AlreadyOptedIn();
    error MaxCollateralExceeded();
    error MaxCollateralProviderExceeded();
    error NoNetwork();
    error ProviderIsSlashed();

    event ProviderRegistered(address provider, bool isRegistered);
    event OptIn(address provider, address agent, uint256 amount);
    event OptOut(address provider, address bagent, uint256 amount);
    event SlashProvider(address provider, uint256 amount);

    function _onlyNetwork() private view {
        if (!network[msg.sender]) revert NotNetwork();
    }
    
    function _onlyProvider() private view {
        if (providers[msg.sender]) revert NotProvider();
    }

    function _onlyLender() private view {
        if (msg.sender != lender) revert NotLender();
    }

    function globalCollateral() external view returns (uint256 _collateral) {
        for (uint i; i < activeAgents.length; ++i) {
            _collateral += agents[activeAgents[i]].collateral;
        }
    }

    function collateralByNetwork(address) external view returns (uint256) {}
    function collateralByProvider(address) external view returns (uint256) {}

    function coverage(address _agent) external view returns (uint256) {
        return _convertToUsd(agents[_agent].collateral);
    }

    function _convertToUsd(uint256 _amount) private pure returns (uint256) {
        /// to do add oracle
        return _amount;
    }

    function ltv(address _agent) external view returns (uint256 _ltv) {
        return agents[_agent].ltv;
    }

    function liquidiationThreshold(address _agent) external view returns (uint256 _lt) {
        return agents[_agent].liquidationThreshold;
    }

    function agentsList() external view returns (address[] memory _agents) {
        for (uint i; i < activeAgents.length; ++i) {
            _agents[i] = activeAgents[i];
        }
    }

    function slash(address _agent, uint _amount) external {
        _onlyLender();
        
        Agent memory storedAgents = agents[_agent];

        uint256 divisor = _amount  * 1e18 / storedAgents.collateral;

        storedAgents.collateral -= _amount;

        for (uint i; i < agentProviders[_agent].length; ++i) {
            address provider = agentProviders[_agent][i];
            uint256 amountCurrent = providerAgentCollateral[provider][_agent];
            address _network = providerToNetwork[provider];

            uint256 slashAmount = amountCurrent * 1e18 / divisor;
            INetwork(_network).slashProvider(provider, slashAmount);

            providerIsSlashed[provider] = true;

            emit SlashProvider(provider, slashAmount);
        }
    }

    function optIn(address[] calldata _agents, uint[] calldata _amountsCollateral) external {
        for (uint i; i < _agents.length; ++i) {
            optIn(_agents[i], _amountsCollateral[i]);
        }
    }

    function optIn(address _agent, uint _amountCollateral) private {
        _onlyProvider();

        address _network = providerToNetwork[msg.sender];

        Agent memory storedAgent = agents[_agent];
        if (storedAgent.collateral + _amountCollateral > storedAgent.maxCollateral) revert MaxCollateralExceeded();
        if (_amountCollateral > storedAgent.maxCollateralPerProvider) revert MaxCollateralProviderExceeded();

        storedAgent.collateral += _amountCollateral;

        uint current = providerAgentCollateral[msg.sender][_agent]; 
        if (current + _amountCollateral > INetwork(_network).collateralByProvider(msg.sender)) revert NotEnoughCollateral();
        if (current > 0) revert AlreadyOptedIn();
        providerAgentCollateral[msg.sender][_agent] = _amountCollateral;
        
        // Need to work on this because opt out and back in is an issue.
        agentProviders[_agent].push(msg.sender);
       
        emit OptIn(msg.sender, _agent, _amountCollateral);
    }

     function optOut(address[] calldata _agents) external {
        for (uint i; i < _agents.length; ++i) {
            optOut(_agents[i]);
        }
    }

    function optOut(address _agent) public {
        _onlyProvider();

        if (providerIsSlashed[msg.sender]) revert ProviderIsSlashed();

        Agent memory storedAgent = agents[_agent];

        uint256 amount = providerAgentCollateral[msg.sender][_agent];

        storedAgent.collateral -= amount;

        providerAgentCollateral[msg.sender][_agent] = 0;

        emit OptOut(msg.sender, _agent, amount);
    }

    function modifyAgent(address _agent, Agent calldata _agentData) external {
        agents[_agent] = _agentData;
    }

    function registerProvider(address _provider, bool _isRegistered) external {
        _onlyNetwork();

        providers[_provider] = _isRegistered;

        emit ProviderRegistered(_provider, _isRegistered);
    }

}