// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.22;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { CapInterestHarvester } from "../../contracts/gelato/CapInterestHarvester.sol";
import { ICapInterestHarvester } from "../../contracts/interfaces/ICapInterestHarvester.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";

contract HarvesterTest is Test {
    CapInterestHarvester public impl;
    ERC1967Proxy public proxy;
    address public accessControl = address(0x7731129a10d51e18cDE607C5C115F26503D2c683);
    address public asset = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address public cusd = address(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
    address public feeAuction = address(0xa1a20aBdc873CF291c22Ce3C8968EC06277324D0);
    address public feeReceiver = address(0x0036c7b9b62c53F47c804a5643F0c09f864beF0b);
    address public harvester = address(0xBF664De63168720b57f1c93581512E9580E3E6f8);
    address public lender = address(0x15622c3dbbc5614E6DFa9446603c1779647f01FC);
    address public balancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address public admin = address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52);
    address public gelato = address(0xe84E4337c382cC8Ed57c6FB12919270228B6B7A3);

    function setUp() public {
        impl = new CapInterestHarvester();

        bytes memory data = abi.encodeWithSelector(
            ICapInterestHarvester.initialize.selector,
            accessControl,
            asset,
            cusd,
            feeAuction,
            feeReceiver,
            harvester,
            lender,
            balancerVault,
            admin
        );
        proxy = new ERC1967Proxy(address(impl), data);

        vm.prank(admin);
        AccessControl(accessControl).grantAccess(ICapInterestHarvester.harvestInterest.selector, address(proxy), gelato);
        vm.stopPrank();

        vm.prank(admin);
        AccessControl(accessControl).grantAccess(
            ICapInterestHarvester.receiveFlashLoan.selector, address(proxy), balancerVault
        );
        vm.stopPrank();
    }

    function test_gelatoHarvest() public {
        (bool canExec,) = CapInterestHarvester(address(proxy)).checker();
        console.log("canExec", canExec);

        vm.prank(gelato);
        if (canExec) ICapInterestHarvester(address(proxy)).harvestInterest();
        vm.stopPrank();
    }
}
