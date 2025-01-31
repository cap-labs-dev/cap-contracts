// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessUpgradeable } from "../../../access/AccessUpgradeable.sol";
import { IOracle } from "../../../interfaces/IOracle.sol";
import { IStakerRewards } from "./interfaces/IStakerRewards.sol";
import { NetworkMiddlewareStorage } from "./libraries/NetworkMiddlewareStorage.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";

import { INetwork } from "../../../delegation/interfaces/INetwork.sol";

import { IMiddleware } from "./interfaces/IMiddleware.sol";
import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";
import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IRegistry } from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

/// @title Cap Symbiotic Network Middleware Contract
/// @author Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing.
contract NetworkMiddleware is UUPSUpgradeable, AccessUpgradeable, INetwork, IMiddleware {
    using SafeERC20 for IERC20;

    /// @dev Vault registered
    event VaultRegistered(address vault);
    /// @dev Slash event
    event Slash(address indexed agent, address recipient, uint256 amount);

    struct SymbioticSlashHint {
        uint48 slashTimestamp;
    }

    /// @dev Invalid slasher
    error InvalidSlasher();
    /// @dev Invalid delegator
    error InvalidDelegator();
    /// @dev Not a vault
    error NotVault();
    /// @dev No slasher
    error NoSlasher();
    /// @dev No burner
    error NoBurner();
    /// @dev No staker rewarder
    error NoStakerRewarder();
    /// @dev Vault not initialized
    error VaultNotInitialized();
    /// @dev Invalid epoch duration
    error InvalidEpochDuration(uint48 required, uint48 actual);
    /// @dev Invalid slash duration
    error InvalidSlashDuration();
    /// @dev No slashable collateral
    error NoSlashableCollateral();

    /// @notice Initialize
    /// @param _accessControl Access control address
    /// @param _network Network address
    /// @param _vaultRegistry Vault registry address
    /// @param _oracle Oracle address
    /// @param _requiredEpochDuration Required epoch duration in seconds
    /// @param _slashDuration amount of time we have to liquidate collateral in a slash event, needs to be < epochDuration
    function initialize(
        address _accessControl,
        address _network,
        address _vaultRegistry,
        address _oracle,
        uint48 _requiredEpochDuration,
        uint48 _slashDuration
    ) external initializer {
        __Access_init(_accessControl);
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        $.network = _network;
        $.vaultRegistry = _vaultRegistry;
        $.oracle = _oracle;
        $.requiredEpochDuration = _requiredEpochDuration;
        $.slashDuration = _slashDuration;

        if (_slashDuration >= _requiredEpochDuration) revert InvalidSlashDuration();
    }

    /// @notice Register vault to be used as collateral within the CAP system
    /// @param _vault Vault address
    /// @param _agents Agents supported by the vault
    function registerVault(address _vault, address _stakerRewarder, address[] calldata _agents)
        external
        checkAccess(this.registerVault.selector)
    {
        _verifyVault(_vault);
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        $.stakerRewarders[_vault] = _stakerRewarder;
        for (uint256 i; i < _agents.length; ++i) {
            $.vaults[_agents[i]].push(_vault);
        }
        emit VaultRegistered(_vault);
    }

    /// @notice Slash delegation and send to recipient
    /// @param _agent Agent address
    /// @param _recipient Recipient of the slashed assets
    /// @param _slashShare Percentage of delegation to slashn encoded with 18 decimals
    /// @param _slashHints Slash hint specific to symbiotic
    function slash(address _agent, address _recipient, uint256 _slashShare, bytes memory _slashHints)
        external
        checkAccess(this.slash.selector)
    {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        SymbioticSlashHint memory slashHint = abi.decode(_slashHints, (SymbioticSlashHint));

        uint48 _timestamp = timestamp();
        for (uint256 i; i < $.vaults[_agent].length; ++i) {
            IVault vault = IVault($.vaults[_agent][i]);
            (, uint256 delegatedCollateral) = coverageByVault(_agent, address(vault), $.oracle, _timestamp);
            if (delegatedCollateral == 0) continue;

            uint256 slashShareOfCollateral = delegatedCollateral * _slashShare / 1e18;
            uint48 slashTimestamp = slashHint.slashTimestamp;
            if (slashTimestamp == 0) slashTimestamp = _timestamp - IVault(vault).epochDuration();

            ISlasher(vault.slasher()).slash(
                subnetwork(_agent), _agent, slashShareOfCollateral, slashTimestamp, new bytes(0)
            );

            // TODO: the burner could be a non routing burner, could add hooks?
            IBurnerRouter(vault.burner()).triggerTransfer(address(this));
            IERC20(vault.collateral()).safeTransfer(_recipient, slashShareOfCollateral);

            emit Slash(_agent, _recipient, slashShareOfCollateral);
        }
    }

    /// @notice Coverage by vault
    /// @param _agent Agent address
    /// @param _vault Vault address
    /// @param _oracle Oracle address
    /// @param _timestamp Timestamp
    /// @return collateralValue Collateral value
    /// @return collateral Collateral amount
    function coverageByVault(address _agent, address _vault, address _oracle, uint48 _timestamp)
        public
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        address collateralAddress = IVault(_vault).collateral();
        uint8 decimals = IERC20Metadata(collateralAddress).decimals();
        uint256 collateralPrice = IOracle(_oracle).getPrice(collateralAddress);

        collateral = IBaseDelegator(IVault(_vault).delegator()).stakeAt(subnetwork(_agent), _agent, _timestamp, "");
        collateralValue = collateral * collateralPrice / (10 ** decimals);
        return (collateralValue, collateral);
    }

    /// @notice Coverage of an agent by Symbiotic vaults
    /// @param _agent Agent address
    /// @return delegation Delegation amount in USD (8 decimals)
    function coverage(address _agent) external view returns (uint256 delegation) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();

        for (uint256 i = 0; i < $.vaults[_agent].length; i++) {
            (uint256 value,) = coverageByVault(_agent, $.vaults[_agent][i], $.oracle, timestamp());
            delegation += value;
        }
    }

    /// @notice Timestamp
    /// @return stamp Timestamp of the current block minus the slash duration
    function timestamp() public view returns (uint48 stamp) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        /// @dev We need to slash the delegated collateral that is available at timestamp - slash duration time.
        stamp = uint48(block.timestamp - $.slashDuration);
    }

    /// @notice Subnetwork id
    /// @dev Creates a collision resistant uint96 identifier by taking keccak256 hash of agent address
    /// and using the first 96 bits of the hash
    /// @param _agent Agent address
    /// @return id Subnetwork identifier (first 96 bits of keccak256 hash of agent address)
    function subnetworkIdentifier(address _agent) public pure returns (uint96 id) {
        bytes32 hash = keccak256(abi.encodePacked(_agent));
        id = uint96(uint256(hash)); // Takes first 96 bits of hash
    }

    /// @notice Subnetwork id concatenated with network address
    /// @return id Subnetwork id
    function subnetwork(address _agent) public view returns (bytes32 id) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        id = Subnetwork.subnetwork($.network, subnetworkIdentifier(_agent));
    }

    /// @notice Registered vaults for an agent
    /// @param _agent Agent address
    /// @return vaultAddresses Vault addresses
    function vaults(address _agent) external view returns (address[] memory vaultAddresses) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        vaultAddresses = $.vaults[_agent];
    }

    /// @dev Verify a vault has the required specifications
    /// @param _vault Vault address
    function _verifyVault(address _vault) internal view {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();

        if (!IRegistry($.vaultRegistry).isEntity(_vault)) {
            revert NotVault();
        }

        if (!IVault(_vault).isInitialized()) revert VaultNotInitialized();

        uint48 vaultEpoch = IVault(_vault).epochDuration();
        if (vaultEpoch != $.requiredEpochDuration) revert InvalidEpochDuration($.requiredEpochDuration, vaultEpoch);

        address slasher = IVault(_vault).slasher();
        uint64 slasherType = IEntity(slasher).TYPE();
        if (slasher == address(0)) revert NoSlasher();
        if (slasherType != uint64(DataTypes.SlasherType.INSTANT)) revert InvalidSlasher();

        address burner = IVault(_vault).burner();
        if (burner == address(0)) revert NoBurner();

        address delegator = IVault(_vault).delegator();
        uint64 delegatorType = IEntity(delegator).TYPE();
        if (delegatorType != uint64(DataTypes.DelegatorType.NETWORK_RESTAKE)) revert InvalidDelegator();
    }

    /// @notice Distribute rewards accumulated by the agent borrowing
    /// @param _token Token address
    function distributeRewards(address _vault, address _token) external checkAccess(this.distributeRewards.selector) {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        address stakerRewarder = $.stakerRewarders[_vault];
        if (stakerRewarder == address(0)) revert NoStakerRewarder();

        IERC20(_token).forceApprove(address(IStakerRewards(stakerRewarder)), amount);
        IStakerRewards(stakerRewarder).distributeRewards(
            $.network,
            _token,
            amount,
            abi.encode(
                timestamp(),
                1000, // Min Fee Amount we allow. Maybe we should make this configurable?
                new bytes(0),
                new bytes(0)
            )
        );
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
