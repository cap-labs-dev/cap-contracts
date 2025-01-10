// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAddressProvider } from "../interfaces/IAddressProvider.sol";
import { IVaultDataProvider } from "../interfaces/IVaultDataProvider.sol";

import { ValidationLogic } from "./libraries/ValidationLogic.sol";
import { AmountOutLogic } from "./libraries/AmountOutLogic.sol";
import { MintBurnLogic } from "./libraries/MintBurnLogic.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";

/// @title Minter/burner for cap tokens
/// @author kexley, @capLabs
/// @notice Cap tokens are minted or burned in exchange for collateral ratio of the backing tokens
/// @dev Dynamic fees are applied according to the allocation of assets in the basket. Increasing
/// the supply of a excessive asset or burning for an scarce asset will charge fees on a kinked
/// slope. Redeem can be used to avoid these fees by burning for the current ratio of assets.
contract Minter is UUPSUpgradeable {
    /// @notice Minter admin role
    bytes32 public constant MINTER_ADMIN = keccak256("MINTER_ADMIN");

    /// @notice Address provider
    IAddressProvider public addressProvider;

    /// @dev Only authorized addresses can call these functions
    modifier onlyAdmin() {
        addressProvider.checkRole(MINTER_ADMIN, msg.sender);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the address provider
    /// @param _addressProvider Address provider
    function initialize(address _addressProvider) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
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
                vaultDataProvider: addressProvider.vaultDataProvider(),
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                deadline: _deadline
            })
        );

        address capToken = mint ? _tokenOut : _tokenIn;
        address asset = mint ? _tokenIn : _tokenOut;
        address vault = IVaultDataProvider(addressProvider.vaultDataProvider()).vault(capToken);
        IVaultDataProvider.AllocationData memory allocationData =
            IVaultDataProvider(addressProvider.vaultDataProvider()).allocationData(vault, asset);

        (amountOut,) = AmountOutLogic.amountOut(
            DataTypes.AmountOutParams({
                mint: mint,
                asset: asset,
                amount: _amountIn,
                capToken: capToken,
                vault: vault,
                oracle: addressProvider.priceOracle(),
                slope0: allocationData.slope0,
                slope1: allocationData.slope0,
                mintKinkRatio: allocationData.mintKinkRatio,
                burnKinkRatio: allocationData.burnKinkRatio,
                optimalRatio: allocationData.optimalRatio
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
        IVaultDataProvider vaultDataProvider = IVaultDataProvider(addressProvider.vaultDataProvider());

        address vault = vaultDataProvider.vault(_tokenIn);

        ValidationLogic.validateRedeem(vault, _deadline);

        IVaultDataProvider.VaultData memory vaultData = vaultDataProvider.vaultData(vault);

        (amountOuts,) = AmountOutLogic.redeemAmountOut(
            DataTypes.RedeemAmountOutParams({
                capToken: _tokenIn,
                amount: _amountIn,
                vault: vault,
                assets: vaultData.assets,
                redeemFee: vaultData.redeemFee
            })
        );

        MintBurnLogic.redeem(
            DataTypes.RedeemParams({
                capToken: _tokenIn,
                amount: _amountIn,
                vault: vault,
                assets: vaultData.assets,
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
        address vaultDataProvider = addressProvider.vaultDataProvider();

        bool mint = ValidationLogic.validateSwap(
            DataTypes.ValidateSwapParams({
                vaultDataProvider: vaultDataProvider,
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                deadline: block.timestamp
            })
        );

        address capToken = mint ? _tokenOut : _tokenIn;
        address asset = mint ? _tokenIn : _tokenOut;
        address vault = IVaultDataProvider(vaultDataProvider).vault(capToken);
        IVaultDataProvider.AllocationData memory allocationData =
            IVaultDataProvider(vaultDataProvider).allocationData(vault, asset);

        (amountOut,) = AmountOutLogic.amountOut(
            DataTypes.AmountOutParams({
                mint: mint,
                asset: asset,
                amount: _amountIn,
                capToken: capToken,
                vault: vault,
                oracle: addressProvider.priceOracle(),
                slope0: allocationData.slope0,
                slope1: allocationData.slope0,
                mintKinkRatio: allocationData.mintKinkRatio,
                burnKinkRatio: allocationData.burnKinkRatio,
                optimalRatio: allocationData.optimalRatio
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
        address vaultDataProvider = addressProvider.vaultDataProvider();
        address vault = IVaultDataProvider(vaultDataProvider).vault(_tokenIn);

        ValidationLogic.validateRedeem(vault, block.timestamp);

        IVaultDataProvider.VaultData memory vaultData = IVaultDataProvider(vaultDataProvider).vaultData(vault);

        (amountOuts,) = AmountOutLogic.redeemAmountOut(
            DataTypes.RedeemAmountOutParams({
                capToken: _tokenIn,
                amount: _amountIn,
                vault: vault,
                assets: vaultData.assets,
                redeemFee: vaultData.redeemFee
            })
        );
    }

    function _authorizeUpgrade(address) internal override onlyAdmin { }
}
