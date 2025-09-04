// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";
import { ICapInterestHarvester } from "../interfaces/ICapInterestHarvester.sol";
import { IFeeAuction } from "../interfaces/IFeeAuction.sol";
import { IFeeReceiver } from "../interfaces/IFeeReceiver.sol";
import { IHarvester } from "../interfaces/IHarvester.sol";

import { ILender } from "../interfaces/ILender.sol";
import { IMinter } from "../interfaces/IMinter.sol";
import { IVault } from "../interfaces/IVault.sol";
import { CapInterestHarvesterStorageUtils } from "../storage/CapInterestHarvesterStorageUtils.sol";
import { IBalancerVault } from "./interfaces/IBalancerVault.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Cap Interest Harvester
/// @author weso, Cap Labs
/// @notice Harvests interest from borrow and the fractional reserve, sends to fee auction, buys interest, calls distribute on fee receiver
contract CapInterestHarvester is ICapInterestHarvester, UUPSUpgradeable, Access, CapInterestHarvesterStorageUtils {
    using SafeERC20 for IERC20;

    error InvalidFlashLoan();

    event HarvestedInterest(uint256 timestamp);
    event ExcessReceiverSet(address excessReceiver);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ICapInterestHarvester
    function initialize(
        address _accessControl,
        address _asset,
        address _cusd,
        address _feeAuction,
        address _feeReceiver,
        address _harvester,
        address _lender,
        address _balancerVault,
        address _excessReceiver
    ) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();

        CapInterestHarvesterStorage storage s = getCapInterestHarvesterStorage();
        s.asset = _asset;
        s.cusd = _cusd;
        s.feeAuction = _feeAuction;
        s.feeReceiver = _feeReceiver;
        s.harvester = _harvester;
        s.lender = _lender;
        s.balancerVault = _balancerVault;
        s.excessReceiver = _excessReceiver;
    }

    /// @inheritdoc ICapInterestHarvester
    function harvestInterest() external checkAccess(this.harvestInterest.selector) {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();

        /// 1. Harvest fractional reserve
        _harvestFractionalReserve($.harvester, $.asset, $.cusd);

        /// 2. Claim interest from lender
        _claimInterestFromLender($.lender, $.asset);

        /// 3. Flashloan buy all the interest
        _flashloanBuyInterest($.balancerVault, $.cusd, $.feeAuction, $.asset);

        /// 4. Call distribute on fee receiver
        _distributeInterest($.feeReceiver);

        $.lastharvest = block.timestamp;

        emit HarvestedInterest(block.timestamp);
    }

    /// @dev Harvest fractional reserve
    /// @param _harvester Harvester address
    /// @param _asset Asset address
    /// @param _cusd cUSD address
    function _harvestFractionalReserve(address _harvester, address _asset, address _cusd) private {
        try IHarvester(_harvester).harvest(_cusd, _asset) { } catch { } // ignore errors
    }

    /// @dev Claim interest from lender
    /// @param _lender Lender address
    /// @param _asset Asset address
    function _claimInterestFromLender(address _lender, address _asset) private {
        uint256 maxRealization = ILender(_lender).maxRealization(_asset);
        if (maxRealization > 0) ILender(_lender).realizeInterest(_asset);
    }

    /// @dev Flashloan buy all the interest
    /// @param _asset Asset address
    function _flashloanBuyInterest(address _balancerVault, address _cusd, address _feeAuction, address _asset)
        private
    {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();
        uint256 assetBalOfFeeAuction = IERC20(_asset).balanceOf(_feeAuction);
        uint256 price = IFeeAuction(_feeAuction).currentPrice();
        (uint256 cusdAmountFromMint,) = IMinter(_cusd).getMintAmount(_asset, assetBalOfFeeAuction);

        if (cusdAmountFromMint > price) {
            address[] memory assets = new address[](1);
            assets[0] = _asset;

            uint256[] memory amounts = new uint256[](1);
            amounts[0] = assetBalOfFeeAuction;

            IBalancerVault balancerVault = IBalancerVault(_balancerVault);
            $.flashInProgress = true;

            balancerVault.flashLoan(address(this), assets, amounts, "");
        }
    }

    /// @dev Call distribute on fee receiver
    /// @param _feeReceiver Fee receiver address
    function _distributeInterest(address _feeReceiver) private {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();
        uint256 cusdBalOfFeeReceiver = IERC20($.cusd).balanceOf($.feeReceiver);
        if (cusdBalOfFeeReceiver > 0) IFeeReceiver(_feeReceiver).distribute();
    }

    /// @inheritdoc ICapInterestHarvester
    function receiveFlashLoan(IERC20[] memory, uint256[] memory amounts, uint256[] memory feeAmounts, bytes memory)
        external
        checkAccess(this.receiveFlashLoan.selector)
    {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();
        if (!$.flashInProgress) revert InvalidFlashLoan();
        _checkApproval($.asset, $.cusd);
        _checkApproval($.cusd, $.feeAuction);

        uint256 price = IFeeAuction($.feeAuction).currentPrice();

        IVault($.cusd).mint($.asset, amounts[0], price, address(this), block.timestamp);

        address[] memory assets = new address[](1);
        assets[0] = $.asset;

        uint256[] memory minAmounts = new uint256[](1);
        minAmounts[0] = IERC20($.asset).balanceOf($.feeAuction);

        IFeeAuction($.feeAuction).buy(price, assets, minAmounts, address(this), block.timestamp);

        uint256 cusdLeft = IERC20($.cusd).balanceOf(address(this));
        if (cusdLeft > 0) {
            (uint256 burnAmount,) = IMinter($.cusd).getBurnAmount($.asset, cusdLeft);
            if (burnAmount > 0) IVault($.cusd).burn($.asset, cusdLeft, burnAmount, address(this), block.timestamp);
        }

        IERC20($.asset).safeTransfer($.balancerVault, amounts[0] + feeAmounts[0]);
        uint256 excessAmount = IERC20($.asset).balanceOf(address(this));
        if (excessAmount > 0) IERC20($.asset).safeTransfer($.excessReceiver, excessAmount);
        $.flashInProgress = false;
    }

    /// @dev Check approval
    /// @param _asset Asset address
    /// @param _feeAuction Fee auction address
    function _checkApproval(address _asset, address _feeAuction) private {
        uint256 allowance = IERC20(_asset).allowance(address(this), _feeAuction);
        if (allowance == 0) {
            IERC20(_asset).forceApprove(_feeAuction, type(uint256).max);
        }
    }

    /// @inheritdoc ICapInterestHarvester
    function lastHarvest() public view returns (uint256) {
        return getCapInterestHarvesterStorage().lastharvest;
    }

    /// @inheritdoc ICapInterestHarvester
    function setExcessReceiver(address _excessReceiver) external checkAccess(this.setExcessReceiver.selector) {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();
        $.excessReceiver = _excessReceiver;

        emit ExcessReceiverSet(_excessReceiver);
    }

    /// @inheritdoc ICapInterestHarvester
    function checker() external view returns (bool canExec, bytes memory execPayload) {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();

        // Just harvest if its been 24 hours since last harvest
        if (block.timestamp - $.lastharvest > 24 hours) {
            return (true, abi.encodeCall(this.harvestInterest, ()));
        }

        uint256 assetBalOfFeeAuction = IERC20($.asset).balanceOf($.feeAuction);
        uint256 price = IFeeAuction($.feeAuction).currentPrice();
        (uint256 cusdAmountFromMint,) = IMinter($.cusd).getMintAmount($.asset, assetBalOfFeeAuction);

        canExec = cusdAmountFromMint > price;

        if (!canExec) return (canExec, bytes("Not enough cUSD to mint"));

        execPayload = abi.encodeCall(this.harvestInterest, ());
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
