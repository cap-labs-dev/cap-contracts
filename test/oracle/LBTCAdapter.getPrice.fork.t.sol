// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IOracleTypes } from "../../contracts/interfaces/IOracleTypes.sol";
import { IPriceOracle } from "../../contracts/interfaces/IPriceOracle.sol";
import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { LBTCAdapter } from "../../contracts/oracle/libraries/LBTCAdapter.sol";
import { TestHarnessConfig } from "../deploy/interfaces/TestHarnessConfig.sol";
import { OracleFixture } from "../fixtures/OracleFixture.sol";

/// @dev Fork test: verifies LBTCAdapter prices LBTC correctly using real mainnet contracts.
///      Fill in the three address constants below before running.
///
///      Run with:
///        forge test --match-path "test/oracle/LBTCAdapter.getPrice.fork.t.sol" -vv
contract LBTCAdapterGetPriceForkTest is OracleFixture {
    /// @dev Chainlink BTC/USD aggregator on mainnet (8 decimals)
    address constant CHAINLINK_BTC_USD = address(0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);

    /// @dev Lombard staked LBTC ratio oracle (IStakedLBTCOracle) on mainnet
    address constant LBTC_RATIO_ORACLE = address(0x1De9fcfeDF3E51266c188ee422fbA1c7860DA0eF);

    /// @dev LBTC token address on mainnet
    address constant LBTC = address(0x8236a87084f8B84306f72007F36F2618A5634494);

    // -------------------------------------------------------------------------

    /// @dev Fork at the latest block so real oracle data is current.
    function _harnessConfig() internal view override returns (TestHarnessConfig memory config) {
        config = super._harnessConfig();
        config.fork.blockNumber = 24837222;
    }

    function setUp() public {
        require(
            CHAINLINK_BTC_USD != address(0) && LBTC_RATIO_ORACLE != address(0) && LBTC != address(0),
            "Fill in mainnet addresses before running"
        );

        _setUpOracleFixture();

        IOracleTypes.OracleData memory oracleData = IOracleTypes.OracleData({
            adapter: address(LBTCAdapter),
            payload: abi.encodeWithSelector(LBTCAdapter.price.selector, CHAINLINK_BTC_USD, LBTC_RATIO_ORACLE)
        });

        // setStaleness is not granted to oracle_admin by default — add it once.
        _grantAccess(IPriceOracle.setStaleness.selector, env.infra.oracle, env.users.oracle_admin);

        vm.startPrank(env.users.oracle_admin);
        Oracle(env.infra.oracle).setPriceOracleData(LBTC, oracleData);
        Oracle(env.infra.oracle).setPriceBackupOracleData(LBTC, oracleData);
        // Real Chainlink feeds have a non-zero age at the fork block — set generous staleness.
        // postDeployTimeSkip advances block.timestamp ~90 days past the fork; match with generous staleness.
        Oracle(env.infra.oracle).setStaleness(LBTC, 180 days);
        vm.stopPrank();
    }

    function test_lbtc_fork_price_is_nonzero_and_sane() public view {
        (uint256 price, uint256 lastUpdated) = IOracle(env.infra.oracle).getPrice(LBTC);
        assertGt(price, 0, "LBTC price must be non-zero");
        assertGt(lastUpdated, 0, "lastUpdated must be non-zero");
        // LBTC is BTC-backed: price should be in a realistic BTC/USD range ($10k–$500k in 8 dec)
        assertGt(price, 10_000e8, "LBTC price must be above $10k");
        assertLt(price, 500_000e8, "LBTC price must be below $500k");
    }

    function test_lbtc_fork_price_exceeds_raw_btc_feed() public view {
        // LBTC/BTC ratio > 1 (staking rewards have accrued), so LBTC USD price > BTC USD price.
        (uint256 lbtcPrice,) = IOracle(env.infra.oracle).getPrice(LBTC);

        // Read raw BTC/USD directly from the Chainlink feed.
        (, int256 btcAnswer,,,) = IChainlink(CHAINLINK_BTC_USD).latestRoundData();
        uint256 btcPrice = uint256(btcAnswer);

        assertGe(lbtcPrice, btcPrice, "LBTC price must be >= raw BTC price (ratio >= 1)");
    }
}

interface IChainlink {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
