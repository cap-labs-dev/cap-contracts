// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC7540Operator } from "../interfaces/IERC7540Operator.sol";

/// @title ERC7540Operator
/// @author kexley
/// @notice ERC7540 operator approvals for async redemption controllers
contract ERC7540Operator is IERC7540Operator {
    /// @custom:storage-location cap.storage.ERC7540Operator
    // forge-lint: disable-next-item(pascal-case-struct)
    struct ERC7540OperatorStorage {
        mapping(address => mapping(address => bool)) isOperator;
    }

    // keccak256(abi.encode(uint256(keccak256("cap.storage.ERC7540Operator")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev ERC-7201 storage slot for ERC7540Operator
    uint256 private constant STORAGE_LOCATION = 0x984a447e9a3f276a50a882321c9dcb50ab53cba0333a097400ab36b1a1a27200;

    /// @dev Get the storage of the contract
    /// @return $ The storage of the contract
    // forge-lint: disable-next-item(mixed-case-function)
    function _getERC7540OperatorStorage() private pure returns (ERC7540OperatorStorage storage $) {
        uint256 slot = STORAGE_LOCATION;
        assembly {
            $.slot := slot
        }
    }

    /// @inheritdoc IERC7540Operator
    function setOperator(address operator, bool approved) external returns (bool) {
        _setOperator(msg.sender, operator, approved);
        return true;
    }

    /// @inheritdoc IERC7540Operator
    function isOperator(address controller, address operator) public view returns (bool) {
        return _getERC7540OperatorStorage().isOperator[controller][operator];
    }

    /// @dev Internal function to set an operator for a controller
    /// @param owner The owner of the operator
    /// @param spender The operator to set
    /// @param approved The approval status
    function _setOperator(address owner, address spender, bool approved) internal {
        _getERC7540OperatorStorage().isOperator[owner][spender] = approved;
        emit OperatorSet(owner, spender, approved);
    }
}
