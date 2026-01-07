// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IOracle } from "../../interfaces/IOracle.sol";
import { IUniswapV3Pool, TickMath, UniswapV3OracleLibrary } from "./UniswapV3OracleLibrary.sol";

/// @title UniswapV3 Adapter
/// @author kexley, Cap Labs
/// @notice On-chain oracle using UniswapV3
library UniswapV3Adapter {
    /// @dev Array length is invalid
    error ArrayLength();

    /// @dev No base price was found for the base token
    error NoBasePrice(address token);

    /// @dev Token is not in the pair
    error TokenNotInPair(address token, address pool);

    /// @notice Fetch price from the UniswapV3 pools using the TWAP observations
    /// @param _data Payload from the central oracle with the addresses of the token route, pool
    /// route and TWAP periods in seconds
    /// @return latestAnswer Price from the chained quotes
    /// @return lastUpdated Last updated timestamp
    function price(bytes calldata _data) external view returns (uint256 latestAnswer, uint256 lastUpdated) {
        (address[] memory tokens, address[] memory pools, uint256[] memory twapPeriods) =
            abi.decode(_data, (address[], address[], uint256[]));

        int24[] memory ticks = new int24[](pools.length);
        for (uint i; i < pools.length; i++) {
            (ticks[i],) = UniswapV3OracleLibrary.consult(pools[i], uint32(twapPeriods[i]));
        }

        int256 chainedTick = UniswapV3OracleLibrary.getChainedPrice(tokens, ticks);

        // Do not let the conversion overflow
        if (chainedTick > int256(TickMath.MAX_TICK) || chainedTick < -int256(TickMath.MAX_TICK)) return (0, 0);

        uint256 amountOut =
            UniswapV3OracleLibrary.getQuoteAtTick(int24(chainedTick), 10 ** IERC20Metadata(tokens[0]).decimals());

        (uint256 basePrice, uint256 lastBaseUpdated) = IOracle(msg.sender).getPrice(tokens[0]);
        uint8 decimals = IERC20Metadata(tokens[tokens.length - 1]).decimals();
        amountOut = decimals == 18 ? amountOut : amountOut * 10 ** 18 / 10 ** decimals;
        if (amountOut == 0) return (0, 0);
        latestAnswer = basePrice * 1 ether / amountOut;

        if (latestAnswer != 0) lastUpdated = lastBaseUpdated;
    }

    /// @notice Data validation for new oracle data being added to central oracle
    /// @param _data Encoded addresses of the token route, pool route and TWAP periods
    function validateData(bytes calldata _data) external view {
        (address[] memory tokens, address[] memory pools, uint256[] memory twapPeriods) =
            abi.decode(_data, (address[], address[], uint256[]));

        if (tokens.length != pools.length + 1 || tokens.length != twapPeriods.length + 1) {
            revert ArrayLength();
        }

        (uint256 basePrice,) = IOracle(msg.sender).getPrice(tokens[0]);
        if (basePrice == 0) revert NoBasePrice(tokens[0]);

        uint256 poolLength = pools.length;
        for (uint i; i < poolLength;) {
            address fromToken = tokens[i];
            address toToken = tokens[i + 1];
            address pool = pools[i];
            address token0 = IUniswapV3Pool(pool).token0();
            address token1 = IUniswapV3Pool(pool).token1();

            if (fromToken != token0 && fromToken != token1) {
                revert TokenNotInPair(fromToken, pool);
            }
            if (toToken != token0 && toToken != token1) {
                revert TokenNotInPair(toToken, pool);
            }
            unchecked {
                ++i;
            }
        }
    }
}
