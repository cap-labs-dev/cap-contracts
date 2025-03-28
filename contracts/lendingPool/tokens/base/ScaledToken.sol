// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IScaledToken } from "../../../interfaces/IScaledToken.sol";
import { ScaledTokenStorageUtils } from "../../../storage/ScaledTokenStorageUtils.sol";
import { ERC20Upgradeable, IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title ScaledToken
/// @author kexley, @capLabs
/// @notice A token that scales with an index, meant to be inherited by interest debt tokens
/// @dev The scaled balance of the user is multiplied by the change in index to get the actual balance
contract ScaledToken is IScaledToken, ERC20Upgradeable, ScaledTokenStorageUtils {
    /// @dev Initialize the scaled token
    /// @param _name Name of the token
    /// @param _symbol Symbol of the token
    function __ScaledToken_init(string memory _name, string memory _symbol) internal onlyInitializing {
        __ERC20_init(_name, _symbol);
    }

    /// @notice Accrue interest and update the scaled balance of the agent
    /// @param _agent Agent address
    /// @param _newScaledBalance New scaled balance
    /// @param _index Index
    function _update(address _agent, uint256 _newScaledBalance, uint256 _index) internal {
        if (_agent == address(0)) revert AddressZero();

        ScaledTokenStorage storage $ = getScaledTokenStorage();
        uint256 scaledBalance = $.scaledBalance[_agent];

        uint256 increase = _balanceIncrease(_agent, _index);
        if (increase > 0) {
            $.balance[_agent] += increase;
            emit Transfer(address(0), _agent, increase);
        }
        $.storedIndex[_agent] = _index;

        $.totalSupply += _totalSupplyIncrease(_index);
        $.storedIndex[address(0)] = _index;

        if (_newScaledBalance > scaledBalance) {
            uint256 amountToMint = _newScaledBalance - scaledBalance;
            $.scaledBalance[_agent] += amountToMint;
            $.scaledTotalSupply += amountToMint;
        } else if (_newScaledBalance < scaledBalance) {
            uint256 amountToBurn = scaledBalance - _newScaledBalance;
            $.scaledBalance[_agent] -= amountToBurn;
            $.scaledTotalSupply -= amountToBurn;
        }
    }

    /// @notice Burn interest from the agent's balance
    /// @param _agent Agent address
    /// @param _amount Amount to burn
    function _burnFrom(address _agent, uint256 _amount) internal {
        ScaledTokenStorage storage $ = getScaledTokenStorage();
        $.balance[_agent] -= _amount;
        $.totalSupply -= _amount;

        emit Transfer(_agent, address(0), _amount);
    }

    /// @notice Get the current interest balance of the agent
    /// @param _agent Agent address
    /// @param _index Index
    /// @return balance The balance of the agent
    function _balanceOf(address _agent, uint256 _index) internal view returns (uint256) {
        return getScaledTokenStorage().balance[_agent] + _balanceIncrease(_agent, _index);
    }

    /// @notice Get the total supply of the interest
    /// @param _index Index
    /// @return totalSupply The total supply of the interest
    function _totalSupply(uint256 _index) internal view returns (uint256) {
        return getScaledTokenStorage().totalSupply + _totalSupplyIncrease(_index);
    }

    /// @notice Get the interest balance increase of the agent
    /// @param _agent Agent address
    /// @param _index Index
    /// @return increase The interest balance increase of the agent
    function _balanceIncrease(address _agent, uint256 _index) private view returns (uint256) {
        ScaledTokenStorage storage $ = getScaledTokenStorage();
        uint256 scaledBalance = $.scaledBalance[_agent];
        return scaledBalance * (_index - $.storedIndex[_agent]) / 1e27;
    }

    /// @notice Get the interest total supply increase
    /// @param _index Index
    /// @return increase The interest total supply increase
    function _totalSupplyIncrease(uint256 _index) private view returns (uint256) {
        ScaledTokenStorage storage $ = getScaledTokenStorage();
        uint256 scaledTotalSupply = $.scaledTotalSupply;
        return scaledTotalSupply * (_index - $.storedIndex[address(0)]) / 1e27;
    }

    /// @notice Disabled due to this being a non-transferrable token
    function transfer(address, uint256) public pure override(ERC20Upgradeable, IERC20) returns (bool) {
        revert OperationNotSupported();
    }

    /// @notice Disabled due to this being a non-transferrable token
    function allowance(address, address) public pure override(ERC20Upgradeable, IERC20) returns (uint256) {
        revert OperationNotSupported();
    }

    /// @notice Disabled due to this being a non-transferrable token
    function approve(address, uint256) public pure override(ERC20Upgradeable, IERC20) returns (bool) {
        revert OperationNotSupported();
    }

    /// @notice Disabled due to this being a non-transferrable token
    function transferFrom(address, address, uint256) public pure override(ERC20Upgradeable, IERC20) returns (bool) {
        revert OperationNotSupported();
    }
}
