// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { ICapSweeper } from "../interfaces/ICapSweeper.sol";
import { IFractionalReserve } from "../interfaces/IFractionalReserve.sol";
import { IVault } from "../interfaces/IVault.sol";
import { CapSweeperStorageUtils } from "../storage/CapSweeperStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title Cap Sweeper
/// @author weso, Cap Labs
/// @notice Sweeps assets from fractional reserve
contract CapSweeper is ICapSweeper, Access, CapSweeperStorageUtils, UUPSUpgradeable {
    event Swept(address indexed asset, uint256 amount);
    event SweepIntervalSet(uint256 sweepInterval);
    event MinSweepAmountSet(uint256 minSweepAmount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ICapSweeper
    function initialize(address _accessControl, address _cusd, uint256 _sweepInterval, uint256 _minSweepAmount)
        external
        initializer
    {
        __UUPSUpgradeable_init();
        __Access_init(_accessControl);

        CapSweeperStorage storage $ = getCapSweeperStorage();
        $.cusd = _cusd;
        $.sweepInterval = _sweepInterval;
        $.minSweepAmount = _minSweepAmount;
    }

    /// @inheritdoc ICapSweeper
    function sweep(address _asset) external checkAccess(this.sweep.selector) {
        CapSweeperStorage storage $ = getCapSweeperStorage();
        uint256 assetBal = IERC20Metadata(_asset).balanceOf($.cusd);
        if (assetBal > 0) IFractionalReserve($.cusd).investAll(_asset);
        $.lastSweep[_asset] = block.timestamp;
        emit Swept(_asset, assetBal);
    }

    /// @inheritdoc ICapSweeper
    function checker() external view returns (bool canExec, bytes memory execPayload) {
        CapSweeperStorage storage $ = getCapSweeperStorage();
        address[] memory assets = IVault($.cusd).assets();

        for (uint256 i; i < assets.length; ++i) {
            // Skip if last sweep was less than interval ago
            if (block.timestamp - $.lastSweep[assets[i]] < $.sweepInterval) continue;
            // Skip if asset is not supported
            if (IVault($.cusd).paused(assets[i])) continue;
            // Get balance and convert to 18 decimals
            uint256 assetBal =
                IERC20Metadata(assets[i]).balanceOf($.cusd) * 1e18 / (10 ** IERC20Metadata(assets[i]).decimals());
            if (assetBal >= $.minSweepAmount) {
                return (true, abi.encodeCall(this.sweep, (assets[i])));
            }
        }

        return (false, bytes("Nothing To Sweep"));
    }

    /// @inheritdoc ICapSweeper
    function sweepInterval() external view returns (uint256) {
        return getCapSweeperStorage().sweepInterval;
    }

    /// @inheritdoc ICapSweeper
    function minSweepAmount() external view returns (uint256) {
        return getCapSweeperStorage().minSweepAmount;
    }

    /// @inheritdoc ICapSweeper
    function lastSweep(address _asset) external view returns (uint256) {
        return getCapSweeperStorage().lastSweep[_asset];
    }

    /// @inheritdoc ICapSweeper
    function setSweepInterval(uint256 _sweepInterval) external checkAccess(this.setSweepInterval.selector) {
        getCapSweeperStorage().sweepInterval = _sweepInterval;
    }

    /// @inheritdoc ICapSweeper
    function setMinSweepAmount(uint256 _minSweepAmount) external checkAccess(this.setMinSweepAmount.selector) {
        getCapSweeperStorage().minSweepAmount = _minSweepAmount;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
