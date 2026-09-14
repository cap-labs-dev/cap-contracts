// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title ICreateX
/// @notice The pcaversaccio CreateX factory at {CreateXUtils-CREATEX}
interface ICreateX {
    /// @notice Deploy `initCode` via CREATE3
    /// @param salt Permissioned salt; first 20 bytes must be `msg.sender`
    /// @param initCode Creation bytecode, including constructor arguments
    /// @return newContract The deployed address
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

    /// @notice CREATE3 address for a salt that has already been guarded
    /// @param salt The guarded salt, not the raw one passed to {deployCreate3}
    /// @return computedAddress The address CreateX will deploy to
    function computeCreate3Address(bytes32 salt) external view returns (address computedAddress);
}
