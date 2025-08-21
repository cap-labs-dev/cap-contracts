// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { ICapChainlinkPoRAddressList } from "../contracts/interfaces/ICapChainlinkPoRAddressList.sol";
import { CapChainlinkPoRAddressList } from "../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract ChainlinkPoRTest is Test {
    CapChainlinkPoRAddressList public chainlinkPoRAddressList;
    address public msig;

    function setUp() public {
        msig = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);
        chainlinkPoRAddressList = CapChainlinkPoRAddressList(0x69A22f0fc7b398e637BF830B862C75dd854b2BbF);
        address newImpl = address(new CapChainlinkPoRAddressList());
        vm.startPrank(msig);
        chainlinkPoRAddressList.upgradeToAndCall(newImpl, "");
        vm.stopPrank();
    }

    function test_call_address_list() public view {
        chainlinkPoRAddressList.getPoRAddressListLength();
        console.log(chainlinkPoRAddressList.getPoRAddressListLength());
        ICapChainlinkPoRAddressList.PoRInfo[] memory infos = chainlinkPoRAddressList.getPoRAddressList(0, 2);
        console.log(infos.length);
        assertEq(infos.length, 2);
        console.log("infos[0].tokenAddress", infos[0].tokenAddress);
        console.log("infos[1].tokenAddress", infos[1].tokenAddress);
        console.log("infos[0].yourVaultAddress", infos[0].yourVaultAddress);
        console.log("infos[1].yourVaultAddress", infos[1].yourVaultAddress);
    }
}
