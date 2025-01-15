// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";
import { AmountOutLogic } from "./libraries/AmountOutLogic.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";

/// @title Minter/burner for cap tokens
/// @author kexley, @capLabs
/// @notice Cap tokens are minted or burned in exchange for collateral ratio of the backing tokens
/// @dev Dynamic fees are applied according to the allocation of assets in the basket. Increasing
/// the supply of a excessive asset or burning for an scarce asset will charge fees on a kinked
/// slope. Redeem can be used to avoid these fees by burning for the current ratio of assets.
contract MinterUpgradeable is AccessUpgradeable {
    /// @custom:storage-location erc7201:cap.storage.Minter
    struct MinterStorage {
        address oracle;
        uint256 redeemFee;
        mapping(address => DataTypes.FeeData) fees;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Minter")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MinterStorageLocation = 0x3b40995b576f8dd0a8521bba471c5346e53f6a25529b0903b82331eb1a2afe00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getMinterStorage() private pure returns (MinterStorage storage $) {
        assembly {
            $.slot := MinterStorageLocation
        }
    }

    /// @dev Initialize the minter
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    function __Minter_init(address _accessControl, address _oracle) internal onlyInitializing {
        __Access_init(_accessControl);
        __Minter_init_unchained(_oracle);
    }

    /// @dev Initialize unchained
    /// @param _oracle Oracle address
    function __Minter_init_unchained(address _oracle) internal onlyInitializing {
        MinterStorage storage $ = _getMinterStorage();
        $.oracle = _oracle;
    }

    /// @dev Fee data set for an asset in a vault
    event SetFeeData(address asset, DataTypes.FeeData feeData);

    /// @dev Redeem fee set
    event SetRedeemFee(uint256 redeemFee);

    /// @notice Get the mint amount for a given asset
    /// @param _asset Asset address
    /// @param _amountIn Amount of asset to use
    /// @return amountOut Amount minted
    function getMintAmount(address _asset, uint256 _amountIn) public view returns (uint256 amountOut) {
        MinterStorage storage $ = _getMinterStorage();
        DataTypes.FeeData memory fees = $.fees[_asset];
        amountOut = AmountOutLogic.amountOut(
            DataTypes.AmountOutParams({
                mint: true,
                asset: _asset,
                amount: _amountIn,
                oracle: $.oracle,
                slope0: fees.slope0,
                slope1: fees.slope0,
                mintKinkRatio: fees.mintKinkRatio,
                burnKinkRatio: fees.burnKinkRatio,
                optimalRatio: fees.optimalRatio
            })
        );
    }

    /// @notice Get the burn amount for a given asset
    /// @param _asset Asset address to withdraw
    /// @param _amountIn Amount of cap token to burn
    /// @return amountOut Amount of the asset withdrawn
    function getBurnAmount(address _asset, uint256 _amountIn) public view returns (uint256 amountOut) {
        MinterStorage storage $ = _getMinterStorage();
        DataTypes.FeeData memory fees = $.fees[_asset];
        amountOut = AmountOutLogic.amountOut(
            DataTypes.AmountOutParams({
                mint: false,
                asset: _asset,
                amount: _amountIn,
                oracle: $.oracle,
                slope0: fees.slope0,
                slope1: fees.slope0,
                mintKinkRatio: fees.mintKinkRatio,
                burnKinkRatio: fees.burnKinkRatio,
                optimalRatio: fees.optimalRatio
            })
        );
    }

    /// @notice Get the redeem amount
    /// @param _amountIn Amount of cap token to burn
    /// @return amountsOut Amounts of assets to be withdrawn
    function getRedeemAmount(uint256 _amountIn) public view returns (uint256[] memory amountsOut) {
        MinterStorage storage $ = _getMinterStorage();
        amountsOut = AmountOutLogic.redeemAmountOut(
            DataTypes.RedeemAmountOutParams({
                amount: _amountIn,
                redeemFee: $.redeemFee
            })
        );
    }

    /// @notice Set the allocation slopes and ratios for an asset
    /// @param _asset Asset address
    /// @param _feeData Fee slopes and ratios for the asset in the vault
    function setFeeData(address _asset, DataTypes.FeeData calldata _feeData)
        external
        checkAccess(this.setFeeData.selector)
    {
        MinterStorage storage $ = _getMinterStorage();
        $.fees[_asset] = _feeData;
        emit SetFeeData(_asset, _feeData);
    }

    /// @notice Set the redeem fee
    /// @param _redeemFee Redeem fee amount
    function setRedeemFee(uint256 _redeemFee) external checkAccess(this.setFeeData.selector) {
        MinterStorage storage $ = _getMinterStorage();
        $.redeemFee = _redeemFee;
        emit SetRedeemFee(_redeemFee);
    }
}
