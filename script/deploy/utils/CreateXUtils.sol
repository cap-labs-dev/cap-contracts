// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ICreateX } from "../interfaces/ICreateX.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title CreateXUtils
/// @notice Permissioned CREATE3 helpers against the canonical CreateX factory
/// @dev Salts are `deployer || 0x00 || entropy`. The zero flag keeps the address
/// identical across chains; the deployer prefix stops anyone else mining it.
abstract contract CreateXUtils {
    /// @dev CreateX, same address on every chain that has it
    ICreateX internal constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    /// @dev Build a permissioned salt. {ICreateX-deployCreate3} must be called by `deployer`.
    /// @param deployer The account that will call CreateX
    /// @param namespace Distinguishes otherwise identical deploys (tests, retries)
    /// @param key What is being deployed
    /// @return salt The raw salt passed to CreateX
    function _createXSalt(address deployer, bytes32 namespace, bytes32 key) internal pure returns (bytes32 salt) {
        salt = bytes32(abi.encodePacked(deployer, bytes1(0), bytes11(keccak256(abi.encode(namespace, key)))));
    }

    /// @dev Guard a permissioned, same-chain-replay salt the way CreateX does
    /// @param salt The raw salt
    /// @param deployer The account that will call CreateX
    /// @return guarded The salt CreateX feeds to CREATE2
    function _guardedCreateXSalt(bytes32 salt, address deployer) internal pure returns (bytes32 guarded) {
        guarded = keccak256(abi.encodePacked(bytes32(uint256(uint160(deployer))), salt));
    }

    /// @dev Address CreateX will deploy `salt` to when called by `deployer`
    /// @param salt The raw salt
    /// @param deployer The account that will call CreateX
    /// @return predicted The CREATE3 address
    function _predictCreate3(bytes32 salt, address deployer) internal view returns (address predicted) {
        predicted = CREATEX.computeCreate3Address(_guardedCreateXSalt(salt, deployer));
    }

    /// @dev Deploy `initCode` through CreateX
    /// @param salt The raw salt
    /// @param initCode Creation bytecode, including constructor arguments
    /// @return deployed The CREATE3 address
    function _create3(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        require(address(CREATEX).code.length > 0, "CreateX missing");
        deployed = CREATEX.deployCreate3(salt, initCode);
    }

    /// @dev Deploy an ERC-1967 proxy through CreateX and run its initializer
    /// @param salt The raw salt
    /// @param implementation The implementation address
    /// @param initData The encoded initializer call
    /// @return proxy The proxy address
    function _create3Proxy(bytes32 salt, address implementation, bytes memory initData)
        internal
        returns (address proxy)
    {
        proxy = _create3(salt, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData)));
    }
}
