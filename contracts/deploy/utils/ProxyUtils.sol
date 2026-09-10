// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ProxyUtils {
    /// @dev Deploy an ERC-1967 proxy and run its initializer
    /// @param implementation The implementation address
    /// @param initData The encoded initializer call
    /// @return The proxy address
    function _proxy(address implementation, bytes memory initData) internal returns (address) {
        return address(new ERC1967Proxy(implementation, initData));
    }
}
