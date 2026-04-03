// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

/// @dev Shared base for test-only suites that do not use `TestDeployer`.
/// Keeps a consistent style for actors + high-signal labeling.
abstract contract BaseTest is Test {
    function _actor(string memory name) internal returns (address a) {
        a = makeAddr(name);
        vm.label(a, name);
    }
}

