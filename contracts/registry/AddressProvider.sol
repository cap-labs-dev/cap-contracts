// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAddressProvider } from "../interfaces/IAddressProvider.sol";
import { AccessUpgradeable } from "./AccessUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AddressProvider
/// @author kexley, @capLabs
/// @notice Addresses are stored here as a central repository
contract AddressProvider is IAddressProvider, UUPSUpgradeable, AccessUpgradeable {
    /// @notice AccessControl
    address public accessControl;

    /// @notice Lender for assets
    address public lender;

    /// @notice Collateral controller for collateralizing agents
    address public collateral;

    /// @notice Oracle for prices and rate
    address public oracle;

    /// @notice Interest receiver for an asset
    mapping(address => address) public interestReceiver;

    /// @notice Receiver of restaker interest for an agent
    mapping(address => address) public restakerInterestReceiver;

    /// @dev Set an interest receiver for an asset
    event SetInterestReceiver(address asset, address receiver);

    /// @dev Set a restaker interest receiver for an agent
    event SetRestakerInterestReceiver(address agent, address receiver);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// TODO Initialize all variables in initializer
    /// @notice Initialize the address provider with the access control
    /// @param _accessControl Access control address
    function initialize(
        address _accessControl,
        address _lender,
        address _collateral,
        address _oracle
    ) external initializer {
        __Access_init(_accessControl);

        lender = _lender;
        collateral = _collateral;
        oracle = _oracle;
    }

    /// @notice Set a interest receiver for an asset
    /// @param _asset Asset address
    /// @param _receiver Receiver address
    function setInterestReceiver(address _asset, address _receiver)
        external
        checkAccess(this.setInterestReceiver.selector)
    {
        interestReceiver[_asset] = _receiver;
        emit SetInterestReceiver(_asset, _receiver);
    }

    /// @notice Set a restaker interest receiver for an agent
    /// @param _agent Agent address
    /// @param _receiver Receiver address
    function setRestakerInterestReceiver(address _agent, address _receiver)
        external
        checkAccess(this.setRestakerInterestReceiver.selector)
    {
        interestReceiver[_agent] = _receiver;
        emit SetRestakerInterestReceiver(_agent, _receiver);
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
