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
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Cap Interest Harvester
/// @author weso, Cap Labs
/// @notice Harvests interest from borrow and the fractional reserve, sends to fee auction, buys interest, calls distribute on fee receiver
contract CapInterestHarvester is
    ICapInterestHarvester,
    UUPSUpgradeable,
    OwnableUpgradeable,
    CapInterestHarvesterStorageUtils
{
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
        address _owner,
        address _asset,
        address _cusd,
        address _wtgxx,
        address _feeAuction,
        address _feeReceiver,
        address _harvester,
        address _lender,
        address _balancerVault,
        address _excessReceiver
    ) external initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        CapInterestHarvesterStorage storage s = getCapInterestHarvesterStorage();
        s.asset = _asset;
        s.cusd = _cusd;
        s.wtgxx = _wtgxx;
        s.feeAuction = _feeAuction;
        s.feeReceiver = _feeReceiver;
        s.harvester = _harvester;
        s.lender = _lender;
        s.balancerVault = _balancerVault;
        s.excessReceiver = _excessReceiver;
    }

    /// @inheritdoc ICapInterestHarvester
    function harvestInterest() external returns (uint256 _excess) {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();

        /// 1. Harvest fractional reserve
        _harvestFractionalReserve($.harvester, $.asset, $.cusd);
        _harvestFractionalReserve($.harvester, $.wtgxx, $.cusd);

        /// 2. Claim interest from lender
        _claimInterestFromLender($.lender, $.asset);
        _claimInterestFromLender($.lender, $.wtgxx);

        /// 3. Flashloan buy all the interest
        _flashloanBuyInterest($.balancerVault, $.feeAuction);

        /// 4. Call distribute on fee receiver
        _distributeInterest($.feeReceiver);

        $.lastharvest = block.timestamp;

        emit HarvestedInterest(block.timestamp);
        _excess = $.excess;
        $.excess = 0;
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
        (,, address debtToken,,,,) = ILender(_lender).reservesData(_asset);
        if (debtToken == address(0)) return;
        uint256 maxRealization = ILender(_lender).maxRealization(_asset);
        if (maxRealization > 0) ILender(_lender).realizeInterest(_asset);
    }

    /// @dev Flashloan buy all the interest
    /// @param _balancerVault Balancer vault address
    /// @param _feeAuction Fee auction address
    function _flashloanBuyInterest(address _balancerVault, address _feeAuction) private {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();

        uint256 assetBalOfFeeAuction = IERC20($.asset).balanceOf(_feeAuction);
        (uint256 cusdFromUsdc,) = IMinter($.cusd).getMintAmount($.asset, assetBalOfFeeAuction);

        uint256 wtgxxBalOfFeeAuction = IERC20($.wtgxx).balanceOf(_feeAuction);
        (uint256 cusdFromWtgxx,) = IMinter($.cusd).getMintAmount($.wtgxx, wtgxxBalOfFeeAuction);

        uint256 cusdAmountFromMint = cusdFromUsdc + cusdFromWtgxx;

        uint256 price = IFeeAuction(_feeAuction).currentPrice();

        if (cusdAmountFromMint > price) {
            address[] memory flashloanAssets = new address[](1);
            flashloanAssets[0] = $.asset;

            uint256[] memory flashloanAmounts = new uint256[](1);
            flashloanAmounts[0] = price / 0.99e12; // flashloan USDC amount plus buffer (6 decimals vs 18 decimals for price)

            IBalancerVault balancerVault = IBalancerVault(_balancerVault);
            $.flashInProgress = true;
            balancerVault.flashLoan(address(this), flashloanAssets, flashloanAmounts, "");
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
    {
        CapInterestHarvesterStorage storage $ = getCapInterestHarvesterStorage();
        if (msg.sender != $.balancerVault) revert InvalidFlashLoan();
        if (!$.flashInProgress) revert InvalidFlashLoan();
        _checkApproval($.asset, $.cusd);
        _checkApproval($.cusd, $.feeAuction);

        uint256 price = IFeeAuction($.feeAuction).currentPrice();

        IVault($.cusd).mint($.asset, amounts[0], price, address(this), block.timestamp);

        address[] memory assets = new address[](2);
        assets[0] = $.asset;
        assets[1] = $.wtgxx;

        uint256[] memory minAmounts = new uint256[](2);
        minAmounts[0] = IERC20($.asset).balanceOf($.feeAuction);
        minAmounts[1] = IERC20($.wtgxx).balanceOf($.feeAuction);

        IFeeAuction($.feeAuction).buy(price, assets, minAmounts, address(this), block.timestamp);

        uint256 wtgxxBalance = IERC20($.wtgxx).balanceOf(address(this));
        if (wtgxxBalance > 0) {
            _checkApproval($.wtgxx, $.cusd);
            try IVault($.cusd).mint($.wtgxx, wtgxxBalance, 0, address(this), block.timestamp) { }
            catch {
                IERC20($.wtgxx).safeTransfer($.excessReceiver, wtgxxBalance);
            }
        }

        uint256 cusdLeft = IERC20($.cusd).balanceOf(address(this));
        if (cusdLeft > 0) {
            (uint256 burnAmount,) = IMinter($.cusd).getBurnAmount($.asset, cusdLeft);
            if (burnAmount > 0) IVault($.cusd).burn($.asset, cusdLeft, burnAmount, address(this), block.timestamp);
        }

        IERC20($.asset).safeTransfer($.balancerVault, amounts[0] + feeAmounts[0]);
        uint256 excessAmount = IERC20($.asset).balanceOf(address(this));
        $.excess = excessAmount;
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
    function setExcessReceiver(address _excessReceiver) external onlyOwner {
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
        (uint256 cusdFromUsdc,) = IMinter($.cusd).getMintAmount($.asset, assetBalOfFeeAuction);

        uint256 wtgxxBalOfFeeAuction = IERC20($.wtgxx).balanceOf($.feeAuction);
        (uint256 cusdFromWtgxx,) = IMinter($.cusd).getMintAmount($.wtgxx, wtgxxBalOfFeeAuction);

        uint256 cusdAmountFromMint = cusdFromUsdc + cusdFromWtgxx;

        uint256 price = IFeeAuction($.feeAuction).currentPrice();

        canExec = cusdAmountFromMint > price;

        if (!canExec) return (canExec, bytes("Not enough cUSD to mint"));

        execPayload = abi.encodeCall(this.harvestInterest, ());
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override onlyOwner { }
}
