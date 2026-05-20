// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { ProxyUtils } from "../../contracts/deploy/utils/ProxyUtils.sol";
import {
    CapChainlinkPoRAddressList,
    ICapChainlinkPoRAddressList
} from "../../contracts/oracle/chainlink/CapChainlinkPoRAddressList.sol";
import { LenderFixture } from "../fixtures/LenderFixture.sol";

/// @dev Basic integration coverage for the PoR allowlist helper used by the oracle stack.
contract TestPoRAddressList is LenderFixture {
    CapChainlinkPoRAddressList porAddressList;

    function setUp() public {
        _setUpLenderFixture();

        address impl = address(new CapChainlinkPoRAddressList());
        porAddressList = CapChainlinkPoRAddressList(_proxy(impl));

        porAddressList.initialize(env.infra.accessControl, env.usdVault.capToken);

        vm.startPrank(env.users.access_control_admin);
        AccessControl(env.infra.accessControl)
            .grantAccess(
                ICapChainlinkPoRAddressList.addTokenPriceOracle.selector, address(porAddressList), env.users.deployer
            );
        vm.stopPrank();
    }

    function test_getPoRAddressListLength() public view {
        assertEq(porAddressList.getPoRAddressListLength(), 3);
    }

    function test_getPoRAddressList() public view {
        ICapChainlinkPoRAddressList.PoRInfo[] memory addresses = porAddressList.getPoRAddressList(1, 2);
        assertEq(addresses.length, 2);
        for (uint256 i = 0; i < addresses.length; i++) {
            assertTrue(bytes(addresses[i].chain).length > 0);
            assertEq(addresses[i].chainId, block.chainid);
            assertTrue(addresses[i].tokenAddress != address(0));
            // `tokenPriceOracle` is expected to be unset (0) until an admin configures it.
            assertEq(addresses[i].yourVaultAddress, env.usdVault.capToken);
        }
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
