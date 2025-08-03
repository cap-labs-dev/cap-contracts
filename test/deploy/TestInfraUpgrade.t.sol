// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { Delegation } from "../../contracts/delegation/Delegation.sol";
import { ImplementationsConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";
import { InfraConfig } from "../../contracts/deploy/interfaces/DeployConfigs.sol";

import { FeeAuction } from "../../contracts/feeAuction/FeeAuction.sol";

import { Lender } from "../../contracts/lendingPool/Lender.sol";
import { DebtToken } from "../../contracts/lendingPool/tokens/DebtToken.sol";
import { Oracle } from "../../contracts/oracle/Oracle.sol";
import { CapToken } from "../../contracts/token/CapToken.sol";
import { StakedCap } from "../../contracts/token/StakedCap.sol";
import { TestDeployer } from "../deploy/TestDeployer.sol";

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract TestInfraUpgrade is TestDeployer {
    address user_agent;

    function setUp() public {
        _deployCapTestEnvironment();
        _initTestVaultLiquidity(usdVault);
        _initSymbioticVaultsLiquidity(env, 100);

        user_agent = _getRandomAgent();
    }

    function test_can_upgrade_infra_as_access_control_admin() public {
        // assert initial state
        assertEq(Lender(env.infra.lender).maxBorrowable(user_agent, env.usdMocks[0]), 2000e6);
        // TODO assert more state, ideally one per contract

        // have new implementations
        InfraConfig memory infra = env.infra;
        ImplementationsConfig memory implems1 = env.implems;
        ImplementationsConfig memory implems2 = _deployImplementations();

        // upgrade
        vm.startPrank(env.users.access_control_admin);
        AccessControl(infra.accessControl).upgradeToAndCall(implems2.accessControl, "");
        Lender(infra.lender).upgradeToAndCall(implems2.lender, "");
        Delegation(infra.delegation).upgradeToAndCall(implems2.delegation, "");
        Oracle(infra.oracle).upgradeToAndCall(implems2.oracle, "");
        CapToken(usdVault.capToken).upgradeToAndCall(implems2.capToken, "");
        StakedCap(usdVault.stakedCapToken).upgradeToAndCall(implems2.stakedCap, "");
        DebtToken(usdVault.debtTokens[0]).upgradeToAndCall(implems2.debtToken, "");
        FeeAuction(usdVault.feeAuction).upgradeToAndCall(implems2.feeAuction, "");
        vm.stopPrank();

        // erase previous implementations
        vm.etch(implems1.accessControl, "");
        vm.etch(implems1.lender, "");
        vm.etch(implems1.delegation, "");
        vm.etch(implems1.capToken, "");
        vm.etch(implems1.stakedCap, "");
        vm.etch(implems1.oracle, "");
        vm.etch(implems1.debtToken, "");
        vm.etch(implems1.feeAuction, "");

        // assert new state is unchanged
        assertEq(Lender(env.infra.lender).maxBorrowable(user_agent, env.usdMocks[0]), 2000e6);
        // TODO assert more state, ideally one per contract
    }

    function test_cannot_upgrade_infra_as_non_admin() public {
        address non_admin = makeAddr("non_admin");
        InfraConfig memory infra = env.infra;
        ImplementationsConfig memory implems2 = _deployImplementations();

        vm.startPrank(non_admin);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, non_admin, 0x00)
        );
        AccessControl(infra.accessControl).upgradeToAndCall(implems2.accessControl, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                non_admin,
                accessControl.role(bytes4(0), infra.lender)
            )
        );
        Lender(infra.lender).upgradeToAndCall(implems2.lender, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                non_admin,
                accessControl.role(bytes4(0), infra.delegation)
            )
        );
        Delegation(infra.delegation).upgradeToAndCall(implems2.delegation, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                non_admin,
                accessControl.role(bytes4(0), infra.oracle)
            )
        );
        Oracle(infra.oracle).upgradeToAndCall(implems2.oracle, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                non_admin,
                accessControl.role(bytes4(0), usdVault.capToken)
            )
        );
        CapToken(usdVault.capToken).upgradeToAndCall(implems2.capToken, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                non_admin,
                accessControl.role(bytes4(0), usdVault.stakedCapToken)
            )
        );
        StakedCap(usdVault.stakedCapToken).upgradeToAndCall(implems2.stakedCap, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                non_admin,
                accessControl.role(bytes4(0), usdVault.debtTokens[0])
            )
        );
        DebtToken(usdVault.debtTokens[0]).upgradeToAndCall(implems2.debtToken, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                non_admin,
                accessControl.role(bytes4(0), usdVault.feeAuction)
            )
        );
        FeeAuction(usdVault.feeAuction).upgradeToAndCall(implems2.feeAuction, "");

        vm.stopPrank();
    }
}
