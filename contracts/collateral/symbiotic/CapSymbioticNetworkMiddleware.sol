// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

import {INetworkRegistry} from "@symbioticfi/core/src/interfaces/INetworkRegistry.sol";
import {INetworkMiddlewareService} from "@symbioticfi/core/src/interfaces/service/INetworkMiddlewareService.sol";
import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {IRegistry} from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import {IEntity} from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import {IVault} from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import {IBaseDelegator} from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import {IBaseSlasher} from "@symbioticfi/core/src/interfaces/slasher/IBaseSlasher.sol";
import {IOptInService} from "@symbioticfi/core/src/interfaces/service/IOptInService.sol";
import {IEntity} from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import {ISlasher} from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "@symbioticfi/core/src/interfaces/slasher/IVetoSlasher.sol";
import {Subnetwork} from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";

import {SimpleKeyRegistry32} from "./SimpleKeyRegistry32.sol";
import {MapWithTimeData} from "./libraries/MapWithTimeData.sol";
import {Errors} from "./Errors.sol";
import {Network} from "../Network.sol";

/// @title Cap Symbiotic Network Middleware Contract
/// @author Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing.
contract CapSymbioticNetworkMiddleware is 
    Network,
    SimpleKeyRegistry32,
    Errors,
    AccessControlEnumerableUpgradeable, 
    UUPSUpgradeable
{
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;
    using Subnetwork for address;

    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    struct ValidatorData {
        uint256 stake;
        bytes32 key;
    }

    address public network;
    address public operatorRegistry;
    address public vaultRegistry;
    address public operatorNetOptIn;
    uint48 public epochDuration;
    uint48 public slashingWindow;
    uint48 public startTime;

    uint48 private constant INSTANT_SLASHER_TYPE = 0;
    uint48 private constant VETO_SLASHER_TYPE = 1;

    uint256 public subnetworksCnt;
    mapping(uint48 => uint256) public totalStakeCache;
    mapping(uint48 => bool) public totalStakeCached;
    mapping(uint48 => mapping(address => uint256)) public operatorStakeCache;
    EnumerableMap.AddressToUintMap private operators;
    EnumerableMap.AddressToUintMap private vaults;

    modifier updateStakeCache(uint48 epoch) {
        if (!totalStakeCached[epoch]) {
            calcAndCacheStakes(epoch);
        }
        _;
    }

    function initialize(
        address _network,
        address _operatorRegistry,
        address _vaultRegistry,
        address _operatorNetOptin,
        address _pauser,
        uint48 _epochDuration,
        uint48 _slashingWindow
    ) initializer external {

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OWNER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, _pauser);

        if (_slashingWindow < _epochDuration) {
            revert SlashingWindowTooShort();
        }
        
        startTime = Time.timestamp();
        epochDuration = _epochDuration;
        network = _network;
        operatorRegistry = _operatorRegistry;
        vaultRegistry = _vaultRegistry;
        operatorNetOptIn = _operatorNetOptin;
        slashingWindow = _slashingWindow;

        subnetworksCnt = 1;
    }

    function getEpochStartTs(uint48 epoch) public view returns (uint48 timestamp) {
        return startTime + epoch * epochDuration;
    }

    function getEpochAtTs(uint48 timestamp) public view returns (uint48 epoch) {
        return (timestamp - startTime) / epochDuration;
    }

    function getCurrentEpoch() public view returns (uint48 epoch) {
        return getEpochAtTs(Time.timestamp());
    }

    function registerOperator(address operator, bytes32 key) external onlyRole(OWNER_ROLE) {
        if (operators.contains(operator)) {
            revert OperatorAlreadyRegistred();
        }

        if (!IRegistry(operatorRegistry).isEntity(operator)) {
            revert NotOperator();
        }

        if (!IOptInService(operatorNetOptIn).isOptedIn(operator, network)) {
            revert OperatorNotOptedIn();
        }

        updateKey(operator, key);

        operators.add(operator);
        operators.enable(operator);
    }

    function updateOperatorKey(address operator, bytes32 key) external onlyRole(OWNER_ROLE) {
        if (!operators.contains(operator)) {
            revert OperatorNotRegistred();
        }

        updateKey(operator, key);
    }

    function pauseOperator(address operator) external onlyRole(PAUSER_ROLE) {
        operators.disable(operator);
    }

    function unpauseOperator(address operator) external onlyRole(OWNER_ROLE) {
        operators.enable(operator);
    }

    function unregisterOperator(address operator) external onlyRole(OWNER_ROLE) {
        (, uint48 disabledTime) = operators.getTimes(operator);

        if (disabledTime == 0 || disabledTime + slashingWindow > Time.timestamp()) {
            revert OperarorGracePeriodNotPassed();
        }

        operators.remove(operator);
    }

    function registerVault(address vault) external onlyRole(OWNER_ROLE) {
        if (vaults.contains(vault)) {
            revert VaultAlreadyRegistred();
        }

        if (!IRegistry(vaultRegistry).isEntity(vault)) {
            revert NotVault();
        }

        uint48 vaultEpoch = IVault(vault).epochDuration();

        address slasher = IVault(vault).slasher();
        if (slasher != address(0) && IEntity(slasher).TYPE() == VETO_SLASHER_TYPE) {
            vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
        }

        if (vaultEpoch < slashingWindow) {
            revert VaultEpochTooShort();
        }

        vaults.add(vault);
        vaults.enable(vault);
    }

    function pauseVault(address vault) external onlyRole(PAUSER_ROLE) {
        vaults.disable(vault);
    }

    function unpauseVault(address vault) external onlyRole(OWNER_ROLE) {
        vaults.enable(vault);
    }

    function unregisterVault(address vault) external onlyRole(OWNER_ROLE) {
        (, uint48 disabledTime) = vaults.getTimes(vault);

        if (disabledTime == 0 || disabledTime + slashingWindow > Time.timestamp()) {
            revert VaultGracePeriodNotPassed();
        }

        vaults.remove(vault);
    }

    function setSubnetworksCnt(uint256 _subnetworksCnt) external onlyRole(OWNER_ROLE) {
        if (subnetworksCnt >= _subnetworksCnt) {
            revert InvalidSubnetworksCnt();
        }

        subnetworksCnt = _subnetworksCnt;
    }

    function getOperatorStake(address operator, uint48 epoch) public view returns (uint256 stake) {
        if (totalStakeCached[epoch]) {
            return operatorStakeCache[epoch][operator];
        }

        uint48 epochStartTs = getEpochStartTs(epoch);

        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = vaults.atWithTimes(i);

            // just skip the vault if it was enabled after the target epoch or not enabled
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            for (uint96 j = 0; j < subnetworksCnt; ++j) {
                stake += IBaseDelegator(IVault(vault).delegator()).stakeAt(
                    network.subnetwork(j), operator, epochStartTs, new bytes(0)
                );
            }
        }

        return stake;
    }

    function getTotalStake(uint48 epoch) public view returns (uint256) {
        if (totalStakeCached[epoch]) {
            return totalStakeCache[epoch];
        }
        return _calcTotalStake(epoch);
    }

    function getValidatorSet(uint48 epoch) public view returns (ValidatorData[] memory validatorsData) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        validatorsData = new ValidatorData[](operators.length());
        uint256 valIdx = 0;

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            bytes32 key = getOperatorKeyAt(operator, epochStartTs);
            if (key == bytes32(0)) {
                continue;
            }

            uint256 stake = getOperatorStake(operator, epoch);

            validatorsData[valIdx++] = ValidatorData(stake, key);
        }

        // shrink array to skip unused slots
        /// @solidity memory-safe-assembly
        assembly {
            mstore(validatorsData, valIdx)
        }
    }

    function submission(bytes memory payload, bytes32[] memory signatures) public updateStakeCache(getCurrentEpoch()) {
        // validate signatures
        // validate payload
        // process payload
    }

    // just for example, our devnets don't support slashing
    function slash(uint48 epoch, address operator, uint256 amount) public onlyRole(OWNER_ROLE) updateStakeCache(epoch) {
       /* uint48 epochStartTs = getEpochStartTs(epoch);

        if (epochStartTs < Time.timestamp() - slashingWindow) {
            revert TooOldEpoch();
        }

        uint256 totalOperatorStake = getOperatorStake(operator, epoch);

        if (totalOperatorStake < amount) {
            revert TooBigSlashAmount();
        }

        // simple pro-rata slasher
        for (uint256 i; i < vaults.length(); ++i) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip the vault if it was enabled after the target epoch or not enabled
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            for (uint96 j = 0; j < subnetworksCnt; ++j) {
                bytes32 subnetwork = network.subnetwork(j);
                uint256 vaultStake =
                    IBaseDelegator(IVault(vault).delegator()).stakeAt(subnetwork, operator, epochStartTs, new bytes(0));

                _slashVault(epochStartTs, vault, subnetwork, operator, amount * vaultStake / totalOperatorStake);
            }
        }*/
    }

    function calcAndCacheStakes(uint48 epoch) public returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // for epoch older than SLASHING_WINDOW total stake can be invalidated (use cache)
        if (epochStartTs < Time.timestamp() - slashingWindow) {
            revert TooOldEpoch();
        }

        if (epochStartTs > Time.timestamp()) {
            revert InvalidEpoch();
        }

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            uint256 operatorStake = getOperatorStake(operator, epoch);
            operatorStakeCache[epoch][operator] = operatorStake;

            totalStake += operatorStake;
        }

        totalStakeCached[epoch] = true;
        totalStakeCache[epoch] = totalStake;
    }

    function _calcTotalStake(uint48 epoch) private view returns (uint256 totalStake) {
        uint48 epochStartTs = getEpochStartTs(epoch);

        // for epoch older than SLASHING_WINDOW total stake can be invalidated (use cache)
        if (epochStartTs < Time.timestamp() - slashingWindow) {
            revert TooOldEpoch();
        }

        if (epochStartTs > Time.timestamp()) {
            revert InvalidEpoch();
        }

        for (uint256 i; i < operators.length(); ++i) {
            (address operator, uint48 enabledTime, uint48 disabledTime) = operators.atWithTimes(i);

            // just skip operator if it was added after the target epoch or paused
            if (!_wasActiveAt(enabledTime, disabledTime, epochStartTs)) {
                continue;
            }

            uint256 operatorStake = getOperatorStake(operator, epoch);
            totalStake += operatorStake;
        }
    }

    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime >= timestamp);
    }

    function _slashVault(
        uint48 timestamp,
        address vault,
        bytes32 subnetwork,
        address operator,
        uint256 amount
    ) private {
       /* address slasher = IVault(vault).slasher();
        uint256 slasherType = IEntity(slasher).TYPE();
        if (slasherType == INSTANT_SLASHER_TYPE) {
            ISlasher(slasher).slash(subnetwork, operator, amount, timestamp, new bytes(0));
        } else if (slasherType == VETO_SLASHER_TYPE) {
            IVetoSlasher(slasher).requestSlash(subnetwork, operator, amount, timestamp, new bytes(0));
        } else {
            revert UnknownSlasherType();
        }*/
    }

    function _authorizeUpgrade(address) internal override onlyRole(OWNER_ROLE) {}
}