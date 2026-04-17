// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IOracleTypes } from "../../contracts/interfaces/IOracleTypes.sol";
import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { FalconXUSDCAdapter } from "../../contracts/oracle/libraries/FalconXUSDCAdapter.sol";
import { TestHarnessConfig } from "../deploy/interfaces/TestHarnessConfig.sol";
import { OracleFixture } from "../fixtures/OracleFixture.sol";
import { console } from "forge-std/console.sol";

/// @dev Fork test: verifies FalconXUSDCAdapter prices correctly using real mainnet contracts.
///
///      Run with:
///        forge test --match-path "test/oracle/FalconXUSDCAdapter.getPrice.fork.t.sol" -vv
contract FalconXUSDCAdapterGetPriceForkTest is OracleFixture {
    /// @dev FalconX USDC aggregator on mainnet
    address constant FALCONX_SOURCE = 0x50449B3D1f5931d568A1951Ee506A9534e7f7dFf;

    /// @dev Placeholder asset address used to register the oracle data
    address constant ASSET = address(0xFafafAfafAFaFAFaFafafafAfaFaFAfAfAfAFaFA);

    /// @dev Fork at latest so real oracle data is current.
    function _harnessConfig() internal view override returns (TestHarnessConfig memory config) {
        config = super._harnessConfig();
        config.fork.blockNumber = 0;
    }

    function setUp() public {
        _setUpOracleFixture();

        IOracleTypes.OracleData memory oracleData = IOracleTypes.OracleData({
            adapter: address(FalconXUSDCAdapter),
            payload: abi.encodeWithSelector(FalconXUSDCAdapter.price.selector, FALCONX_SOURCE)
        });

        vm.startPrank(env.users.oracle_admin);
        Oracle(env.infra.oracle).setPriceOracleData(ASSET, oracleData);
        Oracle(env.infra.oracle).setPriceBackupOracleData(ASSET, oracleData);
        // No staleness configuration needed: FalconXUSDCAdapter always returns block.timestamp.
        vm.stopPrank();
    }

    /// @dev Price must be non-zero and have a valid timestamp.
    function test_falconx_usdc_fork_price_is_nonzero() public view {
        (uint256 price, uint256 lastUpdated) = IOracle(env.infra.oracle).getPrice(ASSET);
        console.log("price (8 dec):", price);
        console.log("lastUpdated:  ", lastUpdated);

        assertGt(price, 0, "price must be non-zero");
        assertGt(lastUpdated, 0, "lastUpdated must be non-zero");
    }

    /// @dev Calls the adapter directly and confirms lastUpdated equals block.timestamp.
    function test_falconx_usdc_last_updated_is_block_timestamp() public view {
        (, uint256 lastUpdated) = FalconXUSDCAdapter.price(FALCONX_SOURCE);
        assertEq(lastUpdated, block.timestamp, "lastUpdated must equal block.timestamp");
    }
}
