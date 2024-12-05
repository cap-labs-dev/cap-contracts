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
            (amountOut,) = MintBurnLogic.getMint(registry, _tokenIn, _tokenOut, _amountIn);
            IERC20(_tokenOut).mint(msg.sender, amountOut);
            IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amountIn);
            IERC20(_asset).forceApprove(address(vault), _amountIn);
            vault.deposit(_asset, _amountIn);
        } else {
            (amountOut,) = MintBurnLogic.getBurn(registry, _tokenIn, _tokenOut, _amountIn);
            IERC20(_tokenIn).burn(msg.sender, _amountIn);
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
        IERC20(_tokenIn).burn(msg.sender, _amountIn);
        (amountOuts, uint256[] memory fees) = MintBurnLogic.getRedeem(registry, _tokenIn, _amountIn);

        uint256 amountLength = amountOuts.length;
        for (uint256 i; i < amountLength; ++i) {
            address amount = amountOuts[i];
            if (amount < minAmountOuts[i]) revert RedeemSlippage(asset, amount, minAmountOuts[i]);
            vault.withdraw(asset, amount, _receiver);
        }
    }

    function getAmountOut(address _tokenIn, address _tokenOut, uint256 _amountIn) external view returns (uint256 amount) {
        bool mint = registry.supportedAsset[_tokenOut];
        if (mint) {
            (amount, fee) = getMint(_tokenIn, _tokenOut, _amount);
        } else {
            (amount, fee) = getBurn(_tokenIn, _tokenOut, _amount);
        }
    }

    function getRedeemAmountOut(address _tokenIn, uint256 _amountIn) public view returns (uint256[] memory amounts, uint256[] memory fees) {
        (amounts, fees) = MintBurnLogic.getRedeem(registry, _tokenIn, _amountIn);
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
