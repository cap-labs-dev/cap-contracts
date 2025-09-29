// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../../../access/Access.sol";
import { IOracle } from "../../../interfaces/IOracle.sol";
import { IStakerRewards } from "../../../interfaces/IStakerRewards.sol";

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IBurnerRouter } from "@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol";

import { ISymbioticNetwork } from "../../../interfaces/ISymbioticNetwork.sol";
import { ISymbioticNetworkMiddleware } from "../../../interfaces/ISymbioticNetworkMiddleware.sol";
import { SymbioticNetworkMiddlewareStorageUtils } from "../../../storage/SymbioticNetworkMiddlewareStorageUtils.sol";

import { Subnetwork } from "@symbioticfi/core/src/contracts/libraries/Subnetwork.sol";
import { IEntity } from "@symbioticfi/core/src/interfaces/common/IEntity.sol";
import { IRegistry } from "@symbioticfi/core/src/interfaces/common/IRegistry.sol";
import { IBaseDelegator } from "@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol";
import { ISlasher } from "@symbioticfi/core/src/interfaces/slasher/ISlasher.sol";
import { IVault } from "@symbioticfi/core/src/interfaces/vault/IVault.sol";

/// @title Symbiotic Network Middleware
/// @author weso, Cap Labs
/// @notice This contract manages the symbiotic collateral and slashing
contract SymbioticNetworkMiddleware is
    ISymbioticNetworkMiddleware,
    UUPSUpgradeable,
    Access,
    SymbioticNetworkMiddlewareStorageUtils
{
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function initialize(
        address _accessControl,
        address _network,
        address _vaultRegistry,
        address _oracle,
        uint48 _requiredEpochDuration,
        uint256 _feeAllowed
    ) external initializer {
        __Access_init(_accessControl);
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();
        $.network = _network;
        $.vaultRegistry = _vaultRegistry;
        $.oracle = _oracle;
        $.requiredEpochDuration = _requiredEpochDuration;
        $.feeAllowed = _feeAllowed;
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function registerVault(address _vault, address _stakerRewarder, address _agent)
        external
        checkAccess(this.registerVault.selector)
    {
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();
        if ($.agentsToVault[_agent] != address(0)) revert ExistingCoverage();
        if (_stakerRewarder == address(0) || _agent == address(0)) revert ZeroAddress();

        _verifyVault(_vault);
        Vault storage vault = $.vaults[_vault];
        if (vault.exists) revert VaultExists();
        vault.stakerRewarder = _stakerRewarder;
        vault.exists = true;
        $.agentsToVault[_agent] = _vault;

        ISymbioticNetwork($.network).registerVault(_vault, _agent);

        emit VaultRegistered(_vault, _agent);
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function setFeeAllowed(uint256 _feeAllowed) external checkAccess(this.setFeeAllowed.selector) {
        getSymbioticNetworkMiddlewareStorage().feeAllowed = _feeAllowed;
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function slash(address _agent, address _recipient, uint256 _slashShare, uint48 _timestamp)
        external
        checkAccess(this.slash.selector)
    {
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();

        IVault vault = IVault($.agentsToVault[_agent]);

        (, uint256 totalSlashableCollateral) =
            slashableCollateralByVault($.network, _agent, address(vault), $.oracle, _timestamp);

        // Round up in favor of the liquidator
        uint256 slashShareOfCollateral =
            _slashShare == 1e18 ? totalSlashableCollateral : (totalSlashableCollateral * _slashShare / 1e18) + 1;

        // If the slash share is greater than the total slashable collateral, set it to the total slashable collateral
        if (slashShareOfCollateral > totalSlashableCollateral) {
            slashShareOfCollateral = totalSlashableCollateral;
        }

        address operator = ISymbioticNetwork($.network).getOperator(_agent);

        ISlasher(vault.slasher()).slash(
            subnetwork(operator), operator, slashShareOfCollateral, _timestamp, new bytes(0)
        );

        IBurnerRouter(vault.burner()).triggerTransfer(address(this));
        IERC20(vault.collateral()).safeTransfer(_recipient, slashShareOfCollateral);

        emit Slash(_agent, _recipient, slashShareOfCollateral);
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function distributeRewards(address _agent, address _token) external checkAccess(this.distributeRewards.selector) {
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();
        uint256 _amount = IERC20(_token).balanceOf(address(this));

        address _vault = $.agentsToVault[_agent];
        address stakerRewarder = $.vaults[_vault].stakerRewarder;

        IERC20(_token).forceApprove(stakerRewarder, _amount);
        IStakerRewards(stakerRewarder).distributeRewards(
            $.network, _token, _amount, abi.encode(uint48(block.timestamp - 1), $.feeAllowed, "", "")
        );
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function coverageByVault(address _network, address _agent, address _vault, address _oracle, uint48 _timestamp)
        public
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        (IBurnerRouter burnerRouter, uint8 decimals, uint256 collateralPrice) =
            _getVaultInfo(_network, _agent, _vault, _oracle);

        if (address(burnerRouter) == address(0)) return (0, 0);

        address operator = ISymbioticNetwork(_network).getOperator(_agent);

        collateral = IBaseDelegator(IVault(_vault).delegator()).stakeAt(subnetwork(operator), operator, _timestamp, "");
        collateralValue = collateral * collateralPrice / (10 ** decimals);
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function slashableCollateralByVault(
        address _network,
        address _agent,
        address _vault,
        address _oracle,
        uint48 _timestamp
    ) public view returns (uint256 collateralValue, uint256 collateral) {
        (IBurnerRouter burnerRouter, uint8 decimals, uint256 collateralPrice) =
            _getVaultInfo(_network, _agent, _vault, _oracle);

        if (address(burnerRouter) == address(0)) return (0, 0);

        ISlasher slasher = ISlasher(IVault(_vault).slasher());
        address operator = ISymbioticNetwork(_network).getOperator(_agent);
        collateral = slasher.slashableStake(subnetwork(operator), operator, _timestamp, "");
        collateralValue = collateral * collateralPrice / (10 ** decimals);
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function coverage(address _agent) public view returns (uint256 delegation) {
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();
        address _vault = $.agentsToVault[_agent];
        if (_vault == address(0)) revert ZeroAddress();
        address _network = $.network;
        address _oracle = $.oracle;
        uint48 _timestamp = uint48(block.timestamp);

        (delegation,) = coverageByVault(_network, _agent, _vault, _oracle, _timestamp);
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function slashableCollateral(address _agent, uint48 _timestamp)
        public
        view
        returns (uint256 _slashableCollateral)
    {
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();
        address _vault = $.agentsToVault[_agent];
        address _network = $.network;
        address _oracle = $.oracle;

        (_slashableCollateral,) = slashableCollateralByVault(_network, _agent, _vault, _oracle, _timestamp);
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function subnetworkIdentifier(address _operator) public pure returns (uint96 id) {
        bytes32 hash = keccak256(abi.encodePacked(_operator));
        id = uint96(uint256(hash)); // Takes first 96 bits of hash
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function subnetwork(address _operator) public view returns (bytes32 id) {
        id = Subnetwork.subnetwork(getSymbioticNetworkMiddlewareStorage().network, subnetworkIdentifier(_operator));
    }

    /// @inheritdoc ISymbioticNetworkMiddleware
    function vaults(address _agent) external view returns (address vaultAddress) {
        vaultAddress = getSymbioticNetworkMiddlewareStorage().agentsToVault[_agent];
    }

    /// @dev Get vault info
    /// @param _network Network address
    /// @param _agent Agent address
    /// @param _vault Vault address
    /// @param _oracle Oracle address
    /// @return burnerRouter The burner router contract
    /// @return decimals The collateral token decimals
    /// @return collateralPrice The collateral token price
    function _getVaultInfo(address _network, address _agent, address _vault, address _oracle)
        private
        view
        returns (IBurnerRouter burnerRouter, uint8 decimals, uint256 collateralPrice)
    {
        burnerRouter = IBurnerRouter(IVault(_vault).burner());

        address operator = ISymbioticNetwork(_network).getOperator(_agent);

        // Check pending receivers
        (address pendingReceiver,) = burnerRouter.pendingNetworkReceiver(_network);
        if (pendingReceiver != address(0) && pendingReceiver != address(this)) {
            return (IBurnerRouter(address(0)), 0, 0);
        }

        (pendingReceiver,) = burnerRouter.pendingOperatorNetworkReceiver(_network, operator);
        if (pendingReceiver != address(0) && pendingReceiver != address(this)) {
            return (IBurnerRouter(address(0)), 0, 0);
        }

        address collateral = IVault(_vault).collateral();
        decimals = IERC20Metadata(collateral).decimals();
        (collateralPrice,) = IOracle(_oracle).getPrice(collateral);
    }

    /// @dev Verify a vault has the required specifications
    /// @param _vault Vault address
    function _verifyVault(address _vault) internal view {
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();

        if (!IRegistry($.vaultRegistry).isEntity(_vault)) {
            revert NotVault();
        }

        if (!IVault(_vault).isInitialized()) revert VaultNotInitialized();

        uint48 vaultEpoch = IVault(_vault).epochDuration();
        if (vaultEpoch < $.requiredEpochDuration) revert InvalidEpochDuration($.requiredEpochDuration, vaultEpoch);

        address slasher = IVault(_vault).slasher();
        uint64 slasherType = IEntity(slasher).TYPE();
        if (slasherType != uint64(ISymbioticNetworkMiddleware.SlasherType.INSTANT)) revert InvalidSlasher();

        address burner = IVault(_vault).burner();
        if (burner == address(0)) revert NoBurner();
        address receiver = IBurnerRouter(burner).networkReceiver($.network);
        address globalReceiver = IBurnerRouter(burner).globalReceiver();
        if (globalReceiver != address(this)) {
            if (receiver != address(this)) revert InvalidBurnerRouter();
        }

        address delegator = IVault(_vault).delegator();
        uint64 delegatorType = IEntity(delegator).TYPE();
        if (delegatorType != uint64(ISymbioticNetworkMiddleware.DelegatorType.OPERATOR_NETWORK_SPECIFIC)) {
            revert InvalidDelegator();
        }
    }

    /// @notice Get the collateral address of an agent
    /// @param _agent Agent address
    /// @return collateral The collateral address of the agent
    function collateralAddress(address _agent) external view returns (address) {
        SymbioticNetworkMiddlewareStorage storage $ = getSymbioticNetworkMiddlewareStorage();
        if ($.agentsToVault[_agent] == address(0)) return address(0);
        else return IVault($.agentsToVault[_agent]).collateral();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
