// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC7540Operator } from "../interfaces/IERC7540Operator.sol";
import { ERC7540OperatorStorageUtils } from "../storage/ERC7540OperatorStorageUtils.sol";

contract ERC7540Operator is IERC7540Operator, ERC7540OperatorStorageUtils {
    /// @notice Set an operator for a controller
    /// @param operator The operator to set
    /// @param approved The approval status
    /// @return true if the operator was set successfully
    function setOperator(address operator, bool approved) external returns (bool) {
        _setOperator(msg.sender, operator, approved);
        return true;
    }

    /// @notice Check if an operator is authorized for a controller
    /// @param controller The controller to check
    /// @param operator The operator to check
    /// @return true if the operator is authorized
    function isOperator(address controller, address operator) public view returns (bool) {
        return getERC7540OperatorStorage().isOperator[controller][operator];
    }

    /// @dev Internal function to set an operator for a controller
    /// @param owner The owner of the operator
    /// @param spender The operator to set
    /// @param approved The approval status
    function _setOperator(address owner, address spender, bool approved) internal {
        getERC7540OperatorStorage().isOperator[owner][spender] = approved;
        emit OperatorSet(owner, spender, approved);
    }
}
