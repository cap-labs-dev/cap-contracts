// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface INetwork {
    function collateralByProvider(address _provider) external view returns (uint256);
    function slashProvider(address _provider, uint256 _amount) external;
}

contract CollateralHandler {

    address public lendingPool;
    bytes32[] public availableTranches;

    struct Tranche {
        uint maxCollateral;
        uint maxCollateralPerProvider;
        uint availableCollateral;
        uint collateral;
    }

    mapping(bytes32 => Tranche) public tranche;
    mapping(address => bytes32) public optIns;
    mapping(address => bool) public network;
    mapping(address => bool) public providers;
    mapping(address => mapping(bytes32 => uint256)) public providerTrancheCollateral;
    mapping(address => address) public providerToNetwork;
    mapping(bytes32 => address[]) public trancheProviders;

    error NotNetwork();
    error NotProvider();
    error NotLendingPool();
    error NotEnoughCollateral();
    error AlreadyOptedIn();
    error MaxCollateralExceeded();
    error MaxCollateralProviderExceeded();
    error NoNetwork();

    event ProviderRegistered(address provider, bool isRegistered);
    event CollateralUsed(bytes32 trancheId, uint256 amountUsed);
    event OptIn(address provider, bytes32 trancheId, uint256 amount);
    event OptOut(address povider, bytes32 trancheId, uint256 amount);
    event SlashProvider(address provider, uint256 amount);

    function _onlyNetwork() private view {
        if (!network[msg.sender]) revert NotNetwork();
    }
    
    function _onlyProvider() private view {
        if (providers[msg.sender]) revert NotProvider();
    }

    function _onlyLendingPool() private view {
        if (msg.sender != lendingPool) revert NotLendingPool();
    }

    function globalCollateral() external view returns (uint256 _collateral) {
        for (uint i; i < availableTranches.length; ++i) {
            _collateral += tranche[availableTranches[i]].collateral;
        }
    }

    function collateralByNetwork(address) external view returns (uint256) {}
    function collateralByProvider(address) external view returns (uint256) {}

    function trancheCollateral(bytes32 _trancheId) external view returns (uint256) {
        return tranche[_trancheId].availableCollateral;
    }

    function tranches() external view returns (bytes32[] memory _tranches) {
        for (uint i; i < availableTranches.length; ++i) {
            _tranches[i] = availableTranches[i];
        }
    }

    function borrowAgainst(bytes32 _trancheId, uint _amount) external {
        _onlyLendingPool();

        uint available = tranche[_trancheId].availableCollateral;
        if (_amount < available) revert NotEnoughCollateral();

        tranche[_trancheId].availableCollateral = available - _amount;

        emit CollateralUsed(_trancheId, _amount);
    }


    function slash(bytes32 _trancheId, uint _amount) external {
        _onlyLendingPool();
        
        Tranche memory _tranche = tranche[_trancheId];

        uint256 divisor = _amount  * 1e18 / _tranche.collateral;

        _tranche.availableCollateral -= _amount;
        _tranche.collateral -= _amount;

        for (uint i; i < trancheProviders[_trancheId].length; ++i) {
            address provider = trancheProviders[_trancheId][i];
            uint256 amountCurrent = providerTrancheCollateral[provider][_trancheId];
            address _network = providerToNetwork[provider];

            uint256 slashAmount = amountCurrent * 1e18 / divisor;
            INetwork(_network).slashProvider(provider, slashAmount);

            emit SlashProvider(provider, slashAmount);
        }
    }

    function optIn(bytes32[] calldata _trancheIds, uint[] calldata _amountsCollateral) external {
        for (uint i; i < _trancheIds.length; ++i) {
            optIn(_trancheIds[i], _amountsCollateral[i]);
        }
    }

    function optIn(bytes32 _trancheId, uint _amountCollateral) private {
        _onlyProvider();

        address _network = providerToNetwork[msg.sender];

        Tranche memory _tranche = tranche[_trancheId];
        if (_tranche.collateral + _amountCollateral > _tranche.maxCollateral) revert MaxCollateralExceeded();
        if (_amountCollateral > _tranche.maxCollateralPerProvider) revert MaxCollateralProviderExceeded();

        _tranche.availableCollateral += _amountCollateral;
        _tranche.collateral += _amountCollateral;

        uint current = providerTrancheCollateral[msg.sender][_trancheId]; 
        if (current + _amountCollateral > INetwork(_network).collateralByProvider(msg.sender)) revert NotEnoughCollateral();
        if (current > 0) revert AlreadyOptedIn();
        providerTrancheCollateral[msg.sender][_trancheId] = _amountCollateral;
        
        // Need to work on this because opt out and back in is an issue.
        trancheProviders[_trancheId].push(msg.sender);
       
        emit OptIn(msg.sender, _trancheId, _amountCollateral);
    }

     function optOut(bytes32[] calldata _tranches) external {
        for (uint i; i < _tranches.length; ++i) {
            optOut(_tranches[i]);
        }
    }

    function optOut(bytes32 _trancheId) public {
        _onlyProvider();

        Tranche memory _tranche = tranche[_trancheId];

        uint256 amount = providerTrancheCollateral[msg.sender][_trancheId];
        if (amount < _tranche.availableCollateral) revert NotEnoughCollateral();

        _tranche.availableCollateral -= amount;
        _tranche.collateral -= amount;

        providerTrancheCollateral[msg.sender][_trancheId] = 0;

        emit OptOut(msg.sender, _trancheId, amount);
    }

    function configureTranche(bytes32 _trancheId, Tranche calldata _tranche) external {
        tranche[_trancheId] = _tranche;
    }

    function registerProvider(address _provider, bool _isRegistered) external {
        _onlyNetwork();

        providers[_provider] = _isRegistered;

        emit ProviderRegistered(_provider, _isRegistered);
    }

}