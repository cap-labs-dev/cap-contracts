// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { AccessManager } from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Test } from "forge-std/Test.sol";

/// @title BaseTest
/// @notice Shared scaffolding for Cap unit tests: an AccessManager authority (with this test as
/// admin so `restricted` functions can be called directly) plus a UUPS proxy deploy helper.
abstract contract BaseTest is Test {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant WAD = 1e18;

    AccessManager internal accessManager;

    function _setUpAccessManager() internal {
        accessManager = new AccessManager(address(this));
    }

    /// @dev Deploy a UUPS/ERC1967 proxy in front of `implementation` and initialize it.
    function _deployProxy(address implementation, bytes memory initData) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(implementation, initData));
    }

    /// @dev Grant `account` a role and allow it to call `selectors` on `target`.
    function _grantRoleForTarget(uint64 roleId, address account, address target, bytes4[] memory selectors) internal {
        accessManager.grantRole(roleId, account, 0);
        accessManager.setTargetFunctionRole(target, selectors, roleId);
    }

    function _selectors(bytes4 a) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = a;
    }
}
