// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Upgradeable, IERC20} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {AccessUpgradeable} from "../../registry/AccessUpgradeable.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {IAddressProvider} from "../../interfaces/IAddressProvider.sol";

/// @title Principal debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Principal debt tokens are minted 1:1 with the principal loan amount
contract PrincipalDebtToken is ERC20Upgradeable, AccessUpgradeable {
    /// @notice asset Underlying asset
    address public asset;

    /// @dev Decimals of the underlying asset
    uint8 private _decimals;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the debt token with the underlying asset
    /// @param _accessControl Access control
    /// @param _asset Asset address
    function initialize(address _accessControl, address _asset) external initializer {
        string memory _name = string.concat("debt", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("debt", IERC20Metadata(_asset).symbol());
        _decimals = IERC20Metadata(_asset).decimals();
        asset = _asset;

        __ERC20_init(_name, _symbol);
        __Access_init(_accessControl);
    }

    /// @notice Match decimals with underlying asset
    /// @return decimals
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Lender will mint debt tokens to match the amount borrowed by an agent. Interest and
    /// restaker interest is accrued to the agent.
    /// @param to Address to mint tokens to
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external checkRole(this.mint.selector) {
        _mint(to, amount);
    }

    /// @notice Lender will burn debt tokens when the principal debt is repaid by an agent
    /// @param from Burn tokens from agent
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external checkRole(this.burn.selector) {
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
