// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import { AccessControl } from "../../access/AccessControl.sol";

import { Delegation } from "../../delegation/Delegation.sol";

import { FeeReceiver } from "../../feeReceiver/FeeReceiver.sol";
import { Lender } from "../../lendingPool/Lender.sol";
import { Oracle } from "../../oracle/Oracle.sol";

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { L2TokenUpgradeable } from "../../token/L2TokenUpgradeable.sol";
import { Vault } from "../../vault/Vault.sol";

import {
    ImplementationsConfig,
    InfraConfig,
    L2VaultConfig,
    PreMainnetInfraConfig,
    UsersConfig,
    VaultConfig
} from "../interfaces/DeployConfigs.sol";
import { LzAddressbook } from "../utils/LzUtils.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

contract DeployInfra is ProxyUtils {
    function _deployInfra(
        ImplementationsConfig memory implementations,
        UsersConfig memory users,
        uint256 _delegationEpochDuration
    ) internal returns (InfraConfig memory d) {
        // deploy proxy contracts
        d.accessControl = _proxy(implementations.accessControl);
        d.lender = _proxy(implementations.lender);
        d.oracle = _proxy(implementations.oracle);
        d.delegation = _proxy(implementations.delegation);

        // init infra instances
        AccessControl(d.accessControl).initialize(users.access_control_admin);
        Lender(d.lender).initialize(d.accessControl, d.delegation, d.oracle, 1.25e27, 1 hours, 1 days, 0.1e27, 0.9e27);
        Oracle(d.oracle).initialize(d.accessControl);
        Delegation(d.delegation).initialize(d.accessControl, d.oracle, _delegationEpochDuration);
    }

    function _deployL2InfraForVault(
        UsersConfig memory users,
        VaultConfig memory l1Vault,
        LzAddressbook memory addressbook
    ) internal returns (L2VaultConfig memory d) {
        address lzEndpoint = address(addressbook.endpointV2);
        string memory name;
        string memory symbol;
        address delegate = users.vault_config_admin;

        name = Vault(l1Vault.capToken).name();
        symbol = Vault(l1Vault.capToken).symbol();
        address l2CapTokenImplementation = address(new L2TokenUpgradeable(lzEndpoint));
        bytes memory capTokenInitData = abi.encodeCall(L2TokenUpgradeable.initialize, (name, symbol, delegate));
        d.bridgedCapToken = address(new ERC1967Proxy(address(l2CapTokenImplementation), capTokenInitData));

        name = Vault(l1Vault.stakedCapToken).name();
        symbol = Vault(l1Vault.stakedCapToken).symbol();
        address l2StakedCapTokenImplementation = address(new L2TokenUpgradeable(lzEndpoint));
        bytes memory stakedCapTokenInitData = abi.encodeCall(L2TokenUpgradeable.initialize, (name, symbol, delegate));
        d.bridgedStakedCapToken =
            address(new ERC1967Proxy(address(l2StakedCapTokenImplementation), stakedCapTokenInitData));
    }
}
