// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { MockERC20 } from "./MockERC20.sol";

// Mock OFT token for testing
contract MockOFT is MockERC20 {
    constructor() MockERC20("MockOFT", "MOFT") { }

    function token() external view returns (address) {
        return address(this);
    }
}
