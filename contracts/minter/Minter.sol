// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IAddressProvider } from "../interfaces/IAddressProvider.sol";
import { IVault } from "../interfaces/IVault.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";

import { AmountOutLogic } from "./libraries/AmountOutLogic.sol";
import { MintBurnLogic } from "./libraries/MintBurnLogic.sol";
import { ValidationLogic } from "./libraries/ValidationLogic.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";

/// @title Minter/burner for cap tokens
/// @author kexley, @capLabs
/// @notice Cap tokens are minted or burned in exchange for collateral ratio of the backing tokens
/// @dev Dynamic fees are applied according to the allocation of assets in the basket. Increasing
/// the supply of a excessive asset or burning for an scarce asset will charge fees on a kinked
/// slope. Redeem can be used to avoid these fees by burning for the current ratio of assets.
contract Minter is UUPSUpgradeable, AccessUpgradeable {
    /// @dev Fee data for minting and burning
    struct FeeData {
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }

    /// @notice Address provider
    IAddressProvider public addressProvider;

    /// @notice Fee data for each asset in a vault
    mapping(address => mapping(address => FeeData)) public feeData;

    /// @notice Redeem fee for a vault
    mapping(address => uint256) public redeemFee;

    /// @dev Fee data set for an asset in a vault
    event SetFeeData(address vault, address asset, FeeData feeData);

    /// @dev Redeem fee set
    event SetRedeemFee(address vault, uint256 redeemFee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the address provider
    /// @param _addressProvider Address provider
    function initialize(address _addressProvider, address _accessControl) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
        __Access_init(_accessControl);
    }

    /// @notice Swap a backing asset for a cap token or vice versa, fees are charged based on asset
    /// backing ratio
    /// @dev Only whitelisted assets are allowed, this contract must be approved by the msg.sender
    /// to pull the asset
    /// @param _amountIn Amount of tokenIn to be swapped
    /// @param _minAmountOut Minimum amount of tokenOut to be received
    /// @param _tokenIn Token to swap in
    /// @param _tokenOut Token to swap out
    /// @param _receiver Receiver of the swap
    /// @param _deadline Deadline for the swap
    function swapExactTokenForTokens(
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _tokenIn,
        address _tokenOut,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256 amountOut) {
        bool mint = ValidationLogic.validateSwap(
            DataTypes.ValidateSwapParams({
                addressProvider: address(addressProvider),
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                deadline: _deadline
            })
        );

        address capToken = mint ? _tokenOut : _tokenIn;
        address asset = mint ? _tokenIn : _tokenOut;
        address vault = addressProvider.vault(capToken);
        FeeData memory fees = feeData[vault][asset];

        (amountOut,) = AmountOutLogic.amountOut(
            DataTypes.AmountOutParams({
                mint: mint,
                asset: asset,
                amount: _amountIn,
                capToken: capToken,
                vault: vault,
                oracle: addressProvider.priceOracle(),
                slope0: fees.slope0,
                slope1: fees.slope0,
                mintKinkRatio: fees.mintKinkRatio,
                burnKinkRatio: fees.burnKinkRatio,
                optimalRatio: fees.optimalRatio
            })
        );

        ValidationLogic.validateMinAmount(_minAmountOut, amountOut);

        DataTypes.MintBurnParams memory mintBurnParams = DataTypes.MintBurnParams({
            capToken: capToken,
            amountOut: amountOut,
            asset: asset,
            amountIn: _amountIn,
            vault: vault,
            receiver: _receiver
        });

        mint ? MintBurnLogic.mint(mintBurnParams) : MintBurnLogic.burn(mintBurnParams);
    }

    /// @notice Redeem a cToken for a portion of all backing tokens
    /// @dev Only a base fee is charged, no dynamic fees
    /// @param _amountIn Amount of tokenIn to be swapped
    /// @param _minAmountOuts Minimum amounts of backing tokens to be received
    /// @param _tokenIn Token to swap in
    /// @param _receiver Receiver of the swap
    /// @param _deadline Deadline for the swap
    function redeem(
        uint256 _amountIn,
        uint256[] memory _minAmountOuts,
        address _tokenIn,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256[] memory amountOuts) {
        address vault = addressProvider.vault(_tokenIn);

        ValidationLogic.validateRedeem(vault, _deadline);

        address[] memory assets = IVault(vault).assets();

        (amountOuts,) = AmountOutLogic.redeemAmountOut(
            DataTypes.RedeemAmountOutParams({
                capToken: _tokenIn,
                amount: _amountIn,
                vault: vault,
                assets: assets,
                redeemFee: redeemFee[vault]
            })
        );

        MintBurnLogic.redeem(
            DataTypes.RedeemParams({
                capToken: _tokenIn,
                amount: _amountIn,
                vault: vault,
                assets: assets,
                amountOuts: amountOuts,
                minAmountOuts: _minAmountOuts,
                receiver: _receiver
            })
        );
    }

    /// @notice Get amount out from minting/burning a cap token
    /// @param _tokenIn Token to swap in
    /// @param _tokenOut Token to swap out
    /// @param _amountIn Amount to swap in
    /// @param amountOut Amount out
    function getAmountOut(address _tokenIn, address _tokenOut, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        bool mint = ValidationLogic.validateSwap(
            DataTypes.ValidateSwapParams({
                addressProvider: address(addressProvider),
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                deadline: block.timestamp
            })
        );

        address capToken = mint ? _tokenOut : _tokenIn;
        address asset = mint ? _tokenIn : _tokenOut;
        address vault = addressProvider.vault(capToken);
        FeeData memory fees = feeData[vault][asset];

        (amountOut,) = AmountOutLogic.amountOut(
            DataTypes.AmountOutParams({
                mint: mint,
                asset: asset,
                amount: _amountIn,
                capToken: capToken,
                vault: vault,
                oracle: addressProvider.priceOracle(),
                slope0: fees.slope0,
                slope1: fees.slope0,
                mintKinkRatio: fees.mintKinkRatio,
                burnKinkRatio: fees.burnKinkRatio,
                optimalRatio: fees.optimalRatio
            })
        );
    }

    /// @notice Get redeem amounts out from burning a cToken
    /// @param _tokenIn Token to swap in
    /// @param _amountIn Amount to swap in
    /// @param amountOuts Amounts out
    function getRedeemAmountOut(address _tokenIn, uint256 _amountIn)
        external
        view
        returns (uint256[] memory amountOuts)
    {
        address vault = addressProvider.vault(_tokenIn);

        ValidationLogic.validateRedeem(vault, block.timestamp);

        address[] memory assets = IVault(vault).assets();

        (amountOuts,) = AmountOutLogic.redeemAmountOut(
            DataTypes.RedeemAmountOutParams({
                capToken: _tokenIn,
                amount: _amountIn,
                vault: vault,
                assets: assets,
                redeemFee: redeemFee[vault]
            })
        );
    }

    /// @notice Set the allocation slopes and ratios for an asset in a vault
    /// @param _vault Vault address
    /// @param _asset Asset address
    /// @param _feeData Fee slopes and ratios for the asset in the vault
    function setFeeData(address _vault, address _asset, FeeData calldata _feeData)
        external
        checkAccess(this.setFeeData.selector)
    {
        feeData[_vault][_asset] = _feeData;
        emit SetFeeData(_vault, _asset, _feeData);
    }

    /// @notice Set the redeem fee for a vault
    /// @param _vault Vault address
    /// @param _redeemFee Redeem fee amount
    function setRedeemFee(address _vault, uint256 _redeemFee) external checkAccess(this.setFeeData.selector) {
        redeemFee[_vault] = _redeemFee;
        emit SetRedeemFee(_vault, _redeemFee);
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
