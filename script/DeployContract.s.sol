// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { CapChainlinkPoRAddressList } from "../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployContract is Script {
    function run() external {
        address accessControl = 0x7731129a10d51e18cDE607C5C115F26503D2c683;
        address capToken = 0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC;
        vm.startBroadcast();
        CapChainlinkPoRAddressList porAddressList = new CapChainlinkPoRAddressList();
        console.log("CapChainlinkPoRAddressListImpl deployed to:", address(porAddressList));

        bytes memory data = abi.encodeWithSelector(porAddressList.initialize.selector, accessControl, capToken);

        ERC1967Proxy proxy = new ERC1967Proxy(address(porAddressList), data);
        console.log("CapChainlinkPoRAddressListProxy deployed to:", address(proxy));
        /* address vaultConfigurator = 0x29300b1d3150B4E2b12fE80BE72f365E200441EC;
        address burnerRouterFactory = 0x99F2B89fB3C363fBafD8d826E5AA77b28bAB70a0;
        address defaultStakerRewardsFactory = 0xFEB871581C2ab2e1EEe6f7dDC7e6246cFa087A23;
        address middleware = 0x8C9140Fe6650E56A0A07E86455D745f8F7843B6D;
        CapSymbioticVaultFactory factory = new CapSymbioticVaultFactory(
            vaultConfigurator, burnerRouterFactory, defaultStakerRewardsFactory, middleware
        );
        console.log("CapSymbioticVaultFactory deployed to:", address(factory));*/
        vm.stopBroadcast();
    }
}
