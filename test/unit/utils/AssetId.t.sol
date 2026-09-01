// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { AssetId } from "../../../contracts/utils/AssetId.sol";
import { Test } from "forge-std/Test.sol";

contract AssetIdHarness {
    function toId(address token) external pure returns (uint256) {
        return AssetId.toId(token);
    }

    function toAsset(uint256 id) external pure returns (address) {
        return AssetId.toAsset(id);
    }
}

contract AssetIdTest is Test {
    AssetIdHarness internal h;

    function setUp() public {
        h = new AssetIdHarness();
    }

    function test_roundtrip() public view {
        address token = address(0xBEEF);
        assertEq(h.toAsset(h.toId(token)), token);
    }

    function test_toId_isAddressValue() public view {
        address token = 0x1111111111111111111111111111111111111111;
        assertEq(h.toId(token), uint256(uint160(token)));
    }

    function testFuzz_roundtrip(address token) public view {
        assertEq(h.toAsset(h.toId(token)), token);
    }

    function testFuzz_toAsset_truncatesToLower160(uint256 id) public view {
        // casting to 'uint160' is safe because toAsset intentionally truncates to address width
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(h.toAsset(id), address(uint160(id)));
    }
}
