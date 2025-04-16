// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// Make role ids easier to read by humans
///  Example:
///  - selector: 0x40c10f19
///  - contract: 0x521291e5c6c2b8a98ad57ea5f165d25d0bf8f65a
///  -> roleId: 0x40c10f190000000000000000521291e5c6c2b8a98ad57ea5f165d25d0bf8f65a
library RoleId {
    bytes32 private constant SELECTOR_MASK = bytes32((uint256(0xffffffff) << 224));
    bytes32 private constant CONTRACT_MASK = bytes32((uint256(type(uint160).max)));

    /// @notice Build role id for a function selector on a contract
    /// @param _selector Function selector
    /// @param _contract Contract being called
    /// @return _roleId Role id
    function roleId(bytes4 _selector, address _contract) public pure returns (bytes32 _roleId) {
        _roleId = bytes32(_selector) | bytes32(uint256(uint160(_contract)));
    }

    /// @notice Build role id for a function selector on a contract
    /// @param _contract Contract being called
    /// @param _selector Function selector
    /// @return _roleId Role id
    function roleId(address _contract, bytes4 _selector) public pure returns (bytes32 _roleId) {
        _roleId = roleId(_selector, _contract);
    }

    /// @notice Decode role id into function selector and contract
    /// @param _roleId Role id
    /// @return _selector Function selector
    /// @return _contract Contract being called
    function decodeRoleId(bytes32 _roleId) public pure returns (bytes4 _selector, address _contract) {
        _selector = bytes4(_roleId & SELECTOR_MASK);
        _contract = address(uint160(uint256(_roleId) & uint256(CONTRACT_MASK)));
    }
}
