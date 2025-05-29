// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import { BeforeAfter } from "../BeforeAfter.sol";
import { Properties } from "../Properties.sol";
import { BaseTargetFunctions } from "@chimera/BaseTargetFunctions.sol";
// Chimera deps
import { vm } from "@chimera/Hevm.sol";

// Helpers
import { Panic } from "@recon/Panic.sol";

import "contracts/oracle/Oracle.sol";

abstract contract OracleTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///

    function oracle_marketRate(address _asset) public asActor {
        oracle.marketRate(_asset);
    }

    function oracle_setBenchmarkRate(address _asset, uint256 _rate) public asActor {
        oracle.setBenchmarkRate(_asset, _rate);
    }

    function oracle_setMarketOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
        oracle.setMarketOracleData(_asset, _oracleData);
    }

    function oracle_setPriceBackupOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
        oracle.setPriceBackupOracleData(_asset, _oracleData);
    }

    function oracle_setPriceOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
        oracle.setPriceOracleData(_asset, _oracleData);
    }

    function oracle_setRestakerRate(address _agent, uint256 _rate) public asActor {
        oracle.setRestakerRate(_agent, _rate);
    }

    function oracle_setStaleness(address _asset, uint256 _staleness) public asActor {
        oracle.setStaleness(_asset, _staleness);
    }

    function oracle_setUtilizationOracleData(address _asset, IOracle.OracleData memory _oracleData) public asActor {
        oracle.setUtilizationOracleData(_asset, _oracleData);
    }

    function oracle_utilizationRate(address _asset) public asActor {
        oracle.utilizationRate(_asset);
    }
}
