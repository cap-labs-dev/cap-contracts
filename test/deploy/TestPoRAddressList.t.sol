// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { CapChainlinkPoRAddressList } from "../../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";
import { TestDeployer } from "./TestDeployer.sol";
import { console } from "forge-std/console.sol";

contract TestPoRAddressList is TestDeployer {
    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env, 100);
    }

    function test_getPoRAddressListLength() public {
        CapChainlinkPoRAddressList porAddressList = new CapChainlinkPoRAddressList(env.usdVault.capToken);
        assertEq(porAddressList.getPoRAddressListLength(), 3);
    }

    function test_getPoRAddressList() public {
        CapChainlinkPoRAddressList porAddressList = new CapChainlinkPoRAddressList(env.usdVault.capToken);
        assertEq(porAddressList.getPoRAddressListLength(), 3);
        string[] memory addresses = porAddressList.getPoRAddressList(0, 2);
        console.log(addresses[0]);
        console.log(addresses[1]);
        console.log(addresses[2]);
    }
}
