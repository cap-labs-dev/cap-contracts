// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { AccessControl } from "../contracts/access/AccessControl.sol";
import { ICapChainlinkPoRAddressList } from "../contracts/interfaces/ICapChainlinkPoRAddressList.sol";
import { CapChainlinkPoRAddressList } from "../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract ChainlinkPoRTest is Test {
    CapChainlinkPoRAddressList public chainlinkPoRAddressList;
    AccessControl public accessControl;
    address public msig;
    address public yieldAsset;

    function setUp() public {
        msig = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);
        yieldAsset = address(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
        accessControl = AccessControl(0x7731129a10d51e18cDE607C5C115F26503D2c683);
        address usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        chainlinkPoRAddressList = CapChainlinkPoRAddressList(0x69A22f0fc7b398e637BF830B862C75dd854b2BbF);
        address newImpl = address(new CapChainlinkPoRAddressList());
        vm.startPrank(msig);
        chainlinkPoRAddressList.upgradeToAndCall(newImpl, "");
        accessControl.grantAccess(
            ICapChainlinkPoRAddressList.addTokenYieldAsset.selector, address(chainlinkPoRAddressList), msig
        );
        chainlinkPoRAddressList.addTokenYieldAsset(usdc, yieldAsset);
        vm.stopPrank();
    }

    function test_call_address_list() public view {
        chainlinkPoRAddressList.getPoRAddressListLength();
        console.log(chainlinkPoRAddressList.getPoRAddressListLength());
        ICapChainlinkPoRAddressList.PoRInfo[] memory infos = chainlinkPoRAddressList.getPoRAddressList(0, 2);
        console.log(infos.length);
        assertEq(infos.length, 2);
        console.logBytes4(ICapChainlinkPoRAddressList.addTokenYieldAsset.selector);
        console.log("infos[0].tokenAddress", infos[0].tokenAddress);
        console.log("infos[1].tokenAddress", infos[1].tokenAddress);
        console.log("infos[0].yourVaultAddress", infos[0].yourVaultAddress);
        console.log("infos[1].yourVaultAddress", infos[1].yourVaultAddress);
    }
}
