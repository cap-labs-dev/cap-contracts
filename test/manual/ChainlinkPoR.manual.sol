// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { ICapChainlinkPoRAddressList } from "../../contracts/interfaces/ICapChainlinkPoRAddressList.sol";
import { CapChainlinkPoRAddressList } from "../../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";

import { Test } from "forge-std/Test.sol";

/// @dev Manual mainnet-fork playground for upgrading and mutating a live `CapChainlinkPoRAddressList`.
/// Intentionally contains no `test*` functions so it never runs in CI.
contract ChainlinkPoRManual is Test {
    CapChainlinkPoRAddressList public chainlinkPoRAddressList;
    AccessControl public accessControl;
    address public msig;
    address public yieldAsset;

    function setUp() public {
        // These are mainnet addresses; requires `--fork-url` to run.
        msig = address(0xb8FC49402dF3ee4f8587268FB89fda4d621a8793);
        yieldAsset = address(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
        accessControl = AccessControl(0x7731129a10d51e18cDE607C5C115F26503D2c683);
        address usdc = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        chainlinkPoRAddressList = CapChainlinkPoRAddressList(0x69A22f0fc7b398e637BF830B862C75dd854b2BbF);

        // Example flow: upgrade + grant + set yield asset.
        address newImpl = address(new CapChainlinkPoRAddressList());
        vm.startPrank(msig);
        chainlinkPoRAddressList.upgradeToAndCall(newImpl, "");
        accessControl.grantAccess(
            ICapChainlinkPoRAddressList.addTokenYieldAsset.selector, address(chainlinkPoRAddressList), msig
        );
        chainlinkPoRAddressList.addTokenYieldAsset(usdc, yieldAsset);
        vm.stopPrank();
    }

    function manual_call_address_list() public view {
        chainlinkPoRAddressList.getPoRAddressListLength();
        chainlinkPoRAddressList.getPoRAddressList(0, 2);
    }
}

