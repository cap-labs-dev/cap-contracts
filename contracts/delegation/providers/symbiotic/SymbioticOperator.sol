// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ISymbioticOperator } from "../../../interfaces/ISymbioticOperator.sol";

import { SymbioticOperatorStorageUtils } from "../../../storage/SymbioticOperatorStorageUtils.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IOperatorRegistry } from "@symbioticfi/core/src/interfaces/IOperatorRegistry.sol";
import { IOptInService } from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";

contract SymbioticOperator is ISymbioticOperator, Initializable, SymbioticOperatorStorageUtils {
    error AccessDenied(address sender, address agent);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ISymbioticOperator
    function initialize(address _agent, address _networkOptInService, address _operatorRegistry, address _network)
        external
        initializer
    {
        getSymbioticOperatorStorage().agent = _agent;
        getSymbioticOperatorStorage().network = _network;
        _optIntoSymbiotic(_networkOptInService, _operatorRegistry, _network);
    }

    /// @dev Opt into symbiotic
    function _optIntoSymbiotic(address _networkOptInService, address _operatorRegistry, address _network) internal {
        IOperatorRegistry(_operatorRegistry).registerOperator();
        IOptInService(_networkOptInService).optIn(_network);
    }

    /// @inheritdoc ISymbioticOperator
    function optIntoVault(address _vaultOptInService, address _vault) external {
        if (msg.sender != getSymbioticOperatorStorage().network) {
            revert AccessDenied(msg.sender, getSymbioticOperatorStorage().network);
        }

        IOptInService(_vaultOptInService).optIn(_vault);
    }
}
