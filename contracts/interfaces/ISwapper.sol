// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IPriceOracle } from "./IPriceOracle.sol";

/// @title ISwapper
/// @author kexley, Cap Labs
/// @notice Interface for the Swapper contract
interface ISwapper {
    /// @dev Stored data for a swap
    /// @param router Target address that will handle the swap
    /// @param data Payload of a template swap between the two tokens
    /// @param amountIndex Location in the data byte string where the amount should be overwritten
    /// @param slippage Slippage tolerance for the swap (in 18 decimals)
    struct SwapInfo {
        address router;
        bytes data;
        uint256 amountIndex;
        uint256 slippage;
    }

    /// @dev Swapper storage
    /// @param oracle Oracle used to calculate the minimum output of a swap
    /// @param swapInfo Stored swap info for a token pair
    struct SwapperStorage {
        IPriceOracle oracle;
        mapping(address => mapping(address => SwapInfo)) swapInfo;
    }

    /// @dev Price update failed for a token
    /// @param token Address of token that failed the price update
    error PriceFailed(address token);

    /// @dev No amount out was returned from the swap
    error NoAmountOut();

    /// @dev No swap data has been set by the owner
    /// @param fromToken Token to swap from
    /// @param toToken Token to swap to
    error NoSwapData(address fromToken, address toToken);

    /// @dev Swap call failed
    /// @param router Target address of the failed swap call
    /// @param data Payload of the failed call
    error SwapFailed(address router, bytes data);

    /// @dev Not enough output was returned from the swap
    /// @param amountOut Amount returned by the swap
    /// @param minAmountOut Minimum amount required from the swap
    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);

    /// @notice Swap between two tokens
    /// @param caller Address of the caller of the swap
    /// @param fromToken Address of the source token
    /// @param toToken Address of the destination token
    /// @param amountIn Amount of source token inputted to the swap
    /// @param amountOut Amount of destination token outputted from the swap
    event Swap(
        address indexed caller, address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut
    );

    /// @notice Set new swap info for the route between two tokens
    /// @param fromToken Address of the source token
    /// @param toToken Address of the destination token
    /// @param swapInfo Struct of stored swap information for the pair of tokens
    event SetSwapInfo(address indexed fromToken, address indexed toToken, SwapInfo swapInfo);

    /// @notice Set a new oracle
    /// @param oracle New oracle address
    event SetOracle(address oracle);

    /// @notice Initialize the swapper
    /// @param _owner Owner of the swapper
    /// @param _oracle Oracle used to calculate the minimum output of a swap
    function initialize(address _owner, address _oracle) external;

    /// @notice Swap between two tokens with slippage calculated using the oracle
    /// @param _fromToken Address of the source token
    /// @param _toToken Address of the destination token
    /// @param _amountIn Amount of _fromToken to use in the swap
    /// @return amountOut Amount of _toToken returned to the caller
    function swap(address _fromToken, address _toToken, uint256 _amountIn) external returns (uint256 amountOut);

    /// @notice Swap between two tokens with slippage provided by the caller
    /// @param _fromToken Address of the source token
    /// @param _toToken Address of the destination token
    /// @param _amountIn Amount of _fromToken to use in the swap
    /// @param _minAmountOut Minimum amount of _toToken that is acceptable to be returned to caller
    /// @return amountOut Amount of _toToken returned to the caller
    function swap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minAmountOut)
        external
        returns (uint256 amountOut);

    /// @notice Get the amount out from a simulated swap with slippage and non-fresh prices
    /// @param _fromToken Address of the source token
    /// @param _toToken Address of the destination token
    /// @param _amountIn Amount of _fromToken to use in the swap
    /// @return amountOut Amount of _toToken returned from the swap
    function getAmountOut(address _fromToken, address _toToken, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut);

    /// @notice Set the oracle used to calculate the minimum output of a swap
    /// @param _oracle New oracle address
    function setOracle(address _oracle) external;

    /// @notice Set the swap info for a token pair
    /// @param _fromToken Address of the source token
    /// @param _toToken Address of the destination token
    /// @param _swapInfo Struct of stored swap information for the pair of tokens
    function setSwapInfo(address _fromToken, address _toToken, SwapInfo calldata _swapInfo) external;

    /// @notice Set multiple swap info for a token pair
    /// @param _fromTokens Addresses of the source tokens
    /// @param _toTokens Addresses of the destination tokens
    /// @param _swapInfos Structs of stored swap information for the pairs of tokens
    function setSwapInfos(address[] calldata _fromTokens, address[] calldata _toTokens, SwapInfo[] calldata _swapInfos)
        external;

    /// @notice Get the oracle used to calculate the minimum output of a swap
    /// @return priceOracle Price oracle used to calculate the minimum output of a swap
    function oracle() external view returns (IPriceOracle priceOracle);

    /// @notice Get the swap info for a token pair
    /// @param _fromToken Address of the source token
    /// @param _toToken Address of the destination token
    /// @return _swapInfo Struct of stored swap information for the pair of tokens
    function swapInfo(address _fromToken, address _toToken) external view returns (SwapInfo memory _swapInfo);
}
