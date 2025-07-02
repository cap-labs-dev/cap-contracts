// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";

import { IFractionalReserve } from "../interfaces/IFractionalReserve.sol";
import { FractionalReserveStorageUtils } from "../storage/FractionalReserveStorageUtils.sol";
import { FractionalReserveLogic } from "./libraries/FractionalReserveLogic.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Fractional Reserve
/// @author kexley, Cap Labs
/// @notice Idle capital is put to work in fractional reserve vaults and can be recalled when withdrawing, redeeming or borrowing.
abstract contract FractionalReserve is IFractionalReserve, Access, FractionalReserveStorageUtils {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @inheritdoc IFractionalReserve
    function investAll(address _asset) external checkAccess(this.investAll.selector) {
        FractionalReserveLogic.invest(getFractionalReserveStorage(), _asset);
    }

    /// @inheritdoc IFractionalReserve
    function divestAll(address _asset) external checkAccess(this.divestAll.selector) {
        FractionalReserveLogic.divest(getFractionalReserveStorage(), _asset);
    }

    /// @inheritdoc IFractionalReserve
    function setFractionalReserveVault(address _asset, address _vault)
        external
        checkAccess(this.setFractionalReserveVault.selector)
    {
        FractionalReserveStorage storage $ = getFractionalReserveStorage();
        FractionalReserveLogic.divest($, _asset);
        FractionalReserveLogic.setFractionalReserveVault($, _asset, _vault);
    }

    /// @inheritdoc IFractionalReserve
    function setReserve(address _asset, uint256 _reserve) external checkAccess(this.setReserve.selector) {
        FractionalReserveLogic.setReserve(getFractionalReserveStorage(), _asset, _reserve);
    }

    /// @inheritdoc IFractionalReserve
    function realizeInterest(address _asset) external {
        FractionalReserveLogic.realizeInterest(getFractionalReserveStorage(), _asset);
    }

    /// @inheritdoc IFractionalReserve
    function claimableInterest(address _asset) external view returns (uint256 interest) {
        interest = FractionalReserveLogic.claimableInterest(getFractionalReserveStorage(), _asset);
    }

    /// @inheritdoc IFractionalReserve
    function fractionalReserveVault(address _asset) external view returns (address vaultAddress) {
        vaultAddress = getFractionalReserveStorage().vault[_asset];
    }

    /// @inheritdoc IFractionalReserve
    function fractionalReserveVaults() external view returns (address[] memory vaultAddresses) {
        vaultAddresses = getFractionalReserveStorage().vaults.values();
    }

    /// @inheritdoc IFractionalReserve
    function reserve(address _asset) external view returns (uint256 reserveAmount) {
        reserveAmount = getFractionalReserveStorage().reserve[_asset];
    }

    /// @inheritdoc IFractionalReserve
    function loaned(address _asset) external view returns (uint256 loanedAmount) {
        loanedAmount = getFractionalReserveStorage().loaned[_asset];
    }

    /// @inheritdoc IFractionalReserve
    function interestReceiver() external view returns (address _interestReceiver) {
        _interestReceiver = getFractionalReserveStorage().interestReceiver;
    }

    /// @dev Initialize unchained
    /// @param _interestReceiver Interest receiver address
    function __FractionalReserve_init(address _interestReceiver) internal onlyInitializing {
        getFractionalReserveStorage().interestReceiver = _interestReceiver;
    }

    /// @dev Divest an asset from a fractional reserve vault
    /// @param _asset Asset address
    /// @param _amountOut Amount to divest
    function divest(address _asset, uint256 _amountOut) internal {
        FractionalReserveLogic.divest(getFractionalReserveStorage(), _asset, _amountOut);
    }

    /// @dev Divest many assets from a fractional reserve vault
    /// @param _assets Assets to divest
    /// @param _amountsOut Amounts to divest
    function divestMany(address[] memory _assets, uint256[] memory _amountsOut) internal {
        FractionalReserveStorage storage $ = getFractionalReserveStorage();
        for (uint256 i; i < _assets.length; ++i) {
            FractionalReserveLogic.divest($, _assets[i], _amountsOut[i]);
        }
    }
}
