// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Network } from "../Network.sol";
import { IStakerRewards } from "./interfaces/IStakerRewards.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";
import { INetworkRegistry } from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IRegistry } from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

/// @title Cap Symbiotic Network Middleware Contract
/// @author Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing.
contract CapSymbioticNetworkMiddleware is Initializable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Subnetwork for address;
    using Math for uint256;
    using SafeERC20 for IERC20;

    event InstantSlash(address vault, bytes32 subnetwork, uint256 amount);

    error VaultAlreadyRegistred();
    error InvalidDuration();
    error InvalidSlasher();
    error InvalidBurner();
    error InvalidDelegator();
    error NotVault();
    error NoSlasher();
    error NoBurner();
    error VaultNotInitialized();
    error TooBigSlashAmount();
    error DidNotReceiveCollateralImmediatly();
    error InvalidEpochDuration();

    enum SlasherType {
        INSTANT,
        VETO
    }

    enum DelegatorType {
        NETWORK_RESTAKE,
        FULL_RESTAKE,
        OPERATOR_SPECIFIC,
        OPERATOR_NETWORK_SPECIFIC
    }

    address public vaultRegistry;
    address public network;
    mapping(address => EnumerableSet.AddressSet) private vaultsByCollateral;
    uint48 public requiredEpochDuration;

    function initialize(address _network, address _vaultRegistry, uint48 _requiredEpochDuration) external initializer {
        network = _network;
        vaultRegistry = _vaultRegistry;
        requiredEpochDuration = _requiredEpochDuration;
    }

    function subnetworkIdentifier() public pure returns (uint96) {
        return 0;
    }

    function subnetwork() public view returns (bytes32) {
        return network.subnetwork(subnetworkIdentifier());
    }

    function _verifyVault(address vault) internal view {
        if (!IRegistry(vaultRegistry).isEntity(vault)) {
            revert NotVault();
        }

        address collateral = IVault(vault).collateral();

        if (!IVault(vault).isInitialized()) revert VaultNotInitialized();
        if (vaultsByCollateral[collateral].contains(vault)) revert VaultAlreadyRegistred();

        uint48 vaultEpoch = IVault(vault).epochDuration();
        if (vaultEpoch != requiredEpochDuration) revert InvalidEpochDuration();

        address slasher = IVault(vault).slasher();
        uint64 slasherType = IEntity(slasher).TYPE();
        if (slasher == address(0)) revert NoSlasher();
        if (slasherType != uint64(SlasherType.INSTANT)) revert InvalidSlasher();

        address burner = IVault(vault).burner();
        if (burner == address(0)) revert NoBurner();

        address delegator = IVault(vault).delegator();
        uint64 delegatorType = IEntity(delegator).TYPE();
        if (delegatorType != uint64(DelegatorType.NETWORK_RESTAKE)) revert InvalidDelegator();
    }

    function registerVault(address vault) external {
        _verifyVault(vault);
        vaultsByCollateral[IVault(vault).collateral()].add(vault);
    }

    function slashAgent(address _agent, address _collateral, uint256 _amount) external {
        uint48 _timestamp = Time.timestamp() - 1;
        address[] memory _vaults = vaultsByCollateral[_collateral].values();

        uint256 restToSlash = _amount;

        for (uint256 i = 0; i < _vaults.length; i++) {
            IVault vault = IVault(_vaults[i]);

            uint256 toSlash = IBaseDelegator(vault.delegator()).stakeAt(subnetwork(), _agent, _timestamp, "");
            toSlash = restToSlash > toSlash ? toSlash : restToSlash;
            if (toSlash == 0) {
                continue;
            }

            uint256 balanceBefore = IERC20(_collateral).balanceOf(address(this));

            ISlasher(vault.slasher()).slash(subnetwork(), _agent, _amount, _timestamp, new bytes(0));
            // TODO: the burner could be a non routing burner, could add hooks?
            IBurnerRouter(vault.burner()).triggerTransfer(address(this));

            uint256 balanceAfter = IERC20(_collateral).balanceOf(address(this));
            if (balanceAfter - balanceBefore != _amount) {
                revert DidNotReceiveCollateralImmediatly();
            }

            restToSlash -= toSlash;
        }

        if (restToSlash > 0) {
            revert TooBigSlashAmount();
        }
    }
}
