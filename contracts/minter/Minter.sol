// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";
import { IVault } from "../interfaces/IVault.sol";
import { ICToken } from "../interfaces/ICToken.sol";

import { MintBurnLogic } from "./libraries/MintBurnLogic.sol";

/// @title Minter/burner for cTokens
/// @author kexley, @capLabs
/// @notice cTokens are minted or burned in exchange for collateral ratio of the backing tokens
/// @dev Dynamic fees are applied according to the allocation of assets in the basket. Increasing
/// the supply of a excessive asset or burning for an scarce asset will charge fees on a kinked 
/// slope. Redeem can be used to avoid these fees by burning for the current ratio of assets.
contract Minter is Initializable, AccessControlEnumerableUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Registry that controls fees, whitelisting assets and basket allocations
    IRegistry public registry;

    /// @dev Pair of assets is not supported
    error PairNotSupported(address asset0, address asset1);

    /// @dev Assets is not supported
    error AssetNotSupported(address asset);

    /// @dev Amount out is below minimum
    error Slippage(uint256 amount, uint256 minAmount);

    /// @dev Redeemed amount out is below minimum for an asset
    error RedeemSlippage(address asset, uint256 amount, uint256 minAmount);

    /// @dev Deadline has passed
    error PastDeadline();

    /// @dev Swap made
    event Swap(
        address indexed sender,
        address indexed to,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @dev Redeem made
    event Redeem(
        address indexed sender,
        address indexed to,
        address tokenIn,
        uint256 amountIn,
        uint256[] amountOuts
    );

    /// @notice Initialize the registry address and default admin
    /// @param _registry Registry address
    function initialize(address _registry) initializer external {
        registry = IRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Swap a backing asset for a cToken or vice versa, fees are charged based on asset
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
        if (_deadline != 0 && block.timestamp > _deadline) revert PastDeadline();
        bool mint = _validateAssets(_tokenIn, _tokenOut);
        if (mint) {
            IVault vault = IVault(registry.basketVault(_tokenOut));
            (amountOut,) = MintBurnLogic.getMint(registry, _tokenIn, _tokenOut, _amountIn);
            ICToken(_tokenOut).mint(msg.sender, amountOut);
            IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
            IERC20(_tokenIn).forceApprove(address(vault), _amountIn);
            vault.deposit(_tokenIn, _amountIn);
        } else {
            IVault vault = IVault(registry.basketVault(_tokenIn));
            (amountOut,) = MintBurnLogic.getBurn(registry, _tokenIn, _tokenOut, _amountIn);
            ICToken(_tokenIn).burn(msg.sender, _amountIn);
            vault.withdraw(_tokenOut, amountOut, _receiver);
        }
        if (amountOut < _minAmountOut) revert Slippage(amountOut, _minAmountOut);
        emit Swap(msg.sender, _receiver, _tokenIn, _tokenOut, _amountIn, amountOut);
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
        if (_deadline != 0 && block.timestamp > _deadline) revert PastDeadline();
        _validateAsset(_tokenIn);
        ICToken(_tokenIn).burn(msg.sender, _amountIn);

        uint256[] memory fees = new uint256[](_minAmountOuts.length);
        (amountOuts, fees) = MintBurnLogic.getRedeem(registry, _tokenIn, _amountIn);
        address[] memory assets = registry.basketAssets(_tokenIn);
        IVault vault = IVault(registry.basketVault(_tokenIn));

        uint256 amountLength = amountOuts.length;
        for (uint256 i; i < amountLength; ++i) {
            uint256 amount = amountOuts[i];
            if (amount < _minAmountOuts[i]) revert RedeemSlippage(assets[i], amount, _minAmountOuts[i]);
            vault.withdraw(assets[i], amount, _receiver);
        }
        emit Redeem(msg.sender, _receiver, _tokenIn, _amountIn, amountOuts);
    }

    /// @notice Get amount out from minting/burning a cToken
    /// @param _tokenIn Token to swap in
    /// @param _tokenOut Token to swap out
    /// @param _amountIn Amount to swap in
    /// @param amountOut Amount out
    function getAmountOut(
        address _tokenIn, 
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        bool mint = _validateAssets(_tokenIn, _tokenOut);
        if (mint) {
            (amountOut,) = MintBurnLogic.getMint(registry, _tokenIn, _tokenOut, _amountIn);
        } else {
            (amountOut,) = MintBurnLogic.getBurn(registry, _tokenIn, _tokenOut, _amountIn);
        }
    }

    /// @notice Get redeem amounts out from burning a cToken
    /// @param _tokenIn Token to swap in
    /// @param _amountIn Amount to swap in
    /// @param amounts Amounts out
    function getRedeemAmountOut(
        address _tokenIn,
        uint256 _amountIn
    ) external view returns (uint256[] memory amounts) {
        (amounts,) = MintBurnLogic.getRedeem(registry, _tokenIn, _amountIn);
    }

    /* -------------------- VALIDATION -------------------- */

    /// @dev Validate assets are whitelisted and are in a linked basket
    /// @param _tokenIn Token to swap in
    /// @param _tokenOut Token to swap out
    /// @return mint Whether the swap is a mint or a burn
    function _validateAssets(address _tokenIn, address _tokenOut) internal view returns (bool mint) {
        if (registry.supportedCToken(_tokenIn) && registry.basketSupportsAsset(_tokenIn, _tokenOut)) {
            mint = true;
        } else if (!(registry.supportedCToken(_tokenOut) && registry.basketSupportsAsset(_tokenOut, _tokenIn))) {
            revert PairNotSupported(_tokenIn, _tokenOut);
        }
    }

    /// @dev Validate if a single asset is a cToken
    /// @param _cToken Token to redeem
    function _validateAsset(address _cToken) internal view {
        if (!registry.supportedCToken(_cToken)) revert AssetNotSupported(_cToken);
    }
}
