// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Minter is Initializable, AccessControlEnumerableUpgradeable {

    struct Basket {
        address[] assets;
        uint256 baseFee;
        mapping(address => bool) supportedAssets;
        mapping(address => uint256) optimiumRatio;
        mapping(address => uint256) lowerKinkRatio;
        mapping(address => uint256) upperKinkRatio;
    }

    IVault public vault;
    address[] public cTokens;
    mapping(address => bool) public supportedCToken;
    mapping(address => Basket) public basket;

    function initialize(address _vault) initializer external {
        vault = IVault(_vault);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function swapExactTokenForTokens(
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _tokenIn,
        address _tokenOut,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256 amountOut) {
        if (deadline != 0 && block.timestamp > deadline) revert PastDeadline();
        _validateAssets(_tokenIn, _tokenOut);
        bool mint = supportedCToken[_tokenOut];
        if (mint) {
            (amountOut,) = getMint(_asset, _amountIn);
            ICap(_tokenOut).mint(msg.sender, amountOut);
            IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amountIn);
            IERC20(_asset).forceApprove(address(vault), _amountIn);
            vault.deposit(_asset, _amountIn);
        } else {
            (amountOut,) = getBurn(_asset, _amountIn);
            ICap(_tokenIn).burn(msg.sender, _amountIn);
            vault.withdraw(_asset, amountOut, _receiver);
        }
        if (amountOut < _minAmountOut) revert Slippage(amountOut, _minAmountOut);
    }

    function redeem(
        uint256 _amountIn,
        uint256[] memory _minAmountOuts,
        address _tokenIn,
        address _receiver,
        uint256 _deadline
    ) external returns (uint256[] memory amountOuts) {
        if (deadline != 0 && block.timestamp > deadline) revert PastDeadline();
        _validateAsset(_tokenIn);
        ICap(_tokenIn).burn(msg.sender, _amountIn);
        (amountOuts, uint256[] memory fees) = getRedeemAmountOut(_tokenIn, _amountIn);

        uint256 amountLength = amountOuts.length;
        for (uint256 i; i < amountLength; ++i) {
            address amount = amountOuts[i];
            if (amount < minAmountOuts[i]) revert RedeemSlippage(asset, amount, minAmountOuts[i]);
            vault.withdraw(asset, amount, _receiver);
        }
    }

    function getAmountOut(address _tokenIn, address _tokenOut, uint256 _amountIn) external view returns (uint256 amount) {
        bool mint = supportedCToken[_tokenOut];
        if (mint) {
            (amount, fee) = getMint(_tokenIn, _tokenOut, _amount);
        } else {
            (amount, fee) = getBurn(_tokenIn, _tokenOut, _amount);
        }
    }

    function getRedeemAmountOut(address _tokenIn, uint256 _amountIn) public view returns (uint256[] memory amounts, uint256[] memory fees) {
        uint256 shares = _amountIn / ICap(_tokenIn).totalSupply();

        address[] memory assets = basket[_tokenIn].assets;
        uint256 assetLength = assets.length;
        for (uint256 i; i < assetLength; ++i) {
            address asset = assets[i];
            uint256 withdrawAmount = vault.totalSupplies(asset) * shares;
            fees[i] = withdrawAmount * basket[_tokenIn].baseFee / 1e27;
            amounts[i] = withdrawAmount - fees[i];
        }
    }

    /* -------------------- MINT/BURN LOGIC -------------------- */

    function getMint(address _tokenIn, address _tokenOut, uint256 _amount) public view returns (uint256 amountOut, uint256 fee) {
        (uint256 collateralValue, uint256 currentValue) = _getCollateralValue(_tokenIn, _tokenOut);
        uint256 assetValue = _amount * oracle.getPrice(_tokenIn);
        amountOut = assetValue * _tokenOut.totalSupply() / collateralValue;
        uint256 newRatio = ( currentValue + assetValue ) * 1e27 / ( collateralValue + assetValue );
        uint256 rate = basket[_tokenOut].baseFee;

        if (newRatio > basket[_tokenOut].optimiumRatio[_tokenIn]) {
            uint256 kinkRatio = basket[_tokenOut].upperKinkRatio[_tokenIn];
            if (newRatio > kinkRatio) {
                uint256 excessRatio = newRatio - kinkRatio;
                rate += slope1 + ( slope2 * excessRatio );
            } else {
                rate += slope1 * newRatio / kinkRatio;
            }
        }

        if (rate > 1e27) rate = 1e27;
        fee = amountOut * rate / 1e27;
        amountOut = amountOut - fee;
    }

    function getBurn(address _tokenIn, address _tokenOut, uint256 _amount) public view returns (uint256 amountOut, uint256 fee) {
        uint256 collateralValue = _getCollateralValue(_tokenIn);
        uint256 currentValue = vault.totalSupplies(_tokenOut) * oracle.getPrice(_tokenOut);
        uint256 assetValue = _amount * collateralValue / _tokenIn.totalSupply();
        amountOut = assetValue / (oracle.getPrice(_tokenOut));
        uint256 newRatio = ( currentValue - assetValue ) * 1e27 / ( collateralValue - assetValue );
        uint256 rate = basket[_tokenOut].baseFee;

        if (newRatio < basket[_tokenIn].optimiumRatio[_tokenOut]) {
            uint256 kinkRatio = basket[_tokenIn].lowerKinkRatio[_tokenOut];
            if (newRatio < kinkRatio) {
                uint256 excessRatio = kinkRatio - newRatio;
                rate += slope1 + ( slope2 * excessRatio );
            } else {
                rate += slope1 * kinkRatio / newRatio;
            }
        }

        if (rate > 1e27) rate = 1e27;
        fee = amountOut * rate / 1e27;
        amountOut = amountOut - fee;
    }

    function _getCollateralValue(address _cToken) internal view returns (uint256 totalValue) {
        address[] memory assets = basket[_cToken].assets;
        uint256 assetLength = assets.length;
        for (uint256 i; i < assetLength; ++i) {
            address asset = assets[i];
            // Need to normalize decimals here
            totalValue += vault.totalSupplies(asset) * oracle.getPrice(asset);
        }
    }

    /* -------------------- VALIDATION -------------------- */

    function _validateAssets(address _tokenIn, address _tokenOut) internal {
        if (!(supportedCToken[_tokenIn] && basket[_tokenIn].supportedAssets[_tokenOut]) 
            && !(supportedCToken[_tokenOut] && basket[_tokenOut].supportedAssets[_tokenIn])) 
        {
            revert PairNotValid(_tokenIn, _tokenOut);
        }
    }

    function _validateAsset(address _cToken) internal {
        if (!supportedCToken[_cToken]) revert TokenNotSupported(_cToken);
    }
}
