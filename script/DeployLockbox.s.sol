// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { OFTLockboxUpgradeable } from "../contracts/token/OFTLockboxUpgradeable.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

contract DeployLockbox is Script {
    function run() external {
        vm.startBroadcast();

        // cap msig
        address delegate = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);

        // cUSD
        address cusd = address(0xcCcc62962d17b8914c62D74FfB843d73B2a3cccC);
        // stcUSD
        address stcusd = address(0x88887bE419578051FF9F4eb6C858A951921D8888);

        // LayerZero Mainnet Endpoint V2
        address endpoint = address(0x1a44076050125825900e736c501f859c50fE728c);
        address cUSDImplementation = address(new OFTLockboxUpgradeable(cusd, endpoint));
        address stcUSDImplementation = address(new OFTLockboxUpgradeable(stcusd, endpoint));
        console.log("cUSD Implementation Deployed at", cUSDImplementation);
        console.log("stcUSD Implementation Deployed at", stcUSDImplementation);

        // First, encode the initialize function call with all parameters
        bytes memory initializeCalldata = abi.encodeWithSignature("initialize(address)", delegate);

        address lockBoxCapUSD = address(new ERC1967Proxy(cUSDImplementation, initializeCalldata));
        address lockBoxStakedCapUSD = address(new ERC1967Proxy(stcUSDImplementation, initializeCalldata));

        console.log("Lockbox Cap USD deployed at", lockBoxCapUSD);
        console.log("Lockbox Staked Cap USD deployed at", lockBoxStakedCapUSD);

        vm.stopBroadcast();
    }
}
