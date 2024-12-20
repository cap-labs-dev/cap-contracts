// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface ICToken is IERC20 {
    function initialize(string memory name, string memory symbol) external;
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}