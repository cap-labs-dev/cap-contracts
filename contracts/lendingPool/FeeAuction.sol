// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { AccessUpgradeable } from "../access/AccessUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IAuctionCallback } from "../interfaces/IAuctionCallback.sol";

/// @title Fee Auction
/// @author kexley, @capLabs
/// @notice Fees are sold via a dutch auction
contract FeeAuction is UUPSUpgradeable, AccessUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:cap.storage.FeeAuction
    struct FeeAuctionStorage {
        address paymentToken;
        address paymentRecipient;
        uint256 startPrice;
        uint256 startTimestamp;
        uint256 duration;
        uint256 minStartPrice;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.FeeAuction")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FeeAuctionStorageLocation = 0xbbabf7dab1936c7afe15748adafbe56186d0b57f14b5bc3e6f8d57aad0236100;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getFeeAuctionStorage() private pure returns (FeeAuctionStorage storage $) {
        assembly {
            $.slot := FeeAuctionStorageLocation
        }
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @dev Duration must be set
    error NoDuration();

    /// @dev Buy fees
    event Buy(address buyer, uint256 price, address[] assets, uint256[] balances);

    /// @dev Set start price
    event SetStartPrice(uint256 startPrice);

    /// @dev Set duration
    event SetDuration(uint256 duration);

    /// @dev Set minimum start price
    event SetMinStartPrice(uint256 minStartPrice);

    /// @notice Initialize the fee auction
    /// @param _accessControl Access control address
    /// @param _paymentToken Payment token address
    /// @param _paymentRecipient Payment recipient address
    /// @param _duration Duration of auction in seconds
    /// @param _minStartPrice Minimum start price in payment token decimals
    function initialize(
        address _accessControl,
        address _paymentToken,
        address _paymentRecipient,
        uint256 _duration,
        uint256 _minStartPrice
    ) external initializer {
        __Access_init(_accessControl);

        FeeAuctionStorage storage $ = _getFeeAuctionStorage();
        $.paymentToken = _paymentToken;
        $.paymentRecipient = _paymentRecipient;
        $.startPrice = _minStartPrice;
        $.startTimestamp = block.timestamp;
        if (_duration == 0) revert NoDuration();
        $.duration = _duration;
        $.minStartPrice = _minStartPrice;
    }

    /// @notice Current price in the payment token, linearly decays toward 0 over time
    /// @return price Current price
    function currentPrice() public view returns (uint256 price) {
        FeeAuctionStorage storage $ = _getFeeAuctionStorage();
        uint256 elapsed = block.timestamp - $.startTimestamp;
        if (elapsed > $.duration) elapsed = $.duration;
        price = $.startPrice * (1e27 - (elapsed * 1e27 / $.duration)) / 1e27;
    }

    /// @notice Buy fees in exchange for the payment token
    /// @dev Starts new auction where start price is double the settled price of this one
    /// @param _assets Assets to buy
    /// @param _receiver Receiver address for the assets
    /// @param _callback Optional callback data
    function buy(
        address[] calldata _assets,
        address _receiver,
        bytes calldata _callback
    ) external {
        uint256 price = currentPrice();
        FeeAuctionStorage storage $ = _getFeeAuctionStorage();
        $.startTimestamp = block.timestamp;
        $.startPrice = price * 2 > $.minStartPrice ? price * 2 : $.minStartPrice;

        uint256[] memory balances = _transferOutAssets(_assets, _receiver);

        IAuctionCallback(msg.sender).auctionCallback(_assets, balances, price, _callback);

        IERC20($.paymentToken).safeTransferFrom(msg.sender, $.paymentRecipient, price);

        emit Buy(msg.sender, price, _assets, balances);
    }

    /// @notice Set the start price of the current auction
    /// @dev This will affect the current price, use with caution
    /// @param _startPrice New start price
    function setStartPrice(uint256 _startPrice) external checkAccess(this.setStartPrice.selector) {
        FeeAuctionStorage storage $ = _getFeeAuctionStorage();
        $.startPrice = _startPrice;
        emit SetStartPrice(_startPrice);
    }

    /// @notice Set duration of auctions
    /// @dev This will affect the current price, use with caution
    /// @param _duration New duration in seconds
    function setDuration(uint256 _duration) external checkAccess(this.setDuration.selector) {
        if (_duration == 0) revert NoDuration();
        FeeAuctionStorage storage $ = _getFeeAuctionStorage();
        $.duration = _duration;
        emit SetDuration(_duration);
    }

    /// @notice Set minimum start price
    /// @param _minStartPrice New minimum start price
    function setMinStartPrice(uint256 _minStartPrice) external checkAccess(this.setMinStartPrice.selector) {
        FeeAuctionStorage storage $ = _getFeeAuctionStorage();
        $.minStartPrice = _minStartPrice;
        emit SetMinStartPrice(_minStartPrice);
    }

    /// @dev Transfer all specified assets to the receiver from this address
    /// @param _assets Asset addresses
    /// @param _receiver Receiver address
    /// @return balances Balances transferred to receiver
    function _transferOutAssets(
        address[] calldata _assets,
        address _receiver
    ) internal returns (uint256[] memory balances) {
        uint256 assetsLength = _assets.length;
        for (uint256 i; i < assetsLength; ++i) {
            address asset = _assets[i];
            balances[i] = IERC20(asset).balanceOf(address(this));
            if (balances[i] > 0) IERC20(asset).safeTransfer(_receiver, balances[i]);
        }
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}