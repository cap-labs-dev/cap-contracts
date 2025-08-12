// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import {
    CapChainlinkPoRAddressList,
    ICapChainlinkPoRAddressList
} from "../../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";
import { TestDeployer } from "./TestDeployer.sol";
import { console } from "forge-std/console.sol";

contract TestPoRAddressList is TestDeployer {
    CapChainlinkPoRAddressList porAddressList;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env, 100);

        address impl = address(new CapChainlinkPoRAddressList());
        porAddressList = CapChainlinkPoRAddressList(_proxy(impl));

        porAddressList.initialize(env.infra.accessControl, env.usdVault.capToken);

        vm.startPrank(env.users.access_control_admin);
        AccessControl(env.infra.accessControl).grantAccess(
            ICapChainlinkPoRAddressList.addTokenPriceOracle.selector, address(porAddressList), env.users.deployer
        );
        vm.stopPrank();
    }

    function test_getPoRAddressListLength() public {
        assertEq(porAddressList.getPoRAddressListLength(), 3);
    }

    function test_getPoRAddressList() public {
        assertEq(porAddressList.getPoRAddressListLength(), 3);
        ICapChainlinkPoRAddressList.PoRInfo[] memory addresses = porAddressList.getPoRAddressList(1, 2);
        console.log(addresses[0].chain);
        console.log(addresses[0].chainId);
        console.log(addresses[0].tokenSymbol);
        console.log(addresses[0].tokenAddress);
        console.log(addresses[0].tokenDecimals);
        console.log(addresses[0].tokenPriceOracle);
        console.log(addresses[0].yourVaultAddress);
    }

    function test_addTokenPriceOracle() public {
        /// create random address
        address randomAddress = address(uint160(uint256(keccak256("random"))));
        vm.startPrank(env.users.deployer);
        porAddressList.addTokenPriceOracle(env.usdVault.assets[1], randomAddress);
        vm.stopPrank();
        ICapChainlinkPoRAddressList.PoRInfo[] memory addresses = porAddressList.getPoRAddressList(1, 2);
        assertEq(addresses[0].tokenPriceOracle, randomAddress);
    }
}
