// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Errors } from "../libraries/helpers/Errors.sol";
import { IRegistry } from "../../interfaces/IRegistry.sol";

/// @title Debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Debt tokens are minted 1:1 with the principal loan amount
contract DebtToken is ERC20Upgradeable {

    /// @notice Registry contract
    address public registry;

    /// @notice asset Underlying asset
    address public asset;

    /// @dev Decimals of the underlying asset
    uint8 private _decimals;

    /// @dev Only the lender can use these functions
    modifier onlyLender() {
        require(msg.sender == IRegistry(registry).lender(), Errors.CALLER_NOT_POOL_OR_EMERGENCY_ADMIN);
        _;
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the debt token with the underlying asset
    /// @param _registry Registry address
    /// @param asset_ Asset address
    function initialize(address _registry, address asset_) external initializer {
        string memory name = string.concat("debt", IERC20Metadata(asset_).name());
        string memory symbol = string.concat("debt", IERC20Metadata(asset_).symbol());
        _decimals = IERC20Metadata(asset_).decimals();
        asset = asset_;

        __ERC20_init(name, symbol);
        registry = _registry;
    }

    /// @notice Match decimals with underlying asset
    /// @return decimals
    function decimals() public override view returns (uint8) {
        return _decimals;
    }

    /// @notice Lender will mint debt tokens to match the amount borrowed by an agent. Interest and
    /// restaker interest is accrued to the agent.
    /// @param to Address to mint tokens to
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external onlyLender {
        _mint(to, amount);
    }

    /// @notice Lender will burn debt tokens when the principal debt is repaid by an agent
    /// @param from Burn tokens from agent
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external onlyLender {
        _burn(from, amount);
    }

    /// @notice Disabled due to this being a non-transferrable token
    function transfer(address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to this being a non-transferrable token
    function allowance(address, address) public pure override returns (uint256) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to this being a non-transferrable token
    function approve(address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to this being a non-transferrable token
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }
}
