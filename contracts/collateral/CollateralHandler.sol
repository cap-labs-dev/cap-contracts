// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract CollateralHandler {

    struct Tranche {
        uint maxCollateral;
        uint maxCollateralPerProvider;
        uint amountCollateral;
        uint borrowedAgainst;
    }

    mapping(bytes32 => Tranche) public tranche;
    mapping(address => bytes32) public optIns;
    mapping(address => bool) public network;
    mapping(address => bool) public providers;

    error NotNetwork();
    error NotProvider();

    event ProviderRegistered(address provider, bool isRegistered);

    function globalCollateral() external view returns (uint256) {}
    function trancheCollateral(bytes32 _trancheId) external view returns (uint256) {
        return tranche[_trancheId].amountCollateral;
    }

    function _onlyNetwork() private {
        if (!network[msg.sender]) revert NotNetwork();
    }
    
    function _onlyProvider() private {
        if (providers[msg.sender]) revert NotProvider();
    }

    function borrow() external {}
    function slash() external {}

    function optIn(uint[] calldata _tranches, uint[] calldata _amountsCollateral) external {
        for (uint i; i < _tranches.length; ++i) {
            optIn(_tranches[i], _amountsCollateral[i]);
        }
    }

    function optOut(uint[] calldata _tranches) external {
        for (uint i; i < _tranches.length; ++i) {
            optOut(_tranches[i]);
        }
    }

    function optIn(uint _tranche, uint _amountCollateral) public {
           _onlyProvider();

    }
    function optOut(uint _tranche) public {
           _onlyProvider();
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