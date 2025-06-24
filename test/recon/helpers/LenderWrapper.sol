// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ILender } from "contracts/interfaces/ILender.sol";
import { Lender } from "contracts/lendingPool/Lender.sol";
import { AgentConfiguration } from "contracts/lendingPool/libraries/configuration/AgentConfiguration.sol";

contract LenderWrapper is Lender {
    using AgentConfiguration for ILender.AgentConfigurationMap;

    /// @notice Get the total unrealized interest for an asset
    /// @param _asset Asset to get total unrealized interest for
    /// @return totalUnrealizedInterest Total unrealized interest for the asset
    function getTotalUnrealizedInterest(address _asset) external view returns (uint256) {
        ILender.ReserveData storage reserve = getLenderStorage().reservesData[_asset];
        return reserve.totalUnrealizedInterest;
    }

    function getVaultDebt(address _asset) external view returns (uint256) {
        ILender.ReserveData storage reserve = getLenderStorage().reservesData[_asset];
        return reserve.debt;
    }

    function getDelegation() external view returns (address) {
        return getLenderStorage().delegation;
    }

    function getIsBorrowing(address _agent, address _asset) external view returns (bool) {
        ReserveData storage reserve = getLenderStorage().reservesData[_asset];
        return getLenderStorage().agentConfig[_agent].isBorrowing(reserve.id);
    }
}
