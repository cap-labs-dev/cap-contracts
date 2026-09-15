// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { IOracle } from "../../../../contracts/interfaces/IOracle.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { MockAggregator } from "../../../../test/unit/cap/oracle/MockChainlinkFeeds.sol";

/// @dev Wire the REAL Oracle + ChainlinkAdapter (8-decimal answers) into a market and read what
/// the tranche reports as USD capital. ITranche documents totalCapital as USD 18 decimals.
contract LeadOracleDecimals is CapDeployer {
    Oracle real;
    ChainlinkAdapter adapter;
    MockAggregator feed;

    function setUp() public {
        _deployCap();
        accessManager.grantRole(5, address(this), 0); // REGISTRY
        // real oracle stack
        real = Oracle(_deployProxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (address(accessManager)))));
        adapter = new ChainlinkAdapter();
        feed = new MockAggregator(8, 2000e8, block.timestamp); // ETH = $2000, 8 decimals as on mainnet
        real.setSource(
            address(collateral),
            IOracle.OracleData({
                adapter: address(adapter),
                payload: abi.encodeCall(ChainlinkAdapter.price, (address(feed))),
                staleness: 1 days
            })
        );
        (uint256 p,) = real.price(address(collateral));
        assertEq(p, 2000e8, "real oracle answers in 8 decimals");
    }

    function test_realOracle_trancheCapital_isTenOrdersOfMagnitudeOff() public {
        // redeploy registry-created market against the real oracle by swapping the oracle the
        // tranche reads: simplest is to initialize a tranche directly the way Registry does
        (address marketAddr, address t0,) = _createMarket("m");
        // point this tranche at the real oracle via a fresh tranche instance sharing the beacon
        Tranche t = Tranche(
            beaconFactory.create(
                trancheBeacon,
                abi.encodeCall(
                    Tranche.initialize,
                    (address(accessManager), address(collateral), "T", "T", marketAddr, address(vault), address(real))
                )
            )
        );
        // fund it with 1000 ETH ($2,000,000)
        address lp = makeAddr("lp");
        _fundTranche(address(t), lp, 1000e18);

        uint256 capital = t.totalCapital();
        emit log_named_uint("totalCapital reported", capital);
        emit log_named_uint("expected USD 18-dec  ", 2_000_000e18);
        // ITranche says USD 18 decimals; with the real oracle it is 8-decimal USD
        assertEq(capital, 2_000_000e18, "totalCapital should be $2,000,000 in 18 decimals");
    }
}
