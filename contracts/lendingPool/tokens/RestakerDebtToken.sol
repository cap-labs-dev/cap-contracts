// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IPrincipalDebtToken } from "../../interfaces/IPrincipalDebtToken.sol";
import { ERC20Upgradeable, IERC20, ScaledToken } from "./base/ScaledToken.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Access } from "../../access/Access.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { IRestakerDebtToken } from "../../interfaces/IRestakerDebtToken.sol";
import { RestakerDebtTokenStorageUtils } from "../../storage/RestakerDebtTokenStorageUtils.sol";

/// @title Restaker debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Restaker debt tokens accrue over time representing the debt in the underlying asset to be
/// paid to the restakers collateralizing an agent
/// @dev Scaled balance is the principal debt + interest multiplied by the restaker rate, which when multiplied by
/// the time elapsed gives the interest accrued per agent. The total supply is the sum of the scaled balances of
/// all agents multiplied by the time elapsed.
contract RestakerDebtToken is
    IRestakerDebtToken,
    UUPSUpgradeable,
    ScaledToken,
    Access,
    RestakerDebtTokenStorageUtils
{
    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the debt token with the underlying asset
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _debtToken Principal debt token
    /// @param _asset Asset address
    function initialize(address _accessControl, address _oracle, address _debtToken, address _asset)
        external
        initializer
    {
        RestakerDebtTokenStorage storage $ = getRestakerDebtTokenStorage();
        $.asset = _asset;
        $.decimals = IERC20Metadata(_asset).decimals();
        $.debtToken = _debtToken;
        $.oracle = _oracle;

        string memory _name = string.concat("restaker", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("restaker", IERC20Metadata(_asset).symbol());

        __Access_init(_accessControl);
        __ScaledToken_init(_name, _symbol);
        __UUPSUpgradeable_init();
    }

    /// @notice Get the current balance of the agent
    /// @param _agent Agent address
    /// @return balance The balance of the agent
    function balanceOf(address _agent) public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return _balanceOf(_agent, block.timestamp);
    }

    /// @notice Get the current total supply of the token
    /// @return totalSupply The total supply of the token
    function totalSupply() public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return _totalSupply(block.timestamp);
    }

    /// @notice Accrue interest and update the scaled balance of the agent
    /// @dev Must be called after rate change or principal debt change
    /// @param _agent Agent address
    function update(address _agent) public {
        RestakerDebtTokenStorage storage $ = getRestakerDebtTokenStorage();
        uint256 amount = balanceOf(_agent) + IERC20Metadata($.debtToken).balanceOf(_agent);
        _update(_agent, amount * _rate(_agent) / 365 days, block.timestamp);
    }

    /// @notice Burn interest from the agent's balance
    /// @param _agent Agent address
    /// @param _amount Amount to burn
    function burn(address _agent, uint256 _amount) external checkAccess(this.burn.selector) {
        update(_agent);
        _burnFrom(_agent, _amount);
    }

    /// @dev Get the current restaker rate of the agent
    /// @param _agent Agent address
    /// @return rate The restaker rate of the agent
    function _rate(address _agent) internal view returns (uint256) {
        RestakerDebtTokenStorage storage $ = getRestakerDebtTokenStorage();
        return IOracle($.oracle).restakerRate(_agent);
    }

    /// @notice Get the asset address
    /// @return asset The asset address
    function asset() external view returns (address) {
        return getRestakerDebtTokenStorage().asset;
    }

    /// @notice Get the debt token address
    /// @return debtToken The debt token address
    function debtToken() external view returns (address) {
        return getRestakerDebtTokenStorage().debtToken;
    }

    /// @notice Get the decimals of the token
    /// @return decimals The decimals of the token
    function decimals() public view override returns (uint8) {
        return getRestakerDebtTokenStorage().decimals;
    }

    /// @notice Get the oracle address
    /// @return oracle The oracle address
    function oracle() external view returns (address) {
        return getRestakerDebtTokenStorage().oracle;
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
