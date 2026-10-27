// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7540AsyncRedeem } from "../interfaces/IERC7540AsyncRedeem.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { IWrapper } from "../interfaces/IWrapper.sol";
import { IFeeReceiverV1 } from "./IFeeReceiverV1.sol";
import { IMigrator } from "./IMigrator.sol";
import { IStakedCapV1 } from "./IStakedCapV1.sol";
import { IVaultV1 } from "./IVaultV1.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Migrator
/// @author kexley, Cap Labs
/// @notice Upgrade the live cUSD and stcUSD proxies onto v2 in one transaction that checks the v1
/// state it relies on and the v2 state it leaves, reverting as a whole if either is wrong
/// @dev The runbook is on {IMigrator}.
contract Migrator is IMigrator {
    using SafeERC20 for IERC20;

    /// @dev Largest stcUSD share-price jump the upgrade accepts, as a fraction of v1 assets (1 bp).
    /// Exact equality would let anyone block the migration with a 1 wei donation.
    uint256 private constant MAX_STAKED_PRICE_JUMP = 10_000;

    /// @inheritdoc IMigrator
    address public immutable executor;

    /// @inheritdoc IMigrator
    address public immutable upgrader;

    /// @inheritdoc IMigrator
    address public immutable stablecoin;

    /// @inheritdoc IMigrator
    address public immutable wrapper;

    /// @inheritdoc IMigrator
    address public immutable feeReceiver;

    /// @inheritdoc IMigrator
    address public immutable stablecoinImplementation;

    /// @inheritdoc IMigrator
    address public immutable wrapperImplementation;

    /// @inheritdoc IMigrator
    address public immutable authority;

    /// @inheritdoc IMigrator
    address public immutable underlying;

    /// @inheritdoc IMigrator
    address public immutable irm;

    /// @inheritdoc IMigrator
    address public immutable reserveVault;

    /// @inheritdoc IMigrator
    uint256 public immutable vestingPeriod;

    /// @inheritdoc IMigrator
    bool public migrated;

    /// @param config The addresses and parameters the migration needs
    constructor(Config memory config) {
        executor = config.executor;
        upgrader = config.upgrader;
        stablecoin = config.stablecoin;
        wrapper = config.wrapper;
        feeReceiver = config.feeReceiver;
        stablecoinImplementation = config.stablecoinImplementation;
        wrapperImplementation = config.wrapperImplementation;
        authority = config.authority;
        underlying = config.underlying;
        irm = config.irm;
        reserveVault = config.reserveVault;
        vestingPeriod = config.vestingPeriod;
    }

    /// @inheritdoc IMigrator
    function lastNotify() external view returns (uint256 timestamp) {
        timestamp = block.timestamp;
    }

    /// @inheritdoc IMigrator
    function lockDuration() external pure returns (uint256 duration) { }

    /// @inheritdoc IMigrator
    function migrate(uint256 maxTopUp) external {
        if (msg.sender != executor) revert NotExecutor();
        if (migrated) revert AlreadyMigrated();
        migrated = true;

        // reverts unless the FeeReceiver points somewhere that answers it, such as this contract
        IFeeReceiverV1(feeReceiver).distribute();

        _checkUnwound();
        uint256 cusdSupply = IERC20(stablecoin).totalSupply();
        _topUp(cusdSupply, maxTopUp);
        uint256 stakedSupply = IERC20(wrapper).totalSupply();
        uint256 stakedAssets = IStakedCapV1(wrapper).totalAssets();
        bytes32 cusdDomain = IERC20Permit(stablecoin).DOMAIN_SEPARATOR();
        bytes32 stakedDomain = IERC20Permit(wrapper).DOMAIN_SEPARATOR();

        // cUSD first: the wrapper initializer opts into the new vest, which only exists after it.
        // The live name and symbol keep the ERC-2612 domain where it is.
        UUPSUpgradeable(stablecoin)
            .upgradeToAndCall(
                stablecoinImplementation,
                abi.encodeCall(
                    IStablecoin.initialize,
                    (
                        authority,
                        underlying,
                        IERC20Metadata(stablecoin).name(),
                        IERC20Metadata(stablecoin).symbol(),
                        irm,
                        reserveVault,
                        vestingPeriod
                    )
                )
            );
        UUPSUpgradeable(wrapper)
            .upgradeToAndCall(wrapperImplementation, abi.encodeCall(IWrapper.initialize, (authority, stablecoin)));

        if (
            IERC20(stablecoin).totalSupply() != cusdSupply || IERC20(wrapper).totalSupply() != stakedSupply
                || IERC20Permit(stablecoin).DOMAIN_SEPARATOR() != cusdDomain
                || IERC20Permit(wrapper).DOMAIN_SEPARATOR() != stakedDomain
        ) revert StateNotCarriedOver();
        _checkUpgradable(stablecoin);
        _checkUpgradable(wrapper);
        // v2 treats the whole supply as reserve-backed and caps exits at the underlying it holds
        if (IStablecoin(stablecoin).unlockedSupply() < cusdSupply) revert UnwindIncomplete();
        // v2 values stcUSD at its whole cUSD balance, so locked or un-notified v1 profit lands at once
        if (IWrapper(wrapper).totalAssets() > stakedAssets + stakedAssets / MAX_STAKED_PRICE_JUMP) {
            revert StakedPriceWouldJump();
        }

        _returnFees();
        emit Migrated();
    }

    /// @inheritdoc IMigrator
    function returnFees() external {
        if (!migrated) revert NotMigrated();
        IFeeReceiverV1(feeReceiver).distribute();
        _returnFees();
    }

    /// @dev Require the v1 unwind to be complete for every asset: nothing lent to agents, nothing
    /// invested in the fractional reserve, and no reserve interest left to realize, since the v1
    /// functions that would recover any of it are gone once cUSD is upgraded
    function _checkUnwound() private view {
        address[] memory v1Assets = IVaultV1(stablecoin).assets();
        for (uint256 i; i < v1Assets.length; ++i) {
            address asset = v1Assets[i];
            if (IVaultV1(stablecoin).totalBorrows(asset) != 0) revert LoansOutstanding(asset);
            if (IVaultV1(stablecoin).loaned(asset) != 0) revert ReserveInvested(asset);
            if (IVaultV1(stablecoin).claimableInterest(asset) != 0) revert InterestUnrealized(asset);
        }
    }

    /// @dev Require a v2 token to answer to the configured access manager, and the upgrader to be able
    /// to upgrade it there, immediately or after its execution delay, so it cannot be left stranded
    /// @param proxy The token proxy
    function _checkUpgradable(address proxy) private view {
        if (IAccessManaged(proxy).authority() != authority) revert AccessNotConfigured(proxy);
        (bool immediate, uint32 delay) =
            IAccessManager(authority).canCall(upgrader, proxy, UUPSUpgradeable.upgradeToAndCall.selector);
        if (!immediate && delay == 0) revert AccessNotConfigured(proxy);
    }

    /// @dev Pull from the executor whatever cUSD lacks to hold the underlying for its whole supply.
    /// v1 priced mints and burns off the oracle, so a full unwind still leaves it slightly short.
    /// @param cusdSupply The cUSD supply to back
    /// @param maxTopUp The most underlying the executor allowed
    function _topUp(uint256 cusdSupply, uint256 maxTopUp) private {
        uint256 scale = 10 ** (IERC20Metadata(stablecoin).decimals() - IERC20Metadata(underlying).decimals());
        uint256 needed = Math.ceilDiv(cusdSupply, scale);
        uint256 held = IERC20(underlying).balanceOf(stablecoin);
        if (held >= needed) return;
        uint256 shortfall = needed - held;
        if (shortfall > maxTopUp) revert TopUpExceedsMax(shortfall, maxTopUp);
        IERC20(underlying).safeTransferFrom(msg.sender, stablecoin, shortfall);
        emit ToppedUp(shortfall);
    }

    /// @dev Withdraw the collected cUSD in whole units of the underlying and fund it back, so it
    /// vests to every opted-in cUSD holder, stcUSD included, without moving the stcUSD share price.
    /// Burning and minting the same shares leaves the cUSD supply exactly where it was; dust below
    /// one unit stays here for a later call.
    function _returnFees() private {
        uint256 assets = IERC4626(stablecoin).convertToAssets(IERC20(stablecoin).balanceOf(address(this)));
        if (assets == 0) return;
        uint256 shares = IERC7540AsyncRedeem(stablecoin).instantWithdraw(assets, address(this), address(this));
        IERC20(underlying).forceApprove(stablecoin, assets);
        IStablecoin(stablecoin).fund(assets);
        emit FeesReturned(shares, assets);
    }
}
