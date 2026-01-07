// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Access } from "../access/Access.sol";
import { IPriceOracle } from "../interfaces/IPriceOracle.sol";
import { ISwapper } from "../interfaces/ISwapper.sol";
import { SwapperStorageUtils } from "../storage/SwapperStorageUtils.sol";
import { BytesLib } from "./BytesLib.sol";

/// @title Swapper
/// @author kexley, Cap Labs
/// @notice Upgradeable swapper for swapping between two tokens using a price oracle
contract Swapper is ISwapper, UUPSUpgradeable, Access, SwapperStorageUtils {
    using SafeERC20 for IERC20Metadata;
    using BytesLib for bytes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ISwapper
    function initialize(address _accessControl, address _oracle) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
        getSwapperStorage().oracle = IPriceOracle(_oracle);
    }

    /// @inheritdoc ISwapper
    function swap(address _fromToken, address _toToken, uint256 _amountIn) external returns (uint256 amountOut) {
        uint256 minAmountOut = _getAmountOut(_fromToken, _toToken, _amountIn);
        amountOut = _swap(_fromToken, _toToken, _amountIn, minAmountOut);
    }

    /// @inheritdoc ISwapper
    function swap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minAmountOut)
        external
        returns (uint256 amountOut)
    {
        amountOut = _swap(_fromToken, _toToken, _amountIn, _minAmountOut);
    }

    /// @inheritdoc ISwapper
    function getAmountOut(address _fromToken, address _toToken, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        amountOut = _getAmountOut(_fromToken, _toToken, _amountIn);
    }

    /// @inheritdoc ISwapper
    function oracle() external view returns (IPriceOracle priceOracle) {
        priceOracle = getSwapperStorage().oracle;
    }

    /// @inheritdoc ISwapper
    function swapInfo(address _fromToken, address _toToken) external view returns (ISwapper.SwapInfo memory _swapInfo) {
        _swapInfo = getSwapperStorage().swapInfo[_fromToken][_toToken];
    }

    /// @dev Use the oracle to get prices for both _fromToken and _toToken and calculate the
    /// estimated output reduced by the slippage
    /// @param _fromToken Token to swap from
    /// @param _toToken Token to swap to
    /// @param _amountIn Amount of _fromToken to use in the swap
    /// @return amountOut Amount of _toToken returned by the swap
    function _getAmountOut(address _fromToken, address _toToken, uint256 _amountIn)
        private
        view
        returns (uint256 amountOut)
    {
        (uint256 fromPrice, uint256 toPrice) = _getPrices(_fromToken, _toToken);
        uint8 decimals0 = IERC20Metadata(_fromToken).decimals();
        uint8 decimals1 = IERC20Metadata(_toToken).decimals();
        uint256 slippage = getSwapperStorage().swapInfo[_fromToken][_toToken].slippage;
        amountOut = _calculateAmountOut(_amountIn, fromPrice, toPrice, decimals0, decimals1);
        amountOut = amountOut * slippage / 1 ether;
    }

    /// @dev _fromToken is pulled into this contract from the caller, swap is executed according to
    /// the stored data, resulting _toTokens are sent to the caller
    /// @param _fromToken Token to swap from
    /// @param _toToken Token to swap to
    /// @param _amountIn Amount of _fromToken to use in the swap
    /// @param _minAmountOut Minimum amount of _toToken that is acceptable to be returned to caller
    /// @return amountOut Amount of _toToken returned to the caller
    function _swap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minAmountOut)
        private
        returns (uint256 amountOut)
    {
        IERC20Metadata(_fromToken).safeTransferFrom(msg.sender, address(this), _amountIn);
        _executeSwap(_fromToken, _toToken, _amountIn, _minAmountOut);
        amountOut = IERC20Metadata(_toToken).balanceOf(address(this));
        if (amountOut < _minAmountOut) revert SlippageExceeded(amountOut, _minAmountOut);
        if (amountOut == 0) revert NoAmountOut();
        IERC20Metadata(_toToken).safeTransfer(msg.sender, amountOut);
        emit Swap(msg.sender, _fromToken, _toToken, _amountIn, amountOut);
    }

    /// @dev Fetch the stored swap info for the route between the two tokens, insert the encoded
    /// balance and minimum output to the payload and call the stored router with the data
    /// @param _fromToken Token to swap from
    /// @param _toToken Token to swap to
    /// @param _amountIn Amount of _fromToken to use in the swap
    /// @param _minAmountOut Minimum amount of _toToken that is acceptable to be returned to caller
    function _executeSwap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minAmountOut) private {
        ISwapper.SwapInfo memory swapData = getSwapperStorage().swapInfo[_fromToken][_toToken];
        address router = swapData.router;
        if (router == address(0)) revert NoSwapData(_fromToken, _toToken);
        bytes memory data = swapData.data;

        // If the amount index is greater than 0, insert the amount into the data
        if (swapData.amountIndex > 0) {
            data = _insertData(data, swapData.amountIndex, abi.encode(_amountIn));
        }

        IERC20Metadata(_fromToken).forceApprove(router, type(uint256).max);
        (bool success,) = router.call(data);
        if (!success) revert SwapFailed(router, data);
    }

    /// @dev Helper function to insert data to an in-memory bytes string
    /// @param _data Template swap payload with blank spaces to overwrite
    /// @param _index Start location in the data byte string where the _newData should overwrite
    /// @param _newData New data that is to be inserted
    /// @return data The resulting string from the insertion
    function _insertData(bytes memory _data, uint256 _index, bytes memory _newData)
        private
        pure
        returns (bytes memory data)
    {
        data = bytes.concat(
            bytes.concat(_data.slice(0, _index), _newData), _data.slice(_index + 32, _data.length - (_index + 32))
        );
    }

    /// @dev Fetch prices from the oracle
    /// @param _fromToken Token to swap from
    /// @param _toToken Token to swap to
    /// @return fromPrice Price of token to swap from
    /// @return toPrice Price of token to swap to
    function _getPrices(address _fromToken, address _toToken)
        private
        view
        returns (uint256 fromPrice, uint256 toPrice)
    {
        IPriceOracle priceOracle = getSwapperStorage().oracle;
        (fromPrice,) = priceOracle.getPrice(_fromToken);
        if (fromPrice == 0) revert PriceFailed(_fromToken);
        (toPrice,) = priceOracle.getPrice(_toToken);
        if (toPrice == 0) revert PriceFailed(_toToken);
    }

    /// @dev Calculate the amount out given the prices and the decimals of the tokens involved
    /// @param _amountIn Amount of _fromToken to use in the swap
    /// @param _price0 Price of the _fromToken
    /// @param _price1 Price of the _toToken
    /// @param _decimals0 Decimals of the _fromToken
    /// @param _decimals1 Decimals of the _toToken
    function _calculateAmountOut(
        uint256 _amountIn,
        uint256 _price0,
        uint256 _price1,
        uint8 _decimals0,
        uint8 _decimals1
    ) private pure returns (uint256 amountOut) {
        amountOut = _amountIn * (_price0 * 10 ** _decimals1) / (_price1 * 10 ** _decimals0);
    }

    /* ----------------------------------- OWNER FUNCTIONS ----------------------------------- */

    /// @inheritdoc ISwapper
    function setSwapInfo(address _fromToken, address _toToken, SwapInfo calldata _swapInfo)
        external
        checkAccess(this.setSwapInfo.selector)
    {
        getSwapperStorage().swapInfo[_fromToken][_toToken] = _swapInfo;
        emit SetSwapInfo(_fromToken, _toToken, _swapInfo);
    }

    /// @inheritdoc ISwapper
    function setSwapInfos(address[] calldata _fromTokens, address[] calldata _toTokens, SwapInfo[] calldata _swapInfos)
        external
        checkAccess(this.setSwapInfos.selector)
    {
        uint256 tokenLength = _fromTokens.length;
        SwapperStorage storage $ = getSwapperStorage();
        for (uint i; i < tokenLength;) {
            $.swapInfo[_fromTokens[i]][_toTokens[i]] = _swapInfos[i];
            emit SetSwapInfo(_fromTokens[i], _toTokens[i], _swapInfos[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @inheritdoc ISwapper
    function setOracle(address _oracle) external checkAccess(this.setOracle.selector) {
        getSwapperStorage().oracle = IPriceOracle(_oracle);
        emit SetOracle(_oracle);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
