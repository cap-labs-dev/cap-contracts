// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { CapRoles } from "../../../../test/shared/CapRoles.sol";
import { MockAggregator } from "../../../../test/unit/cap/oracle/MockChainlinkFeeds.sol";

import { Registry } from "../../../../contracts/cap/Registry.sol";
import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { IOracle } from "../../../../contracts/interfaces/IOracle.sol";
import { IRegistry } from "../../../../contracts/interfaces/IRegistry.sol";

/// @notice CapDeployer with the PRODUCTION oracle stack (Oracle proxy + ChainlinkAdapter + a
/// Chainlink-shaped 8-decimal feed) wired into the Registry, instead of the 18-decimal MockOracle
/// every existing test uses. Mirrors `_deployCapWithConfig` step for step; only `_deployRegistry`
/// is replaced so the tranches the registry deploys read the real Oracle.
abstract contract RealOracleDeployer is CapDeployer {
    Oracle internal realOracle;
    ChainlinkAdapter internal adapter;
    MockAggregator internal feed;

    /// @param answer8 The collateral price the feed reports, in Chainlink's 8 decimals
    function _deployCapWithRealOracle(int256 answer8) internal {
        capConfig = _defaultCapConfig();
        capConfig.stablecoinYield = makeAddr("stcUSD");
        defaultMarketOwner = address(this);
        defaultBorrower = makeAddr("borrower");
        defaultLiquidator = makeAddr("liquidator");

        _setUpAccessManager();
        _deployCoreContracts();

        // ── the real oracle stack ────────────────────────────────────────────
        realOracle =
            Oracle(_deployProxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(accessManager)))));
        adapter = new ChainlinkAdapter();
        feed = new MockAggregator(8, answer8, block.timestamp);

        bytes4[] memory oracleSelectors = new bytes4[](3);
        oracleSelectors[0] = Oracle.setSource.selector;
        oracleSelectors[1] = Oracle.setBackup.selector;
        oracleSelectors[2] = Oracle.setChain.selector;
        accessManager.setTargetFunctionRole(address(realOracle), oracleSelectors, CapRoles.ADMIN);

        realOracle.setSource(
            address(collateral),
            IOracle.OracleData({
                adapter: address(adapter),
                payload: abi.encodeCall(ChainlinkAdapter.price, (address(feed))),
                staleness: 1 days
            })
        );

        // ── registry pointed at the real oracle ──────────────────────────────
        registry = Registry(
            _deployProxy(
                address(new Registry()),
                abi.encodeCall(
                    Registry.initialize,
                    (
                        address(accessManager),
                        IRegistry.InitParams({
                            stablecoin: address(stablecoin),
                            stakedStablecoin: capConfig.stablecoinYield,
                            vault: address(vault),
                            oracle: address(realOracle),
                            irm: address(irm),
                            factory: address(beaconFactory),
                            floatingMarketBeacon: floatingMarketBeacon,
                            fixedMarketBeacon: fixedMarketBeacon,
                            trancheBeacon: trancheBeacon,
                            underwriterBeacon: underwriterBeacon,
                            lt: capConfig.defaultLt,
                            buffer: capConfig.defaultBuffer,
                            targetHealth: capConfig.defaultTargetHealth
                        })
                    )
                )
            )
        );

        _configureAccess();
        _assignOperator(defaultMarketOwner);
        _assignOperator(defaultBorrower);
    }
}
