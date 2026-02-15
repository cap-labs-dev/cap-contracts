// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICapInterestHarvester {
    /// @dev Storage for the CapInterestHarvester contract
    struct CapInterestHarvesterStorage {
        address asset;
        address cusd;
        address feeAuction;
        address feeReceiver;
        address harvester;
        address lender;
        address balancerVault;
        address excessReceiver;
    }

    /// @notice Initialize the CapInterestHarvester contract
    /// @param _accessControl Access control address
    /// @param _asset Asset address
    /// @param _cusd cUSD address
    /// @param _feeAuction Fee auction address
    /// @param _feeReceiver Fee receiver address
    /// @param _harvester Harvester address
    /// @param _lender Lender address
    /// @param _balancerVault Balancer vault address
    /// @param _excessReceiver Excess receiver address
    function initialize(
        address _accessControl,
        address _asset,
        address _cusd,
        address _feeAuction,
        address _feeReceiver,
        address _harvester,
        address _lender,
        address _balancerVault,
        address _excessReceiver
    ) external;

    /// @notice Harvest interest from borrow and the fractional reserve, sends to fee auction, buys interest, calls distribute on fee receiver
    function harvestInterest() external;

    /// @notice Set excess receiver
    /// @param _excessReceiver Excess receiver address
    function setExcessReceiver(address _excessReceiver) external;

    /// @notice Balancer flash loan callback
    /// @param _assets Assets to be swapped
    /// @param _amounts Amounts of assets to be swapped
    /// @param _feeAmounts Fee amounts of assets to be swapped
    /// @param _userData User data
    function receiveFlashLoan(
        IERC20[] memory _assets,
        uint256[] memory _amounts,
        uint256[] memory _feeAmounts,
        bytes memory _userData
    ) external;

    /// @notice Expected profit from harvesting (CUSD from minting fee-asset minus auction price).
    /// @param transactionCost Cost in asset terms deducted from the fee auction balance before mint
    /// @return expectedProfit Profit in CUSD terms (can be negative)
    function expectedHarvestProfit(uint256 transactionCost) external view returns (int256 expectedProfit);

    /// @notice First block at which harvesting is profitable, or sentinel values.
    /// @param secondsPerBlock Estimated seconds per block for block-offset calculation
    /// @param transactionCost Cost in asset terms deducted from the fee auction balance before mint
    /// @return nextProfitableBlock Block number when profitable; -1 if already profitable; 0 if now or never profitable
    function nextProfitableBlock(uint256 secondsPerBlock, uint256 transactionCost)
        external
        view
        returns (int256 nextProfitableBlock);
}
