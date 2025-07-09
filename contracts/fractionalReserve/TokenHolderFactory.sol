// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { ERC20, TokenHolder } from "./TokenHolder.sol";

import { IRegistry } from "./interfaces/IRegistry.sol";
import { IStrategy } from "@tokenized-strategy/interfaces/IStrategy.sol";

/// @title Token Holder Factory
/// @author kexley, Cap Labs
/// @notice Factory for deploying token holders
contract TokenHolderFactory {
    /// @notice Event emitted when a new token holder is deployed
    event NewTokenHolder(address indexed strategy, address indexed asset);

    /// @notice Revert message for when a strategy has already been deployed
    error AlreadyDeployed(address _strategy);

    /// @notice Revert message for when the asset is not the same as the vault asset
    error InvalidVault(address _asset, address _vault);

    /// @notice The SMS address
    address public immutable sms;

    /// @notice The registry address
    address public immutable registry;

    /// @notice The management address
    address public management;

    /// @notice The performance fee recipient address
    address public performanceFeeRecipient;

    /// @notice The keeper address
    address public keeper;

    /// @notice Track the deployments. asset => strategy
    mapping(address => address) public deployments;

    /// @dev Constructor
    /// @param _management The management address
    /// @param _performanceFeeRecipient The performance fee recipient address
    /// @param _keeper The keeper address
    /// @param _sms The SMS address
    /// @param _registry The registry address
    constructor(
        address _management,
        address _performanceFeeRecipient,
        address _keeper,
        address _sms,
        address _registry
    ) {
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
        sms = _sms;
        registry = _registry;
    }

    /// @notice Deploy a new Token Holder
    /// @param _asset The underlying asset for the holder to use
    /// @param _vault The vault that can deposit and withdraw
    /// @return tokenHolder The address of the new holder
    function newTokenHolder(address _asset, address _vault) external returns (address tokenHolder) {
        require(msg.sender == management, "!management");

        if (deployments[_asset] != address(0)) {
            revert AlreadyDeployed(deployments[_asset]);
        }

        if (!IRegistry(registry).isEndorsed(_vault) || _asset != IStrategy(_vault).asset()) {
            revert InvalidVault(_asset, _vault);
        }

        string memory _name = string(abi.encodePacked("Token Holder ", ERC20(_asset).symbol()));

        IStrategy newStrategy = IStrategy(address(new TokenHolder(_asset, _name, _vault)));

        newStrategy.setPerformanceFeeRecipient(performanceFeeRecipient);

        newStrategy.setKeeper(keeper);

        newStrategy.setPendingManagement(management);

        newStrategy.setEmergencyAdmin(sms);

        newStrategy.setPerformanceFee(0);

        newStrategy.setProfitMaxUnlockTime(0);

        emit NewTokenHolder(address(newStrategy), _asset);

        deployments[_asset] = address(newStrategy);
        tokenHolder = address(newStrategy);
    }

    /// @notice Set the addresses
    /// @param _management The management address
    /// @param _performanceFeeRecipient The performance fee recipient address
    /// @param _keeper The keeper address
    function setAddresses(address _management, address _performanceFeeRecipient, address _keeper) external {
        require(msg.sender == management, "!management");
        management = _management;
        performanceFeeRecipient = _performanceFeeRecipient;
        keeper = _keeper;
    }

    /// @notice Check if a strategy is deployed
    /// @param _strategy The strategy address
    /// @return isDeployed True if the strategy is deployed, false otherwise
    function isDeployedStrategy(address _strategy) external view returns (bool isDeployed) {
        address _asset = IStrategy(_strategy).asset();
        isDeployed = deployments[_asset] == _strategy;
    }
}
