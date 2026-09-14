// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

// Phase-3 adversarial verification of U-2 (offline). Shares the harness in ../U-1/U1_Verify.t.sol.
// Run: FOUNDRY_TEST=audit/v3/tests/scratch/verify/U-2 forge test --match-path 'audit/v3/tests/scratch/verify/U-2/*' -vv
//
// (a) AuthorityUtils.canCallWithDelay against address(0) / an EOA / a contract without canCall: staticcall SUCCEEDS
//     with empty returndata, the pre-zeroed scratch words are read back => (immediate=false, delay=0) => the
//     `restricted` modifier reverts AccessManagedUnauthorized. It never "returns allowed".
// (b) after a bare upgrade nothing rescues: setAuthority from any sender, upgradeToAndCall with any calldata,
//     initialize, a rescue implementation - all revert. Permanent only *after* the bare upgrade.

import { Stablecoin } from "../../../../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../../../../contracts/cap/Wrapper.sol";
import { Migrator, U_VerifyBase } from "../U-1/U1_Verify.t.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AuthorityUtils } from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract AuthorityProbe {
    function probe(address authority) external view returns (bool immediate, uint32 delay, bool staticcallOk) {
        (immediate, delay) = AuthorityUtils.canCallWithDelay(authority, msg.sender, address(this), bytes4(0));
        (staticcallOk,) = authority.staticcall(
            abi.encodeWithSignature("canCall(address,address,bytes4)", msg.sender, address(this), bytes4(0))
        );
    }
}

/// @dev a contract whose fallback returns 32 bytes of 0x01 - what would it take to be "allowed"?
contract TrueFallback {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

contract U2_Verify is U_VerifyBase {
    function test_a_canCallWithDelay_zeroAuthorityIsUnauthorizedNotAllowed() public {
        AuthorityProbe p = new AuthorityProbe();
        (bool imm, uint32 d, bool ok) = p.probe(address(0));
        assertTrue(ok, "staticcall to address(0) succeeds (empty account)");
        assertFalse(imm, "immediate");
        assertEq(d, 0, "delay");
        (imm, d, ok) = p.probe(makeAddr("eoa"));
        assertTrue(ok);
        assertFalse(imm);
        assertEq(d, 0);
        // only a target that actually returns a non-zero first word would be read as allowed, and
        // authority() is fixed at address(0) after the bare upgrade, so this path is unreachable
        (imm,,) = p.probe(address(new TrueFallback()));
        assertTrue(imm, "sanity: a contract answering 1 would be 'allowed'");
    }

    function test_b_nothingRescuesAfterBareUpgrade() public {
        UUPSUpgradeable(cusd).upgradeToAndCall(headStablecoin, "");
        UUPSUpgradeable(stcusd).upgradeToAndCall(headWrapper, "");
        Stablecoin c = Stablecoin(cusd);
        assertEq(c.authority(), address(0));

        // setAuthority: needs msg.sender == address(0)
        address[3] memory senders = [address(this), alice, address(v1ac)];
        for (uint256 i; i < 3; i++) {
            vm.prank(senders[i]);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, senders[i]));
            IAccessManaged(cusd).setAuthority(address(manager));
        }

        // upgrade to anything, with any calldata
        bytes[3] memory datas;
        datas[0] = "";
        datas[1] = abi.encodeCall(
            Stablecoin.initialize, (address(manager), address(usdc), "cap USD", "cUSD", address(irm), address(0))
        );
        datas[2] =
            abi.encodeCall(Migrator.migrateStablecoin, (address(manager), address(usdc), 6, address(irm), address(0)));
        address[2] memory impls = [headStablecoin, migrator];
        for (uint256 i; i < 2; i++) {
            for (uint256 j; j < 3; j++) {
                vm.expectRevert(
                    abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this))
                );
                UUPSUpgradeable(cusd).upgradeToAndCall(impls[i], datas[j]);
            }
        }
        // initialize as a plain call
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        c.initialize(address(manager), address(usdc), "cap USD", "cUSD", address(irm), address(0));

        // every restricted selector on cUSD
        bytes[6] memory calls = [
            abi.encodeCall(c.mintCreditBacked, (alice, 1)),
            abi.encodeCall(c.burnCreditBacked, (alice, 1)),
            abi.encodeCall(c.invest, (1)),
            abi.encodeCall(c.recall, (1)),
            abi.encodeCall(c.setReserveVault, (alice)),
            abi.encodeCall(c.recognizeBadDebtInReserve, (1))
        ];
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = cusd.call(calls[i]);
            assertFalse(ok);
            assertEq(bytes4(ret), IAccessManaged.AccessManagedUnauthorized.selector);
        }

        // stcUSD too
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        UUPSUpgradeable(stcusd).upgradeToAndCall(headWrapper, "");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        IAccessManaged(stcusd).setAuthority(address(manager));
    }

    // Ordering hazard the author flagged in "Likelihood": a non-atomic two-tx plan (plain upgrade then
    // migrate) bricks at tx 1 even if a migrate() entry point exists. The Migrator itself has to be
    // installed while the *v1* implementation still authorises upgrades.
    function test_b_orderMatters_v1GateMustStillBeLiveWhenMigratorLands() public {
        // correct order: v1 -> migrator -> HEAD: works
        _twoStepMigrate();
        assertEq(Stablecoin(cusd).authority(), address(manager));
        assertEq(Wrapper(stcusd).authority(), address(manager));
    }
}
