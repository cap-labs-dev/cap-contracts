// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Network } from "../Network.sol";
import { IStakerRewards } from "./interfaces/IStakerRewards.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";

import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";
import { EqualStakePower } from "@symbioticfi/middleware-sdk/src/extensions/managers/stake-powers/EqualStakePower.sol";
import { console } from "forge-std/console.sol";

import { INetworkRegistry } from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IRegistry } from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

import { Subnetworks } from "@symbioticfi/middleware-sdk/src/extensions/Subnetworks.sol";
import { OwnableAccessManager } from
    "@symbioticfi/middleware-sdk/src/extensions/managers/access/OwnableAccessManager.sol";
import { TimestampCapture } from
    "@symbioticfi/middleware-sdk/src/extensions/managers/capture-timestamps/TimestampCapture.sol";
import { KeyManagerAddress } from "@symbioticfi/middleware-sdk/src/extensions/managers/keys/KeyManagerAddress.sol";

import { EqualStakePower } from "@symbioticfi/middleware-sdk/src/extensions/managers/stake-powers/EqualStakePower.sol";
import { Operators } from "@symbioticfi/middleware-sdk/src/extensions/operators/Operators.sol";

/// @title Cap Symbiotic Network Middleware Contract
/// @author Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing.
contract CapSymbioticNetworkMiddleware is
    Operators,
    KeyManagerAddress,
    TimestampCapture,
    EqualStakePower,
    Subnetworks,
    OwnableAccessManager
{
    using Subnetwork for address;
    using Math for uint256;
    using SafeERC20 for IERC20;

    error VaultAlreadyRegistred();
    error InvalidDuration();
    error InvalidSlasher();
    error InvalidBurner();
    error TooBigSlashAmount();

    // TODO: use eip712
    uint48 public requiredEpochDuration;
    address public requiredBurner;

    function initialize(
        address _network,
        address _vaultRegistry,
        address _operatorRegistry,
        address _operatorNetworkOptinService,
        address _owner,
        uint48 _requiredEpochDuration
    ) external initializer {
        uint48 _slashingWindow = 1;
        address _reader = address(0);
        __BaseMiddleware_init(
            _network, _slashingWindow, _vaultRegistry, _operatorRegistry, _operatorNetworkOptinService, _reader
        );
        __OwnableAccessManager_init(_owner);

        requiredEpochDuration = _requiredEpochDuration;
    }

    function getSubnetworkIdentifier(address /*agent?*/ ) public pure returns (uint96) {
        return 0;
    }

    function getSubnetwork(address agent) public view returns (bytes32) {
        address _network = _NETWORK();
        uint96 _subnetworkIdentifier = getSubnetworkIdentifier(agent);
        bytes32 _subnetwork = _network.subnetwork(_subnetworkIdentifier);
        return _subnetwork;
    }

    function _verifyVault(address vault) internal view {
        if (!IRegistry(_VAULT_REGISTRY()).isEntity(vault)) {
            revert NotVault();
        }

        uint48 vaultEpoch = IVault(vault).epochDuration();
        if (vaultEpoch < requiredEpochDuration) revert InvalidDuration();

        address slasher = IVault(vault).slasher();
        if (slasher == address(0) || IEntity(slasher).TYPE() != uint64(SlasherType.INSTANT)) revert InvalidSlasher();
    }

    function registerVault(address vault) external {
        _verifyVault(vault);
        _registerSharedVault(vault);
    }

    function slashAgent(address _agent, uint256 _amount) external {
        bytes32 _subnetwork = getSubnetwork(_agent);
        uint48 _timestamp = getCaptureTimestamp();
        address[] memory _vaults = _activeVaultsAt(_timestamp);

        uint256 amountToSlash = _amount;
        console.log("amountToSlash", amountToSlash);

        console.log("activeVaults.length", _activeVaultsAt(_timestamp).length);

        for (uint256 i = 0; i < _vaults.length; i++) {
            uint256 totalOperatorStake =
                _getOperatorPowerAt(_timestamp, _agent, _vaults[i], getSubnetworkIdentifier(_agent));
            console.log("totalOperatorStake", totalOperatorStake);
            uint256 amountToSlashFromVault = amountToSlash > totalOperatorStake ? totalOperatorStake : amountToSlash;
            amountToSlash -= amountToSlashFromVault;

            if (amountToSlashFromVault > 0) {
                _slashVault(_timestamp, _vaults[i], _subnetwork, _agent, amountToSlashFromVault, new bytes(0));
            }
        }

        if (amountToSlash > 0) {
            revert TooBigSlashAmount();
        }
    }
}
