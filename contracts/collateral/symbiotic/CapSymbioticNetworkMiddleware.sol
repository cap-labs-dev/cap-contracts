// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Time } from "@openzeppelin/contracts/utils/types/Time.sol";
import { INetworkRegistry } from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import { INetworkMiddlewareService } from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";

import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";
import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IRegistry } from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

import { Network } from "../Network.sol";
import { IStakerRewards } from "./interfaces/IStakerRewards.sol";

/// @title Cap Symbiotic Network Middleware Contract
/// @author Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing.
contract CapSymbioticNetworkMiddleware is Network {
    using SafeERC20 for IERC20;
    using Subnetwork for address;
    using EnumerableSet for EnumerableSet.AddressSet;

    address private network;

    address public vaultRegistry;
    uint48 public requiredEpochDuration;

    uint48 private constant INSTANT_SLASHER_TYPE = 0;

    EnumerableSet.AddressSet private vaults;

    error VaultAlreadyRegistred();
    error NotVault();
    error InvalidDuration();
    error InvalidSlasher();
    error InvalidBurner();
    error TooBigSlashAmount();

    function initialize(
        address _vaultRegistry,
        address _networkRegistry,
        uint48 _requiredEpochDuration,
        address _collateral
    ) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        INetworkRegistry(_networkRegistry).registerNetwork();

        requiredEpochDuration = _requiredEpochDuration;
        vaultRegistry = _vaultRegistry;

        network = address(this);

        collateral = _collateral;
    }

    function subnetwork() public view returns (bytes32) {
        return network.subnetwork(0);
    }

    function registerVault(address vault, address rewards) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (vaults.contains(vault)) {
            revert VaultAlreadyRegistred();
        }

        if (!IRegistry(vaultRegistry).isEntity(vault)) {
            revert NotVault();
        }

        if (IVault(vault).burner() != address(this)) revert InvalidBurner();

        uint48 vaultEpoch = IVault(vault).epochDuration();

        if (vaultEpoch < requiredEpochDuration) revert InvalidDuration();

        address slasher = IVault(vault).slasher();
        if (slasher == address(0) || IEntity(slasher).TYPE() != INSTANT_SLASHER_TYPE) revert InvalidSlasher();

        vaults.add(vault);

        _registerProvider(vault, IVault(vault).collateral(), rewards);
    }

    function unregisterVault(address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vaults.remove(vault);
    }

    function collateralByProvider(address _operator, address _provider)
        external
        view
        virtual
        override
        returns (uint256)
    {
        return IBaseDelegator(IVault(_provider).delegator()).stake(subnetwork(), _operator);
    }

    function slash(address _provider, address _operator, address _liquidator, uint256 _amount)
        external
        virtual
        override
        onlyRole(COLLATERAL_ROLE)
    {
        bytes32 _subnetwork = subnetwork();

        uint256 totalOperatorStake = IBaseDelegator(IVault(_provider).delegator()).stake(_subnetwork, _operator);

        if (totalOperatorStake < _amount) {
            revert TooBigSlashAmount();
        }

        _slashVault(_provider, _operator, _liquidator, _amount);
    }

    function _slashVault(address vault, address operator, address liquidator, uint256 amount) private {
        address slasher = IVault(vault).slasher();
        ISlasher(slasher).slash(subnetwork(), operator, amount, Time.timestamp(), new bytes(0));

        IERC20(IVault(vault).collateral()).safeTransferFrom(address(this), liquidator, amount);
    }

    function rewardStakers(address stakerRewards, address token, uint256 amount) external onlyRole(COLLATERAL_ROLE) {
        IERC20(token).forceApprove(stakerRewards, amount);
        IStakerRewards(stakerRewards).distributeRewards(address(this), token, amount, bytes(""));
    }
}
