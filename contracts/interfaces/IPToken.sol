// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface IPToken is IERC20 {
    function initialize(address asset) external;
    function mint(address to, uint256 amount) external;
    function burn(
        address from,
        uint256 amount,
        uint256 interest
    ) external returns (uint256 paybackMarket, uint256 paybackAgent);
    function totalBalanceOf(address agent) external view returns (uint256 totalBalance);
    function accruedInterest(address agent) external view returns (uint256 interest);
    function accruedAgentInterest(address agent) external view returns (uint256 interest);
}