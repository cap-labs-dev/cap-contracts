// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { NetworkMiddlewareStorage } from "./libraries/NetworkMiddlewareStorage.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";
import { AccessUpgradeable } from "../../../access/AccessUpgradeable.sol";
import { IOracle } from "../../../interfaces/IOracle.sol";
import { IStakerRewards } from "./interfaces/IStakerRewards.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";
import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IRegistry } from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";
import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";

/// @title Cap Symbiotic Network Middleware Contract
/// @author Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing.
contract NetworkMiddleware is UUPSUpgradeable, AccessUpgradeable {
    using SafeERC20 for IERC20;

    event VaultRegistered(address vault);
    event Slash(address indexed agent, address recipient, uint256 amount);

    error InvalidSlasher();
    error InvalidDelegator();
    error NotVault();
    error NoSlasher();
    error NoBurner();
    error VaultNotInitialized();
    error InvalidEpochDuration(uint48 required, uint48 actual);
    error InvalidSlashDuration();

    /// @notice Initialize
    /// @param _accessControl Access control address
    /// @param _network Network address
    /// @param _vaultRegistry Vault registry address
    /// @param _oracle Oracle address
    /// @param _stakerRewarder Staker rewarder address
    /// @param _requiredEpochDuration Required epoch duration in seconds
    /// @param _slashDuration amount of time we have to liquidate collateral in a slash event, needs to be < epochDuration
    function initialize(
        address _accessControl,
        address _network,
        address _vaultRegistry,
        address _oracle,
        address _stakerRewarder,
        uint48 _requiredEpochDuration,
        uint48 _slashDuration
    ) external initializer {
        __Access_init(_accessControl);
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        $.network = _network;
        $.vaultRegistry = _vaultRegistry;
        $.oracle = _oracle;
        $.stakerRewarder = _stakerRewarder;
        $.requiredEpochDuration = _requiredEpochDuration;
        $.slashDuration = _slashDuration;

        if (_slashDuration >= _requiredEpochDuration) revert InvalidSlashDuration();
    }

    /// @notice Register vault to be used as collateral within the CAP system
    /// @param _vault Vault address
    /// @param _agents Agents supported by the vault
    function registerVault(address _vault, address[] calldata _agents) external checkAccess(this.registerVault.selector) {
        _verifyVault(_vault);
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        for (uint256 i; i < _agents.length; ++i) {
            $.vaults[_agents[i]].push(_vault);
        }
        emit VaultRegistered(_vault);
    }

    /// @notice Slash delegation and send to recipient
    /// @param _agent Agent address
    /// @param _recipient Recipient of the slashed assets
    /// @param _slashShare Percentage of delegation to slash
    function slash(address _agent, address _recipient, uint256 _slashShare) external checkAccess(this.slash.selector) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();

        uint48 _timestamp = timestamp();

        for (uint256 i; i < $.vaults[_agent].length; ++i) {
            IVault vault = IVault($.vaults[_agent][i]);
            uint256 toSlashValue = coverageByVault(_agent, address(vault), $.oracle, _timestamp) * _slashShare / 1e18;
            address collateral = vault.collateral();
        
            uint256 toSlash = _toSlash(collateral, toSlashValue, $.oracle);

            ISlasher(vault.slasher()).slash(subnetwork(), _agent, toSlash, _timestamp, new bytes(0));
            // TODO: the burner could be a non routing burner, could add hooks?
            IBurnerRouter(vault.burner()).triggerTransfer(address(this));
            IERC20(collateral).safeTransfer(_recipient, toSlash);

            emit Slash(_agent, _recipient, toSlash);
        }
    }

    /// @dev Fetch the current amounts that can be slashed from a vault for an agent
    /// @param _collateral Collateral address
    /// @param _amount Amount in USD to slash
    /// @param _oracle Oracle address
    function _toSlash(
        address _collateral,
        uint256 _amount,
        address _oracle
    ) internal view returns (uint256 toSlash) {
        uint256 collateralPrice = IOracle(_oracle).getPrice(_collateral);
        uint8 decimals = IERC20Metadata(_collateral).decimals();

        toSlash = _amount * (10 ** decimals) / collateralPrice;
    }

    function coverageByVault(address _agent, address _vault, address _oracle, uint48 _timestamp) public view returns (uint256 delegation) {
        address collateralAddress = IVault(_vault).collateral();
        uint8 decimals = IERC20Metadata(collateralAddress).decimals();
        uint256 collateralPrice = IOracle(_oracle).getPrice(collateralAddress);

        uint256 collateral = IBaseDelegator(IVault(_vault).delegator()).stakeAt(subnetwork(), _agent, _timestamp, "");
        delegation = collateral * collateralPrice / (10 ** decimals);
    }

    /// @notice Coverage of an agent by Symbiotic vaults
    /// @param _agent Agent address
    /// @return delegation Delegation amount in USD (8 decimals)
    function coverage(address _agent) external view returns (uint256 delegation) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();

        for (uint256 i = 0; i < $.vaults[_agent].length; i++) {
            delegation += coverageByVault(_agent, $.vaults[_agent][i], $.oracle, timestamp());
        }
    }

    function timestamp() public view returns (uint48 stamp) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        /// @dev We need to slash the delegated collateral that is available at timestamp - slash duration time.
        stamp = uint48(block.timestamp - $.slashDuration);
    }

    /// @notice Subnetwork id
    function subnetworkIdentifier() public pure returns (uint96) {
        return 0;
    }

    /// @notice Subnetwork id concatenated with network address
    /// @return id Subnetwork id
    function subnetwork() public view returns (bytes32 id) {
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        id = Subnetwork.subnetwork($.network, 0);
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
    function distributeRewards(address _token) external checkAccess(this.distributeRewards.selector) {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        DataTypes.NetworkMiddlewareStorage storage $ = NetworkMiddlewareStorage.get();
        IStakerRewards($.stakerRewarder).distributeRewards(
            $.network,
            _token,
            amount,
            abi.encode(
                uint48(block.timestamp - 1),
                0,
                new bytes(0),
                new bytes(0)
            )
        );
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) {}
}
