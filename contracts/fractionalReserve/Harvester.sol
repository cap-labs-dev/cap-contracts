// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IFractionalReserve } from "../interfaces/IFractionalReserve.sol";
import { IFractionalReserveStrategy } from "../interfaces/IFractionalReserveStrategy.sol";
import { IFractionalReserveVault } from "../interfaces/IFractionalReserveVault.sol";
import { IHarvester } from "../interfaces/IHarvester.sol";

/// @title Harvester
/// @author weso, Cap Labs
/// @notice Harvester harvests the fractional reserve vault
contract Harvester is IHarvester {
    function harvest(address _cusd, address _asset) external returns (uint256 profit, uint256 loss, uint256 interest) {
        IFractionalReserve fractionalReserve = IFractionalReserve(_cusd);
        IFractionalReserveVault vault = IFractionalReserveVault(fractionalReserve.fractionalReserveVault(_asset));
        address[] memory queue = vault.get_default_queue();

        for (uint256 i; i < queue.length; ++i) {
            IFractionalReserveStrategy strategy = IFractionalReserveStrategy(queue[i]);
            strategy.report();
            (uint256 _profit, uint256 _loss) = vault.process_report(queue[i]);
            profit += _profit;
            loss += _loss;
        }

        interest = fractionalReserve.claimableInterest(_asset);
        fractionalReserve.realizeInterest(_asset);
    }
}
