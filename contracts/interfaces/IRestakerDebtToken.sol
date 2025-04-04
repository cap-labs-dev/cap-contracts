// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRestakerDebtToken is IERC20 {
    /// @custom:storage-location erc7201:cap.storage.RestakerDebt
    struct RestakerDebtTokenStorage {
        address asset;
        address debtToken;
        uint8 decimals;
        address oracle;
        uint256 totalSupply;
        mapping(address => uint256) lastAgentUpdate;
        uint256 lastUpdate;
    }

    /// @notice Initialize the debt token with the underlying asset
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _debtToken Principal debt token
    /// @param _asset Asset address
    function initialize(address _accessControl, address _oracle, address _debtToken, address _asset) external;

    /// @notice Update the interest per second of the agent and the scaled total supply
    /// @dev Left permissionless
    /// @param _agent Agent address to update interest rate for
    function update(address _agent) external;

    /// @notice Burn the debt token, only callable by the lender
    /// @dev All underlying token transfers are handled by the lender instead of this contract
    /// @param _agent Agent address that will have it's debt repaid
    /// @param _amount Amount of underlying asset to repay to lender
    function burn(address _agent, uint256 _amount) external;

    /// @notice Get the asset address
    /// @return asset The asset address
    function asset() external view returns (address);

    /// @notice Get the debt token address
    /// @return debtToken The debt token address
    function debtToken() external view returns (address);

    /// @notice Get the oracle address
    /// @return oracle The oracle address
    function oracle() external view returns (address);
}
