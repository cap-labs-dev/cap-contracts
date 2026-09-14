// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IERC7540Operator
/// @notice ERC-7540 operator methods. {IERC165-supportsInterface} id is `0xe3bc4e65`.
interface IERC7540Operator {
    /// @dev Emitted when `controller` sets the `approved` status for an `operator`.
    event OperatorSet(address indexed controller, address indexed operator, bool approved);

    /**
     * @dev Grants or revokes permissions for `operator` to manage requests on behalf of the caller.
     *
     * - MUST set the operator status to the `approved` value.
     * - MUST emit the {OperatorSet} event when the operator status is set.
     * - MUST return true.
     * @param operator The account to grant or revoke
     * @param approved Whether the operator is approved
     * @return Whether the status was set
     */
    function setOperator(address operator, bool approved) external returns (bool);

    /// @dev Returns `true` if the `operator` is approved as an operator for a `controller`.
    /// @param controller The account whose operators are being queried
    /// @param operator The account to check
    /// @return status Whether the operator is approved
    function isOperator(address controller, address operator) external view returns (bool status);
}
