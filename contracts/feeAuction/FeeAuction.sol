// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Access } from "../access/Access.sol";

import { IFeeAuction } from "../interfaces/IFeeAuction.sol";
import { FeeAuctionStorageUtils } from "../storage/FeeAuctionStorageUtils.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20, SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Fee Auction
/// @author kexley, Cap Labs
/// @notice Fees are sold via a dutch auction
contract FeeAuction is IFeeAuction, UUPSUpgradeable, Access, FeeAuctionStorageUtils {
    using SafeERC20 for IERC20;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IFeeAuction
    function initialize(
        address _accessControl,
        address _paymentToken,
        address _paymentRecipient,
        uint256 _duration,
        uint256 _minStartPrice
    ) external initializer {
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();

        FeeAuctionStorage storage $ = getFeeAuctionStorage();
        $.paymentToken = _paymentToken;
        $.paymentRecipient = _paymentRecipient;
        $.startPrice = _minStartPrice;
        $.startTimestamp = block.timestamp;
        if (_duration == 0) revert NoDuration();
        $.duration = _duration;
        if (_minStartPrice == 0) revert NoMinStartPrice();
        $.minStartPrice = _minStartPrice;
    }

    /// @inheritdoc IFeeAuction
    function buy(
        uint256 _maxPrice,
        address[] calldata _assets,
        uint256[] calldata _minAmounts,
        address _receiver,
        uint256 _deadline
    ) external {
        uint256 price = currentPrice();
        if (price > _maxPrice) revert InvalidPrice();
        if (_assets.length == 0 || _assets.length != _minAmounts.length) revert InvalidAssets();
        if (_receiver == address(0)) revert InvalidReceiver();
        if (_deadline < block.timestamp) revert InvalidDeadline();

        FeeAuctionStorage storage $ = getFeeAuctionStorage();
        $.startTimestamp = block.timestamp;

        uint256 newStartPrice = price * 2;
        if (newStartPrice < $.minStartPrice) newStartPrice = $.minStartPrice;
        $.startPrice = newStartPrice;

        uint256[] memory balances = _transferOutAssets(_assets, _minAmounts, _receiver);

        IERC20($.paymentToken).safeTransferFrom(msg.sender, $.paymentRecipient, price);

        emit Buy(msg.sender, price, _assets, balances);
    }

    /// @inheritdoc IFeeAuction
    function setStartPrice(uint256 _startPrice) external checkAccess(this.setStartPrice.selector) {
        FeeAuctionStorage storage $ = getFeeAuctionStorage();
        if (_startPrice < $.minStartPrice) revert InvalidStartPrice();
        $.startPrice = _startPrice;
        emit SetStartPrice(_startPrice);
    }

    /// @inheritdoc IFeeAuction
    function setDuration(uint256 _duration) external checkAccess(this.setDuration.selector) {
        if (_duration == 0) revert NoDuration();
        FeeAuctionStorage storage $ = getFeeAuctionStorage();
        $.duration = _duration;
        emit SetDuration(_duration);
    }

    /// @inheritdoc IFeeAuction
    function setMinStartPrice(uint256 _minStartPrice) external checkAccess(this.setMinStartPrice.selector) {
        if (_minStartPrice == 0) revert NoMinStartPrice();
        FeeAuctionStorage storage $ = getFeeAuctionStorage();
        $.minStartPrice = _minStartPrice;
        emit SetMinStartPrice(_minStartPrice);
    }

    /// @inheritdoc IFeeAuction
    function currentPrice() public view returns (uint256 price) {
        FeeAuctionStorage storage $ = getFeeAuctionStorage();
        uint256 elapsed = block.timestamp - $.startTimestamp;
        if (elapsed > $.duration) elapsed = $.duration;
        price = $.startPrice * (1e27 - (elapsed * 0.9e27 / $.duration)) / 1e27;
    }

    /// @inheritdoc IFeeAuction
    function paymentToken() external view returns (address token) {
        token = getFeeAuctionStorage().paymentToken;
    }

    /// @inheritdoc IFeeAuction
    function paymentRecipient() external view returns (address recipient) {
        recipient = getFeeAuctionStorage().paymentRecipient;
    }

    /// @inheritdoc IFeeAuction
    function startPrice() external view returns (uint256 price) {
        price = getFeeAuctionStorage().startPrice;
    }

    /// @inheritdoc IFeeAuction
    function startTimestamp() external view returns (uint256 timestamp) {
        timestamp = getFeeAuctionStorage().startTimestamp;
    }

    /// @inheritdoc IFeeAuction
    function duration() external view returns (uint256 auctionDuration) {
        auctionDuration = getFeeAuctionStorage().duration;
    }

    /// @inheritdoc IFeeAuction
    function minStartPrice() external view returns (uint256 price) {
        price = getFeeAuctionStorage().minStartPrice;
    }

    /// @dev Transfer all specified assets to the receiver from this address
    /// @param _assets Asset addresses
    /// @param _minAmounts Minimum amounts to buy
    /// @param _receiver Receiver address
    /// @return balances Balances transferred to receiver
    function _transferOutAssets(address[] calldata _assets, uint256[] calldata _minAmounts, address _receiver)
        internal
        returns (uint256[] memory balances)
    {
        uint256 assetsLength = _assets.length;
        balances = new uint256[](assetsLength);
        for (uint256 i; i < assetsLength; ++i) {
            address asset = _assets[i];
            uint256 balance = IERC20(asset).balanceOf(address(this));
            balances[i] = balance;
            if (balance < _minAmounts[i]) revert InsufficientBalance(asset, balance, _minAmounts[i]);
            if (balance > 0) IERC20(asset).safeTransfer(_receiver, balance);
        }
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
