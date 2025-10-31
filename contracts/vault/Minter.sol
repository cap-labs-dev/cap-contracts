// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";

import { IMinter } from "../interfaces/IMinter.sol";
import { MinterStorageUtils } from "../storage/MinterStorageUtils.sol";
import { MinterLogic } from "./libraries/MinterLogic.sol";

/// @title Minter/burner for cap tokens
/// @author kexley, Cap Labs
/// @notice Cap tokens are minted or burned in exchange for collateral ratio of the backing tokens
/// @dev Dynamic fees are applied according to the allocation of assets in the basket. Increasing
/// the supply of a excessive asset or burning for an scarce asset will charge fees on a kinked
/// slope. Redeem can be used to avoid these fees by burning for the current ratio of assets.
abstract contract Minter is IMinter, Access, MinterStorageUtils {
    /// @inheritdoc IMinter
    function getFeeData(address _asset) external view returns (FeeData memory feeData) {
        feeData = getMinterStorage().fees[_asset];
    }

    /// @inheritdoc IMinter
    function setFeeData(address _asset, FeeData calldata _feeData) external checkAccess(this.setFeeData.selector) {
        if (_feeData.minMintFee >= 0.05e27) revert InvalidMinMintFee();
        if (_feeData.mintKinkRatio >= 1e27 || _feeData.mintKinkRatio == 0) revert InvalidMintKinkRatio();
        if (_feeData.burnKinkRatio >= 1e27 || _feeData.burnKinkRatio == 0) revert InvalidBurnKinkRatio();
        if (_feeData.optimalRatio >= 1e27 || _feeData.optimalRatio == 0) revert InvalidOptimalRatio();
        if (_feeData.optimalRatio == _feeData.mintKinkRatio || _feeData.optimalRatio == _feeData.burnKinkRatio) {
            revert InvalidOptimalRatio();
        }
        getMinterStorage().fees[_asset] = _feeData;
        emit SetFeeData(_asset, _feeData);
    }

    /// @inheritdoc IMinter
    function getRedeemFee() external view returns (uint256 redeemFee) {
        redeemFee = getMinterStorage().redeemFee;
    }

    /// @inheritdoc IMinter
    function setRedeemFee(uint256 _redeemFee) external checkAccess(this.setRedeemFee.selector) {
        getMinterStorage().redeemFee = _redeemFee;
        emit SetRedeemFee(_redeemFee);
    }

    /// @inheritdoc IMinter
    function setWhitelist(address _user, bool _whitelisted) external checkAccess(this.setWhitelist.selector) {
        getMinterStorage().whitelist[_user] = _whitelisted;
        emit SetWhitelist(_user, _whitelisted);
    }

    /// @inheritdoc IMinter
    function setDepositCap(address _asset, uint256 _cap) external checkAccess(this.setDepositCap.selector) {
        getMinterStorage().depositCap[_asset] = _cap;
        emit SetDepositCap(_asset, _cap);
    }

    /// @inheritdoc IMinter
    function getMintAmount(address _asset, uint256 _amountIn) public view returns (uint256 amountOut, uint256 fee) {
        (amountOut, fee) =
            MinterLogic.amountOut(getMinterStorage(), AmountOutParams({ mint: true, asset: _asset, amount: _amountIn }));
    }

    /// @inheritdoc IMinter
    function getBurnAmount(address _asset, uint256 _amountIn) public view returns (uint256 amountOut, uint256 fee) {
        (amountOut, fee) = MinterLogic.amountOut(
            getMinterStorage(), AmountOutParams({ mint: false, asset: _asset, amount: _amountIn })
        );
    }

    /// @inheritdoc IMinter
    function getRedeemAmount(uint256 _amountIn)
        public
        view
        returns (uint256[] memory amountsOut, uint256[] memory fees)
    {
        (amountsOut, fees) =
            MinterLogic.redeemAmountOut(getMinterStorage(), RedeemAmountOutParams({ amount: _amountIn }));
    }

    /// @inheritdoc IMinter
    function whitelisted(address _user) external view returns (bool isWhitelisted) {
        isWhitelisted = getMinterStorage().whitelist[_user];
    }

    /// @inheritdoc IMinter
    function depositCap(address _asset) public view returns (uint256 cap) {
        cap = getMinterStorage().depositCap[_asset];
    }

    /// @dev Initialize unchained
    /// @param _oracle Oracle address
    function __Minter_init(address _oracle) internal onlyInitializing {
        getMinterStorage().oracle = _oracle;
    }
}
