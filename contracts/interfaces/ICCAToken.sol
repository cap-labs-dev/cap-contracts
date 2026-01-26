// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title ICCAToken
/// @author kexley, Cap Labs
/// @notice Interface for CCA token
interface ICCAToken {
    /// @custom:storage-location erc7201:cap.storage.CCAToken
    /// @dev CCA token storage
    /// @param whitelist Whitelist of addresses
    /// @param zap Zap address
    /// @param asset Asset address
    struct CCATokenStorage {
        mapping(address => bool) whitelist;
        address zap;
        address asset;
    }

    /// @dev Asset not set yet
    error AssetNotSet();

    /// @dev Insufficient balance of the asset
    error InsufficientBalance();

    /// @dev Transfer not allowed
    error TransferNotAllowed();

    /// @dev Zap address cannot be whitelisted
    error ZapAddressCannotBeWhitelisted();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @dev Zero amount not valid
    error ZeroAmountNotValid();

    /// @dev Emitted when the CCA token is exchanged
    /// @param from Sender address
    /// @param to Receiver address
    /// @param amount Amount of tokens exchanged
    event Exchanged(address indexed from, address indexed to, uint256 amount);

    /// @dev Emitted when ERC20 tokens are recovered
    /// @param token Token address
    /// @param to Recipient address
    /// @param amount Amount of tokens recovered
    event RecoveredERC20(address indexed token, address indexed to, uint256 amount);

    /// @dev Emitted when the asset is set
    /// @param asset Asset address
    event SetAsset(address asset);

    /// @dev Emitted when the whitelist is set for a user to send CCA tokens
    /// @param user User address
    /// @param whitelisted Whitelist state
    event SetWhitelist(address indexed user, bool whitelisted);

    /// @notice Exchange the caller's full balance of CCA tokens for the asset when available
    /// @dev Left permissionless intentionally
    /// @param _to Receiver address
    function exchange(address _to) external;

    /// @notice Exchange the full balance of CCA tokens for the asset on behalf of another address when available
    /// @dev Spender must have allowance for the owner. Left permissionless intentionally
    /// @param _from Sender address
    /// @param _to Receiver address
    function exchangeFrom(address _from, address _to) external;

    /// @notice Initialize the CCA token
    /// @param _accessControl Access control address
    /// @param _zap Zap address
    /// @param _name Name of the token
    /// @param _symbol Symbol of the token
    function initialize(address _accessControl, address _zap, string memory _name, string memory _symbol) external;

    /// @notice Mint CCA tokens
    /// @param _to Receiver address
    /// @param _amount Amount of tokens to mint
    function mint(address _to, uint256 _amount) external;

    /// @notice Pause exchange functionality
    function pause() external;

    /// @notice Recover ERC20 tokens
    /// @param _token Token address
    /// @param _to Recipient address
    /// @param _amount Amount of tokens to recover
    function recoverERC20(address _token, address _to, uint256 _amount) external;

    /// @notice Set the asset address
    /// @param _asset Asset address
    function setAsset(address _asset) external;

    /// @notice Set the whitelist for a user to send CCA tokens
    /// @param _user User address
    /// @param _whitelisted Whitelist state
    function setWhitelist(address _user, bool _whitelisted) external;

    /// @notice Unpause exchange functionality
    function unpause() external;

    /// @notice Get the asset address
    /// @return assetAddress Asset address
    function asset() external view returns (address assetAddress);

    /// @notice Check if a user is whitelisted for sending CCA tokens
    /// @param _user User address
    /// @return isWhitelisted Whitelist state
    function whitelisted(address _user) external view returns (bool isWhitelisted);

    /// @notice Get the zap address
    /// @return zapAddress Zap address
    function zap() external view returns (address zapAddress);
}
