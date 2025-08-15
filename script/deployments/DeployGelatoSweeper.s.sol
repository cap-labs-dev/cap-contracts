// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { CapSweeper } from "../../contracts/gelato/CapSweeper.sol";
import { ICapSweeper } from "../../contracts/interfaces/ICapSweeper.sol";
import { IFractionalReserve } from "../../contracts/interfaces/IFractionalReserve.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployGelatoSweeper is Script {
    function run() external {
        address accessControl = address(0x7731129a10d51e18cDE607C5C115F26503D2c683);
        address cusd = address(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
        address admin = address(0xc1ab5a9593E6e1662A9a44F84Df4F31Fc8A76B52);
        address gelato = address(0xe84E4337c382cC8Ed57c6FB12919270228B6B7A3);
        uint256 sweepInterval = 6 hours;
        uint256 minSweepAmount = 1e18;
        vm.startBroadcast();

        CapSweeper _sweeper = new CapSweeper();
        console.log("CapSweeperImpl deployed to:", address(_sweeper));

        bytes memory data =
            abi.encodeWithSelector(CapSweeper.initialize.selector, accessControl, cusd, sweepInterval, minSweepAmount);

        ERC1967Proxy proxy = new ERC1967Proxy(address(_sweeper), data);
        console.log("CapSweeperProxy deployed to:", address(proxy));

        AccessControl(accessControl).grantAccess(ICapSweeper.sweep.selector, address(proxy), gelato);
        AccessControl(accessControl).grantAccess(IFractionalReserve.investAll.selector, address(cusd), address(proxy));
        AccessControl(accessControl).grantAccess(ICapSweeper.setSweepInterval.selector, address(proxy), admin);
        AccessControl(accessControl).grantAccess(ICapSweeper.setMinSweepAmount.selector, address(proxy), admin);
        AccessControl(accessControl).grantAccess(bytes4(0), address(proxy), admin);

        vm.stopBroadcast();
    }
}
