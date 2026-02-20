// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @title IStabledrop
/// @notice Interface for the stabledrop
/// @author kexley, Cap Labs
interface IStabledrop {
    /// @custom:storage-location erc7201:cap.storage.Stabledrop
    /// @dev Stabledrop storage
    /// @param root Merkle root
    /// @param token Token address
    /// @param approved Approved operators
    /// @param claimed Claimed amounts
    /// @param totalClaimed Total claimed amount
    struct StabledropStorage {
        bytes32 root;
        address token;
        mapping(address => mapping(address => bool)) approved;
        mapping(address => uint256) claimed;
        uint256 totalClaimed;
    }

    /// @notice Error thrown when the balance is insufficient
    error InsufficientBalance();

    /// @notice Error thrown when the proof is invalid
    error InvalidProof();

    /// @notice Error thrown when the nothing to claim
    error NothingToClaim();

    /// @notice Error thrown when the claimant is not the owner or approved operator
    error NotOwnerOrOperator();

    /// @notice Error thrown when the entered address is the zero address
    error ZeroAddressNotValid();

    /// @notice Event emitted when an operator is approved
    /// @param claimant The claimant of the stabledrop
    /// @param operator The operator of the stabledrop
    /// @param approved Approved state
    event ApproveOperator(address indexed claimant, address indexed operator, bool approved);

    /// @notice Event emitted when the stabledrop is claimed
    /// @param claimant The claimant of the stabledrop
    /// @param recipient The recipient of the stabledrop
    /// @param amount The amount of the stabledrop sent to the recipient
    event Claim(address indexed claimant, address indexed recipient, uint256 amount);

    /// @notice Event emitted when the stabledrop is funded
    /// @param amount The amount of the stabledrop
    event Fund(uint256 amount);

    /// @notice Event emitted when ERC20 tokens are recovered
    /// @param token The token recovered
    /// @param to Recipient address
    /// @param amount Amount of the token recovered
    event RecoverERC20(address indexed token, address indexed to, uint256 amount);

    /// @notice Event emitted when the root is set
    /// @param root The new root
    event SetRoot(bytes32 root);

    /// @notice Initialize the stabledrop
    /// @param _accessControl Access control address
    /// @param _root Merkle root
    /// @param _token Token address
    function initialize(address _accessControl, bytes32 _root, address _token) external;

    /// @notice Approve an operator to claim for the claimant
    /// @param _operator Operator address
    /// @param _approved Approved state
    function approveOperator(address _operator, bool _approved) external;

    /// @notice Permissioned function to approve an operator to claim for a specific claimant
    /// @param _claimant Claimant address
    /// @param _operator Operator address
    /// @param _approved Approved state
    function approveOperatorFor(address _claimant, address _operator, bool _approved) external;

    /// @notice Claim the stabledrop for the claimant and send to the recipient
    /// @dev Only the claimant or approved operators can claim
    /// @param _claimant Claimant address
    /// @param _recipient Recipient address
    /// @param _amount Amount of the stabledrop
    /// @param _proofs Proofs
    function claim(address _claimant, address _recipient, uint256 _amount, bytes32[] calldata _proofs) external;

    /// @notice Fund the stabledrop with the token
    /// @dev Caller must have approved the stabledrop to spend the token
    /// @param _amount Amount of the token to fund the stabledrop
    function fund(uint256 _amount) external;

    /// @notice Set the new Merkle root
    /// @param _root Merkle root
    function setRoot(bytes32 _root) external;

    /// @notice Recover ERC20 tokens
    /// @param _token The token to recover
    /// @param _to Recipient address
    /// @param _amount Amount of the token to recover
    function recoverERC20(address _token, address _to, uint256 _amount) external;

    /// @notice Pause the stabledrop
    function pause() external;

    /// @notice Unpause the stabledrop
    function unpause() external;

    /// @notice Get the approved state for an operator
    /// @param _claimant Claimant address
    /// @param _operator Operator address
    /// @return approved Approved state
    function approved(address _claimant, address _operator) external view returns (bool);

    /// @notice Get the claimed amount for a claimant
    /// @param _claimant Claimant address
    /// @return claimed Claimed amount
    function claimed(address _claimant) external view returns (uint256);

    /// @notice Get the root
    /// @return root Root
    function root() external view returns (bytes32);

    /// @notice Get the token address
    /// @return token Token address
    function token() external view returns (address);

    /// @notice Get the total claimed amount
    /// @return totalClaimed Total claimed amount
    function totalClaimed() external view returns (uint256);
}
