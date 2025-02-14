// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IRestakerRewardReceiver } from "./IRestakerRewardReceiver.sol";

interface IDelegation is IRestakerRewardReceiver {
    function coverage(address agent) external view returns (uint256 coverage);
    function slash(address agent, address receiver, uint256 liquidatedValue) external;
    function ltv(address agent) external view returns (uint256 ltv);
    function liquidationThreshold(address agent) external view returns (uint256 liquidationThreshold);
    function networks(address agent) external view returns (address[] memory);
    function setLastBorrow(address agent) external;
    function addAgent(address agent, uint256 ltv, uint256 liquidationThreshold) external;
    function registerNetwork(address agent, address network) external;
}
