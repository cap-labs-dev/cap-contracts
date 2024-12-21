// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IRegistry } from "../../interfaces/IRegistry.sol";
import { IVault } from "../../interfaces/IVault.sol";
import { IOracle } from "../../interfaces/IOracle.sol";

library MintBurnLogic {
    function getMint(
        IRegistry _registry,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) external view returns (uint256 amountOut, uint256 fee) {
        IVault vault = IVault(_registry.basketVault(_tokenOut));
        IOracle oracle = IOracle(_registry.oracle());

        uint256 basketValue = _getBasketValue(_registry, vault, oracle, _tokenOut);
        uint256 mintValue = _amount * oracle.getPrice(_tokenIn);

        if (basketValue == 0) {  // TODO: should we force init vaults with some assets to avoid all this?
            amountOut = mintValue;
            fee = 0; // TODO: Definitely not ok
        } else {
            uint256 basketAssetValue = vault.totalSupplies(_tokenIn) * oracle.getPrice(_tokenIn);
            uint256 newRatio = ( basketAssetValue + mintValue ) * 1e27 / ( basketValue + mintValue );
            IRegistry.BasketFees memory basketFees = _registry.basketFees(_tokenOut, _tokenIn);
            
            amountOut = mintValue * IERC20(_tokenOut).totalSupply() / basketValue;
            (amountOut, fee) = _applyFeeSlopes(
                true,
                amountOut,
                newRatio,
                basketFees
            );
        }
    }

    function getBurn(
        IRegistry _registry,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) external view returns (uint256 amountOut, uint256 fee) {
        IVault vault = IVault(_registry.basketVault(_tokenIn));
        IOracle oracle = IOracle(_registry.oracle());

        uint256 basketValue = _getBasketValue(_registry, vault, oracle, _tokenIn);
        uint256 basketAssetValue = vault.totalSupplies(_tokenOut) * oracle.getPrice(_tokenOut);
        uint256 mintValue = _amount * basketValue / IERC20(_tokenIn).totalSupply();
        uint256 newRatio = ( basketAssetValue - mintValue ) * 1e27 / ( basketValue - mintValue );

        IRegistry.BasketFees memory basketFees = _registry.basketFees(_tokenIn, _tokenOut);

        amountOut = mintValue / (oracle.getPrice(_tokenOut));
        (amountOut, fee) = _applyFeeSlopes(
            false,
            amountOut,
            newRatio,
            basketFees
        );
    }

    function getRedeem(
        IRegistry _registry,
        address _tokenIn,
        uint256 _amountIn
    ) external view returns (uint256[] memory amounts, uint256[] memory fees) {
        IVault vault = IVault(_registry.basketVault(_tokenIn));

        uint256 shares = _amountIn / IERC20(_tokenIn).totalSupply();
        address[] memory assets = _registry.basketAssets(_tokenIn);
        uint256 assetLength = assets.length;
        for (uint256 i; i < assetLength; ++i) {
            address asset = assets[i];
            uint256 withdrawAmount = vault.totalSupplies(asset) * shares;
            fees[i] = withdrawAmount * _registry.basketBaseFee(_tokenIn) / 1e27;
            amounts[i] = withdrawAmount - fees[i];
        }
    }

    function _getBasketValue(
        IRegistry _registry,
        IVault _vault,
        IOracle _oracle,
        address _cToken
    ) internal view returns (uint256 totalValue) {
        address[] memory assets = _registry.basketAssets(_cToken);
        uint256 assetLength = assets.length;
        for (uint256 i; i < assetLength; ++i) {
            address asset = assets[i];
            // Need to normalize decimals here
            totalValue += _vault.totalSupplies(asset) * _oracle.getPrice(asset);
        }
    }

    function _applyFeeSlopes(
        bool _mint,
        uint256 _amountOut,
        uint256 _newRatio,
        IRegistry.BasketFees memory _basketFees
    ) internal pure returns (uint256 amountOut, uint256 fee) {
        uint256 rate;
        if (_mint) {
            if (_newRatio > _basketFees.optimalRatio) {
                if (_newRatio > _basketFees.mintKinkRatio) {
                    uint256 excessRatio = _newRatio - _basketFees.mintKinkRatio;
                    rate = _basketFees.slope0 + ( _basketFees.slope1 * excessRatio );
                } else {
                    rate = _basketFees.slope0 * _newRatio / _basketFees.mintKinkRatio;
                }
            }
        } else {
            if (_newRatio < _basketFees.optimalRatio) {
                if (_newRatio < _basketFees.burnKinkRatio) {
                    uint256 excessRatio = _basketFees.burnKinkRatio - _newRatio;
                    rate = _basketFees.slope0 + ( _basketFees.slope1 * excessRatio );
                } else {
                    rate = _basketFees.slope0 * _basketFees.burnKinkRatio / _newRatio;
                }
            }
        }

        if (rate > 1e27) rate = 1e27;
        fee = _amountOut * rate / 1e27;
        amountOut = _amountOut - fee;
    }
}
