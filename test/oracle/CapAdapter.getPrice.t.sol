// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";

import { VaultConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IStakedCap } from "../../contracts/interfaces/IStakedCap.sol";
import { Lender } from "../../contracts/lendingPool/Lender.sol";

import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";
import { VaultUpgradeable } from "../../contracts/vault/VaultUpgradeable.sol";

import { TestEnvConfig } from "../deploy/interfaces/TestDeployConfig.sol";
import { MockAaveDataProvider } from "../mocks/MockAaveDataProvider.sol";
import { MockChainlinkPriceFeed } from "../mocks/MockChainlinkPriceFeed.sol";
import { MockDelegation } from "../mocks/MockDelegation.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

import { TestDeployer } from "../deploy/TestDeployer.sol";

contract CapAdapterGetPriceTest is Test, TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(env.vault);
    }

    function test_cap_adapter_get_price() public {
        uint256 cUSDPrice = IOracle(env.infra.oracle).getPrice(address(cUSD));
        uint256 scUSDPrice = IOracle(env.infra.oracle).getPrice(address(scUSD));
        assertApproxEqAbs(cUSDPrice, 1e8, 10, "cUSD price should be $1");
        assertApproxEqAbs(scUSDPrice, 1e8, 10, "scUSD price should be $1");
    }
}
