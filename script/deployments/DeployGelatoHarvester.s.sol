// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { CapInterestHarvester } from "../../contracts/gelato/CapInterestHarvester.sol";
import { ICapInterestHarvester } from "../../contracts/interfaces/ICapInterestHarvester.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployGelatoHarvester is Script {
    function run() external {
        address accessControl = address(0x7731129a10d51e18cDE607C5C115F26503D2c683);
        address asset = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        address cusd = address(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
        address feeAuction = address(0xa1a20aBdc873CF291c22Ce3C8968EC06277324D0);
        address feeReceiver = address(0x0036c7b9b62c53F47c804a5643F0c09f864beF0b);
        address harvester = address(0xBF664De63168720b57f1c93581512E9580E3E6f8);
        address lender = address(0x15622c3dbbc5614E6DFa9446603c1779647f01FC);
        address balancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
        address admin = address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52);
        address gelato = address(0xe84E4337c382cC8Ed57c6FB12919270228B6B7A3);
        vm.startBroadcast();

        CapInterestHarvester _harvester = new CapInterestHarvester();
        console.log("CapInterestHarvesterImpl deployed to:", address(_harvester));

        bytes memory data = abi.encodeWithSelector(
            CapInterestHarvester.initialize.selector,
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

        ERC1967Proxy proxy = new ERC1967Proxy(address(_harvester), data);
        console.log("CapInterestHarvesterProxy deployed to:", address(proxy));

        AccessControl(accessControl).grantAccess(ICapInterestHarvester.harvestInterest.selector, address(proxy), gelato);
        AccessControl(accessControl).grantAccess(
            ICapInterestHarvester.receiveFlashLoan.selector, address(proxy), balancerVault
        );
        AccessControl(accessControl).grantAccess(
            ICapInterestHarvester.setExcessReceiver.selector, address(proxy), admin
        );
        AccessControl(accessControl).grantAccess(bytes4(0), address(proxy), admin);

        vm.stopBroadcast();
    }
}
