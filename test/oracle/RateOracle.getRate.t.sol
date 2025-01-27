// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";

contract RateOracleGetRateTest is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
    }

    function test_rate_oracle_get_rate() public {
        uint256 usdtRate = IOracle(env.infra.oracle).marketRate(address(usdt));
        assertEq(usdtRate, 1e17, "USDT borrow rate should be 10%, 1e18 being 100%");
    }
}
