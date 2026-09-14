// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import { MigrationBase } from "./MigrationBase.sol";

/// @notice The live proxies keep their addresses, books, and permit domain after the upgrade.
contract UpgradeTest is MigrationBase {
    function test_implementationsMovedAndAddressesDidNot() public view {
        assertTrue(_implementation(address(scoin)) != live.cusdImpl, "cUSD implementation moved");
        assertTrue(_implementation(address(wrapper)) != live.wrapperImpl, "stcUSD implementation moved");
        assertEq(_implementation(address(scoin)), implems.stablecoin);
        assertEq(_implementation(address(wrapper)), implems.wrapper);
        assertEq(address(scoin), infra.stablecoin);
        assertEq(address(wrapper), infra.wrapper);
    }

    function test_liveIdentityAndBalancesSurvived() public view {
        assertEq(IERC20Metadata(address(scoin)).name(), liveName);
        assertEq(IERC20Metadata(address(scoin)).symbol(), liveSymbol);
        assertEq(IERC20Metadata(address(wrapper)).name(), liveWrapperName);
        assertEq(IERC20Metadata(address(wrapper)).symbol(), liveWrapperSymbol);
        assertEq(scoin.decimals(), live.cusdDecimals);
        assertEq(wrapper.decimals(), live.wrapperDecimals);

        assertEq(scoin.totalSupply(), live.cusdSupply);
        assertEq(wrapper.totalSupply(), live.stakedSupply);
        assertEq(scoin.balanceOf(address(wrapper)), live.wrapperCusd);
        assertEq(scoin.balanceOf(CUSD_OFT_LOCKBOX), live.lockboxCusd);
        assertEq(wrapper.balanceOf(STCUSD_OFT_LOCKBOX), live.lockboxStaked);
    }

    function test_permitDomainsSurvived() public view {
        assertEq(IERC20Permit(address(scoin)).DOMAIN_SEPARATOR(), live.cusdDomain);
        assertEq(IERC20Permit(address(wrapper)).DOMAIN_SEPARATOR(), live.wrapperDomain);
    }

    function test_newAuthorityIsTheDeployedAccessManager() public view {
        assertEq(IAccessManaged(address(scoin)).authority(), infra.accessManager);
        assertEq(IAccessManaged(address(wrapper)).authority(), infra.accessManager);
        assertEq(scoin.irm(), infra.irm);
        assertEq(scoin.asset(), address(usdc));
        assertEq(wrapper.asset(), address(scoin));
        assertTrue(scoin.optedIn(address(wrapper)), "wrapper earns the new vest");
        assertEq(scoin.creditBackedSupply(), 0, "loans were repaid before the cutover");
        assertEq(scoin.badDebt(), 0);
        assertEq(scoin.backing(), scoin.totalSupply());
        assertEq(scoin.reserveVault(), address(0));
    }

    function test_reinitializeIsClosed() public {
        vm.expectRevert();
        scoin.initialize(infra.accessManager, address(usdc), liveName, liveSymbol, infra.irm, address(0));
        vm.expectRevert();
        wrapper.initialize(infra.accessManager, address(scoin));
    }

    function test_depositRedeemAndPermitWorkOnTheUpgradedTokens() public {
        uint256 depositUsdc = 1_000e6;
        _fundAlice(depositUsdc);

        vm.prank(alice);
        uint256 minted = scoin.deposit(depositUsdc, alice);
        assertEq(minted, 1_000e18);

        vm.prank(alice);
        uint256 withdrawn = scoin.instantRedeem(100e18, alice, alice);
        assertEq(withdrawn, 100e6);
        assertEq(scoin.balanceOf(alice), 900e18);

        vm.prank(alice);
        scoin.approve(address(wrapper), 200e18);
        vm.prank(alice);
        uint256 staked = wrapper.deposit(200e18, alice);
        assertGt(staked, 0);

        vm.prank(alice);
        uint256 unstaked = wrapper.redeem(staked, alice, alice);
        // live stcUSD is already off par; a round trip can lose a couple of wei to 4626 rounding
        assertApproxEqAbs(unstaked, 200e18, 2);

        _assertPermit(alice, 40e18);
    }

    function _assertPermit(address owner, uint256 value) private {
        uint256 ownerKey = 0xA11CE;
        address signer = vm.addr(ownerKey);
        vm.prank(alice);
        scoin.transfer(signer, value);

        address spender = makeAddr("permitSpender");
        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                scoin.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        spender,
                        value,
                        scoin.nonces(signer),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        scoin.permit(signer, spender, value, deadline, v, r, s);

        assertEq(scoin.allowance(signer, spender), value);
        assertEq(scoin.nonces(signer), 1);

        vm.prank(spender);
        scoin.transferFrom(signer, spender, value);
        assertEq(scoin.balanceOf(spender), value);
    }
}
