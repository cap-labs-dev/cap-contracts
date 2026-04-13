// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IStakedLBTCOracle
/// @notice Interface for a consortium-attested ratio oracle that publishes and tracks
///         exchange rates for a liquid-staking token via a notary consortium proof system.
interface IStakedLBTCOracle {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the denomination hash is zero during initialization or token detail set
    error Actions_ZeroDenom();

    /// @notice Thrown when the initial ratio is zero
    error Actions_ZeroRatio();

    /// @notice Thrown when the action selector in the payload does not match the expected one
    /// @param expected Expected 4-byte selector
    /// @param actual Actual 4-byte selector found in the payload
    error InvalidAction(bytes4 expected, bytes4 actual);

    /// @notice Thrown by the OZ Initializable when re-initialization is attempted
    error InvalidInitialization();

    /// @notice Thrown when the raw payload length does not match the expected size
    /// @param expected Expected byte length
    /// @param actual Actual byte length received
    error InvalidPayloadSize(uint256 expected, uint256 actual);

    /// @notice Thrown on multiplication/division overflow in fixed-point math
    error MathOverflowedMulDiv();

    /// @notice Thrown by the OZ Initializable when a function is called outside of initialization
    error NotInitializing();

    /// @notice Thrown when the provided owner address is the zero address
    /// @param owner The invalid owner address supplied
    error OwnableInvalidOwner(address owner);

    /// @notice Thrown when a non-owner account calls an owner-restricted function
    /// @param account The caller that is not the owner
    error OwnableUnauthorizedAccount(address account);

    /// @notice Thrown when `publishNewRatio` is called before the contract has been initialized
    error RatioInitializedAlready();

    /// @notice Thrown on reentrant calls
    error ReentrancyGuardReentrantCall();

    /// @notice Thrown when the new ratio deviates beyond the allowed threshold from the current ratio
    error TooBigRatioChange();

    /// @notice Thrown when the switch time embedded in the payload is invalid (e.g. in the past or too far ahead)
    error WrongRatioSwitchTime();

    /// @notice Thrown when a required address argument is the zero address
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when the OZ Initializable version is set
    /// @param version Initialization version number
    event Initialized(uint64 version);

    /// @notice Emitted when the notary consortium address is updated
    /// @param prevVal Previous consortium address
    /// @param newVal New consortium address
    event Oracle_ConsortiumChanged(address indexed prevVal, address indexed newVal);

    /// @notice Emitted when the maximum ahead-interval is updated
    /// @param prevVal Previous max ahead interval (in seconds)
    /// @param newVal New max ahead interval (in seconds)
    event Oracle_MaxAheadIntervalChanged(uint256 indexed prevVal, uint256 indexed newVal);

    /// @notice Emitted when a new ratio is successfully published
    /// @param prevVal Previous ratio value
    /// @param newVal New ratio value
    /// @param switchTime Timestamp at which the new ratio becomes active
    event Oracle_RatioChanged(uint256 prevVal, uint256 newVal, uint256 switchTime);

    /// @notice Emitted when the token and denomination details are set during initialization
    /// @param token Token address
    /// @param denom Denomination hash
    event Oracle_TokenDetailsSet(address indexed token, bytes32 indexed denom);

    /// @notice Emitted by OZ Ownable2Step when ownership transfer is initiated
    /// @param previousOwner Current owner initiating the transfer
    /// @param newOwner Nominated new owner
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted by OZ Ownable when ownership is transferred
    /// @param previousOwner Previous owner
    /// @param newOwner New owner
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the ratio change threshold is updated
    /// @param prevVal Previous threshold
    /// @param newVal New threshold
    event RatioThresholdUpdated(uint256 indexed prevVal, uint256 indexed newVal);

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    /// @notice Accept a pending 2-step ownership transfer
    function acceptOwnership() external;

    /// @notice Update the notary consortium address
    /// @param newVal New consortium contract address
    function changeConsortium(address newVal) external;

    /// @notice Update the maximum time ahead of the current timestamp that a switch time may be set
    /// @param newVal New maximum ahead interval in seconds
    function changeMaxAheadInterval(uint256 newVal) external;

    /// @notice Returns the notary consortium contract used to verify ratio proofs
    /// @return The INotaryConsortium contract address
    function consortium() external view returns (address);

    /// @notice Returns the denomination hash identifying the rate pair (e.g. keccak256("wstETH/ETH"))
    /// @return The bytes32 denomination hash
    function denomHash() external view returns (bytes32);

    /// @notice Returns the current ratio (equivalent to `ratio()` but follows the standard rate oracle interface)
    /// @return The current exchange rate
    function getRate() external view returns (uint256);

    /// @notice Initialize the contract (replaces constructor for upgradeable proxies)
    /// @param owner_            Initial owner address
    /// @param consortium_       Notary consortium contract address
    /// @param token_            Token whose ratio this oracle tracks
    /// @param denomHash_        Denomination hash for the rate pair
    /// @param ratio_            Initial ratio value
    /// @param switchTime_       Timestamp at which the initial ratio becomes active
    /// @param maxAheadInterval_ Maximum seconds ahead of now that a switch time may be scheduled
    function initialize(
        address owner_,
        address consortium_,
        address token_,
        bytes32 denomHash_,
        uint256 ratio_,
        uint256 switchTime_,
        uint256 maxAheadInterval_
    ) external;

    /// @notice Returns the maximum seconds ahead of the current block that a ratio switch time may be set
    /// @return The max ahead interval in seconds
    function maxAheadInterval() external view returns (uint256);

    /// @notice Returns the pending next ratio and its scheduled switch time
    /// @return nextRatioValue  The upcoming ratio value
    /// @return switchTime      The timestamp at which it becomes active
    function nextRatio() external view returns (uint256 nextRatioValue, uint256 switchTime);

    /// @notice Returns the current owner of the contract
    /// @return The owner address
    function owner() external view returns (address);

    /// @notice Returns the nominated pending owner (2-step transfer)
    /// @return The pending owner address
    function pendingOwner() external view returns (address);

    /// @notice Submit a consortium-attested ratio update
    /// @param rawPayload ABI-encoded action payload containing the new ratio and switch time
    /// @param proof      Consortium proof bytes authorizing the payload
    function publishNewRatio(bytes calldata rawPayload, bytes calldata proof) external;

    /// @notice Returns the current active ratio
    /// @return The current ratio
    function ratio() external view returns (uint256);

    /// @notice Returns the maximum allowed change between the current and new ratio (in basis points or similar unit)
    /// @return The ratio change threshold
    function ratioThreshold() external view returns (uint256);

    /// @notice Renounce ownership, leaving the contract without an owner
    function renounceOwnership() external;

    /// @notice Returns the token address whose exchange rate this oracle tracks
    /// @return The token address
    function token() external view returns (address);

    /// @notice Transfer ownership to a new address (2-step; new owner must call `acceptOwnership`)
    /// @param newOwner Nominated new owner
    function transferOwnership(address newOwner) external;

    /// @notice Update the maximum permitted ratio change threshold
    /// @param newThreshold New threshold value (uint32)
    function updateRatioThreshold(uint32 newThreshold) external;
}
