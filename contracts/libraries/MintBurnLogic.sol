// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";
import { IVault } from "../interfaces/IVault.sol";
import { IOracle } from "../interfaces/IOracle.sol";

library MintBurnLogic {
    function getMint(
        address _registry,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) external view returns (uint256 amountOut, uint256 fee) {
        IRegistry registry = IRegistry(_registry);
        IVault vault = IVault(registry.basket[_tokenOut].vault);
        IOracle oracle = IVault(registry.oracle());

        uint256 basketValue = _getBasketValue(registry, vault, oracle, _tokenOut);
        uint256 basketAssetValue = vault.totalSupplies(_tokenIn) * oracle.getPrice(_tokenIn);
        uint256 mintValue = _amount * oracle.getPrice(_tokenIn);
        uint256 newRatio = ( basketAssetValue + mintValue ) * 1e27 / ( basketValue + mintValue );

        amountOut = mintValue * IERC20(_tokenOut).totalSupply() / basketValue;
        (amountOut, fee) = _applyFeeSlopes(
            true,
            amountOut,
            newRatio,
            registry.basket[_tokenOut].optimiumRatio[_tokenIn],
            registry.basket[_tokenOut].mintKinkRatio[_tokenIn],
            registry.basket[_tokenOut].baseFee[_tokenIn],
            registry.basket[_tokenOut].slope0[_tokenIn],
            registry.basket[_tokenOut].slope1[_tokenIn]
        );
    }

    function getBurn(
        address _registry,
        address _tokenIn,
        address _tokenOut,
        uint256 _amount
    ) external view returns (uint256 amountOut, uint256 fee) {
        IRegistry registry = IRegistry(_registry);
        IVault vault = IVault(registry.basket[_tokenIn].vault);
        IOracle oracle = IVault(registry.oracle());

        uint256 basketValue = _getBasketValue(registry, vault, oracle, _tokenIn);
        uint256 basketAssetValue = vault.totalSupplies(_tokenOut) * oracle.getPrice(_tokenOut);
        uint256 mintValue = _amount * basketValue / _tokenIn.totalSupply();
        uint256 newRatio = ( basketAssetValue - mintValue ) * 1e27 / ( basketValue - mintValue );

        amountOut = mintValue / (oracle.getPrice(_tokenOut));
        (amountOut, fee) = _applyFeeSlopes(
            false,
            amountOut,
            newRatio,
            registry.basket[_tokenIn].optimiumRatio[_tokenOut],
            registry.basket[_tokenIn].burnKinkRatio[_tokenOut],
            registry.basket[_tokenIn].baseFee[_tokenOut],
            registry.basket[_tokenIn].slope0[_tokenOut],
            registry.basket[_tokenIn].slope1[_tokenOut]
        );
    }

    function getRedeem(
        address _registry,
        address _tokenIn,
        uint256 _amountIn
    ) external view returns (uint256[] memory amounts, uint256[] memory fees) {
        IRegistry registry = IRegistry(_registry);
        IVault vault = IVault(registry.basket[_tokenIn].vault);

        uint256 shares = _amountIn / IERC20(_tokenIn).totalSupply();
        address[] memory assets = registry.basket[_tokenIn].assets;
        uint256 assetLength = assets.length;
        for (uint256 i; i < assetLength; ++i) {
            address asset = assets[i];
            uint256 withdrawAmount = vault.totalSupplies(asset) * shares;
            fees[i] = withdrawAmount * registry.basket[_tokenIn].baseFee / 1e27;
            amounts[i] = withdrawAmount - fees[i];
        }
    }

    function _getBasketValue(IRegistry _registry, IVault _vault, IOracle _oracle, address _cToken) internal view returns (uint256 totalValue) {
        address[] memory assets = _registry.basket[_cToken].assets;
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
        uint256 _ratio0,
        uint256 _ratio1,
        uint256 _ratio2,
        uint256 _rate,
        uint256 _slope0,
        uint256 _slope1
    ) internal pure returns (uint256 amountOut, uint256 fee) {
        if (mint) {
            if (_ratio0 > _ratio1) {
                if (_ratio0 > _ratio2) {
                    uint256 excessRatio = _ratio0 - _ratio2;
                    _rate += _slope1 + ( _slope2 * excessRatio );
                } else {
                    _rate += _slope1 * _ratio0 / _ratio2;
                }
            }
        } else {
            if (_ratio0 < _ratio1) {
                if (_ratio0 < _ratio2) {
                    uint256 excessRatio = _ratio2 - _ratio0;
                    _rate += _slope0 + ( _slope1 * excessRatio );
                } else {
                    _rate += _slope0 * _ratio2 / _ratio0;
                }
            }
        }

        if (_rate > 1e27) _rate = 1e27;
        fee = _amountOut * _rate / 1e27;
        amountOut = _amountOut - fee;
    }
}
