// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title Fee Auction Interface
/// @author kexley, Cap Labs
/// @notice Interface for the FeeAuction contract
interface IFeeAuction {
    /// @dev Storage for the FeeAuction contract
    /// @param paymentToken Token used to pay for fees in the auction
    /// @param paymentRecipient Address that receives the payment tokens
    /// @param startPrice Starting price of the current auction in payment tokens
    /// @param startTimestamp Timestamp when the current auction started
    /// @param duration Duration of each auction in seconds
    /// @param minStartPrice Minimum allowed start price for future auctions
    struct FeeAuctionStorage {
        address paymentToken;
        address paymentRecipient;
        uint256 startPrice;
        uint256 startTimestamp;
        uint256 duration;
        uint256 minStartPrice;
    }

    /// @dev Buy fees
    event Buy(address buyer, uint256 price, address[] assets, uint256[] balances);

    /// @dev Set duration
    event SetDuration(uint256 duration);

    /// @dev Set minimum start price
    event SetMinStartPrice(uint256 minStartPrice);

    /// @dev Set payment token
    event SetPaymentToken(address paymentToken);

    /// @dev Set start price
    event SetStartPrice(uint256 startPrice);

    /// @dev Assets must be non-zero length and have matching lengths
    error InvalidAssets();

    /// @dev Deadline must be in the future
    error InvalidDeadline();

    /// @dev Payment token must be non-zero address
    error InvalidPaymentToken();

    /// @dev Price must be less than maximum price
    error InvalidPrice();

    /// @dev Receiver must be non-zero address
    error InvalidReceiver();

    /// @dev Start price must be greater than minimum start price
    error InvalidStartPrice();

    /// @dev Insufficient balance for asset
    error InsufficientBalance(address asset, uint256 balance, uint256 minAmount);

    /// @dev Minimum start price must be set
    error NoMinStartPrice();

    /// @dev Duration must be set
    error NoDuration();

    /// @notice Initialize the FeeAuction contract
    /// @param _accessControl Access control address
    /// @param _paymentToken Payment token address
    /// @param _paymentRecipient Payment recipient address
    /// @param _duration Duration of each auction in seconds
    /// @param _minStartPrice Minimum allowed start price for future auctions
    function initialize(
        address _accessControl,
        address _paymentToken,
        address _paymentRecipient,
        uint256 _duration,
        uint256 _minStartPrice
    ) external;

    /// @notice Buy fees in exchange for the payment token
    /// @dev Starts new auction where start price is double the settled price of this one
    /// @param _maxPrice Maximum price to pay
    /// @param _assets Assets to buy
    /// @param _minAmounts Minimum amounts to buy
    /// @param _receiver Receiver address for the assets
    /// @param _deadline Deadline for the auction
    function buy(
        uint256 _maxPrice,
        address[] calldata _assets,
        uint256[] calldata _minAmounts,
        address _receiver,
        uint256 _deadline
    ) external;

    /// @notice Set the start price of the current auction
    /// @param _startPrice New start price
    function setStartPrice(uint256 _startPrice) external;

    /// @notice Set the duration of future auctions
    /// @param _duration New duration
    function setDuration(uint256 _duration) external;

    /// @notice Set the minimum start price for future auctions
    /// @param _minStartPrice New minimum start price
    function setMinStartPrice(uint256 _minStartPrice) external;

    /// @notice Set the payment token
    /// @param _paymentToken New payment token
    function setPaymentToken(address _paymentToken) external;

    /// @notice Current price in the payment token, linearly decays toward 0 over time
    /// @return price Current price
    function currentPrice() external view returns (uint256 price);

    /// @notice Payment token
    /// @return token Payment token
    function paymentToken() external view returns (address token);

    /// @notice Payment recipient
    /// @return recipient Payment recipient
    function paymentRecipient() external view returns (address recipient);

    /// @notice Start price
    /// @return price Start price
    function startPrice() external view returns (uint256 price);

    /// @notice Start timestamp
    /// @return timestamp Start timestamp
    function startTimestamp() external view returns (uint256 timestamp);

    /// @notice Duration
    /// @return duration Duration
    function duration() external view returns (uint256 duration);

    /// @notice Minimum start price
    /// @return minStartPrice Minimum start price
    function minStartPrice() external view returns (uint256 minStartPrice);
}
