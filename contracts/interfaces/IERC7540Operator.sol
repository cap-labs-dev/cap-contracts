// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC7540Operator {
    struct ERC7540OperatorStorage {
        mapping(address controller => mapping(address operator => bool)) isOperator;
    }

    /// @dev Emitted when `controller` sets the `approved` status for an `operator`.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /**
     * @dev Grants or revokes permissions for `operator` to manage requests on behalf of the caller.
     *
     * - MUST set the operator status to the `approved` value.
     * - MUST emit the {OperatorSet} event when the operator status is set.
     * - MUST return true.
     */
    function setOperator(address operator, bool approved) external returns (bool);

    /// @dev Returns `true` if the `operator` is approved as an operator for a `controller`.
    function isOperator(address controller, address operator) external view returns (bool status);
}
