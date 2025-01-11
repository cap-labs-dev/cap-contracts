// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessUpgradeable} from "./AccessUpgradeable.sol";

/// @title AddressProvider
/// @author kexley, @capLabs
/// @notice Addresses are stored here as a central repository
contract AddressProvider is UUPSUpgradeable, AccessUpgradeable {
    /// @notice Lender for assets
    address public lender;

    /// @notice Collateral controller for collateralizing agents
    address public collateral;

    /// @notice Price oracle
    address public priceOracle;

    /// @notice Rate oracle for interest rates
    address public rateOracle;

    /// @notice Minter stored for Staked Cap Token's reference
    address public minter;

    /// @notice Vault for a cap token
    mapping(address => address) public vault;

    /// @notice Interest receiver for an asset
    mapping(address => address) interestReceiver;

    /// @notice Receiver of restaker interest for an agent
    mapping(address => address) restakerInterestReceiver;

    /// @dev Vault cannot be set more than once for a cap token
    error VaultAlreadySet(address capToken);

    /// @dev Set vault for a cap token
    event SetVault(address capToken, address vault);

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
        address _priceOracle,
        address _rateOracle,
        address _minter
    ) external initializer {
        __Access_init(_accessControl);

        lender = _lender;
        collateral = _collateral;
        priceOracle = _priceOracle;
        rateOracle = _rateOracle;
        minter = _minter;
    }

    /// @notice Set a vault address for a cap token
    /// @param _capToken Cap token address
    /// @param _vault Vault token address
    function setVault(address _capToken, address _vault) external checkRole(this.setVault.selector) {
        if (vault[_capToken] != address(0)) revert VaultAlreadySet(_capToken);
        vault[_capToken] = _vault;
        emit SetVault(_capToken, _vault);
    }

    /// @notice Set a interest receiver for an asset
    /// @param _asset Asset address
    /// @param _receiver Receiver address
    function setInterestReceiver(
        address _asset,
        address _receiver
    ) external checkRole(this.setInterestReceiver.selector) {
        interestReceiver[_asset] = _receiver;
        emit SetInterestReceiver(_asset, _receiver);
    }

    /// @notice Set a restaker interest receiver for an agent
    /// @param _agent Agent address
    /// @param _receiver Receiver address
    function setRestakerInterestReceiver(
        address _agent,
        address _receiver
    ) external checkRole(this.setRestakerInterestReceiver.selector) {
        interestReceiver[_agent] = _receiver;
        emit SetRestakerInterestReceiver(_agent, _receiver);
    }

    function _authorizeUpgrade(address) internal override checkRole(bytes4(0)) {}
}
