// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title MockCreateX
/// @notice CREATE3 factory matching CreateX's permissioned `0x00` salt and address formula
/// @dev Etched onto {CreateXUtils-CREATEX} in tests. Only the salt shape DeployInfra uses is accepted.
contract MockCreateX {
    /// @dev Solady / CreateX CREATE3 proxy
    bytes32 private constant PROXY_INITCODE_HASH = 0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f;

    /// @notice Deploy `initCode` via CREATE3
    /// @param salt Permissioned salt; first 20 bytes must be `msg.sender`, 21st byte `0x00`
    /// @param initCode Creation bytecode, including constructor arguments
    /// @return newContract The deployed address
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract) {
        // first 20 bytes are the caller address by CreateX salt construction
        // forge-lint: disable-next-line(unsafe-typecast)
        require(address(bytes20(salt)) == msg.sender && bytes1(salt[20]) == 0x00, "salt");
        bytes32 guarded = keccak256(abi.encodePacked(bytes32(uint256(uint160(msg.sender))), salt));

        bytes memory proxyChildBytecode = hex"67363d3d37363d34f03d5260086018f3";
        address proxy;
        assembly {
            proxy := create2(0, add(proxyChildBytecode, 0x20), mload(proxyChildBytecode), guarded)
        }
        require(proxy != address(0), "proxy");

        newContract = computeCreate3Address(guarded);
        (bool ok,) = proxy.call{ value: msg.value }(initCode);
        require(ok && newContract.code.length > 0, "create3");
    }

    /// @notice CREATE3 address for a salt that has already been guarded
    /// @param salt The guarded salt
    /// @return computedAddress The address this factory will deploy to
    function computeCreate3Address(bytes32 salt) public view returns (address computedAddress) {
        computedAddress = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, PROXY_INITCODE_HASH))))
        );
        computedAddress =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), computedAddress, bytes1(0x01))))));
    }
}
