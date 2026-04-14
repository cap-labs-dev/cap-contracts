// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Interface for TIP20 tokens
/// @author Tempo
/// @notice Interface for TIP20 tokens on Tempo blockchain
interface ITIP20 {
    // =========================================================================
    //                      ERC-20 standard functions
    // =========================================================================

    /// @notice Returns the name of the token
    /// @return The token name
    function name() external view returns (string memory);

    /// @notice Returns the symbol of the token
    /// @return The token symbol
    function symbol() external view returns (string memory);

    /// @notice Returns the number of decimals for the token
    /// @return Always returns 6 for TIP-20 tokens
    function decimals() external pure returns (uint8);

    /// @notice Returns the total amount of tokens in circulation
    /// @return The total supply of tokens
    function totalSupply() external view returns (uint256);

    /// @notice Returns the token balance of an account
    /// @param account The address to check the balance for
    /// @return The token balance of the account
    function balanceOf(address account) external view returns (uint256);

    /// @notice Transfers tokens from caller to recipient
    /// @param to The recipient address
    /// @param amount The amount of tokens to transfer
    /// @return True if successful
    function transfer(address to, uint256 amount) external returns (bool);

    /// @notice Returns the remaining allowance for a spender
    /// @param owner The token owner address
    /// @param spender The spender address
    /// @return The remaining allowance amount
    function allowance(address owner, address spender) external view returns (uint256);

    /// @notice Approves a spender to spend tokens on behalf of caller
    /// @param spender The address to approve
    /// @param amount The amount to approve
    /// @return True if successful
    function approve(address spender, uint256 amount) external returns (bool);

    /// @notice Transfers tokens from one address to another using allowance
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return True if successful
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Mints new tokens to an address (requires ISSUER_ROLE)
    /// @param to The recipient address
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burns tokens from caller's balance (requires ISSUER_ROLE)
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;

    // =========================================================================
    //                      TIP-20 extended functions
    // =========================================================================

    /// @notice Transfers tokens from caller to recipient with a memo
    /// @param to The recipient address
    /// @param amount The amount of tokens to transfer
    /// @param memo A 32-byte memo attached to the transfer
    function transferWithMemo(address to, uint256 amount, bytes32 memo) external;

    /// @notice Transfers tokens from one address to another with a memo using allowance
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @param memo A 32-byte memo attached to the transfer
    /// @return True if successful
    function transferFromWithMemo(address from, address to, uint256 amount, bytes32 memo) external returns (bool);

    /// @notice Mints new tokens to an address with a memo (requires ISSUER_ROLE)
    /// @param to The recipient address
    /// @param amount The amount of tokens to mint
    /// @param memo A 32-byte memo attached to the mint
    function mintWithMemo(address to, uint256 amount, bytes32 memo) external;

    /// @notice Burns tokens from caller's balance with a memo (requires ISSUER_ROLE)
    /// @param amount The amount of tokens to burn
    /// @param memo A 32-byte memo attached to the burn
    function burnWithMemo(uint256 amount, bytes32 memo) external;

    /// @notice Burns tokens from a blocked address (requires BURN_BLOCKED_ROLE)
    /// @param from The address to burn tokens from (must be unauthorized by transfer policy)
    /// @param amount The amount of tokens to burn
    function burnBlocked(address from, uint256 amount) external;

    /// @notice Returns the quote token used for DEX pairing
    /// @return The quote token address
    function quoteToken() external view returns (ITIP20);

    /// @notice Returns the next quote token staged for update
    /// @return The next quote token address (zero if none staged)
    function nextQuoteToken() external view returns (ITIP20);

    /// @notice Returns the currency identifier for this token
    /// @return The currency string
    function currency() external view returns (string memory);

    /// @notice Returns whether the token is currently paused
    /// @return True if paused, false otherwise
    function paused() external view returns (bool);

    /// @notice Returns the maximum supply cap for the token
    /// @return The supply cap (checked on mint operations)
    function supplyCap() external view returns (uint256);

    /// @notice Returns the current transfer policy ID from TIP-403 registry
    /// @return The transfer policy ID
    function transferPolicyId() external view returns (uint64);

    // =========================================================================
    //                            Admin Functions
    // =========================================================================

    /// @notice Pauses the contract, blocking transfers (requires PAUSE_ROLE)
    function pause() external;

    /// @notice Unpauses the contract, allowing transfers (requires UNPAUSE_ROLE)
    function unpause() external;

    /// @notice Changes the transfer policy ID (requires DEFAULT_ADMIN_ROLE)
    /// @param newPolicyId The new policy ID from TIP-403 registry
    /// @dev Validates that the policy exists using TIP403Registry.policyExists().
    /// Built-in policies (ID 0 = always-reject, ID 1 = always-allow) are always valid.
    /// For custom policies (ID >= 2), the policy must exist in the TIP-403 registry.
    /// Reverts with InvalidTransferPolicyId if the policy does not exist.
    function changeTransferPolicyId(uint64 newPolicyId) external;

    /// @notice Stages a new quote token for update (requires DEFAULT_ADMIN_ROLE)
    /// @param newQuoteToken The new quote token address
    function setNextQuoteToken(ITIP20 newQuoteToken) external;

    /// @notice Completes the quote token update process (requires DEFAULT_ADMIN_ROLE)
    function completeQuoteTokenUpdate() external;

    /// @notice Sets the maximum supply cap (requires DEFAULT_ADMIN_ROLE)
    /// @param newSupplyCap The new supply cap (cannot be less than current supply)
    function setSupplyCap(uint256 newSupplyCap) external;

    // =========================================================================
    //                            Role Management
    // =========================================================================

    /// @notice Returns the BURN_BLOCKED_ROLE constant
    /// @return keccak256("BURN_BLOCKED_ROLE")
    function BURN_BLOCKED_ROLE() external view returns (bytes32);

    /// @notice Returns the ISSUER_ROLE constant
    /// @return keccak256("ISSUER_ROLE")
    function ISSUER_ROLE() external view returns (bytes32);

    /// @notice Returns the PAUSE_ROLE constant
    /// @return keccak256("PAUSE_ROLE")
    function PAUSE_ROLE() external view returns (bytes32);

    /// @notice Returns the UNPAUSE_ROLE constant
    /// @return keccak256("UNPAUSE_ROLE")
    function UNPAUSE_ROLE() external view returns (bytes32);

    /// @notice Grants a role to an account (requires role admin)
    /// @param role The role to grant (keccak256 hash)
    /// @param account The account to grant the role to
    function grantRole(bytes32 role, address account) external;

    /// @notice Revokes a role from an account (requires role admin)
    /// @param role The role to revoke (keccak256 hash)
    /// @param account The account to revoke the role from
    function revokeRole(bytes32 role, address account) external;

    /// @notice Allows an account to remove a role from itself
    /// @param role The role to renounce (keccak256 hash)
    function renounceRole(bytes32 role) external;

    /// @notice Changes the admin role for a specific role (requires current role admin)
    /// @param role The role whose admin is being changed
    /// @param adminRole The new admin role
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external;

    // =========================================================================
    //                            System Functions
    // =========================================================================

    /// @notice System-level transfer function (restricted to precompiles)
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return True if successful
    function systemTransferFrom(address from, address to, uint256 amount) external returns (bool);

    /// @notice Pre-transaction fee transfer (restricted to precompiles)
    /// @param from The account to charge fees from
    /// @param amount The fee amount
    function transferFeePreTx(address from, uint256 amount) external;

    /// @notice Post-transaction fee handling (restricted to precompiles)
    /// @param to The account to refund
    /// @param refund The refund amount
    /// @param actualUsed The actual fee used
    function transferFeePostTx(address to, uint256 refund, uint256 actualUsed) external;

    // =========================================================================
    //                                Events
    // =========================================================================

    /// @notice Emitted when a new allowance is set by `owner` for `spender`
    /// @param owner The account granting the allowance
    /// @param spender The account being approved to spend tokens
    /// @param amount The new allowance amount
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    /// @notice Emitted when tokens are burned from an address
    /// @param from The address whose tokens were burned
    /// @param amount The amount of tokens that were burned
    event Burn(address indexed from, uint256 amount);

    /// @notice Emitted when tokens are burned from a blocked address
    /// @param from The blocked address whose tokens were burned
    /// @param amount The amount of tokens that were burned
    event BurnBlocked(address indexed from, uint256 amount);

    /// @notice Emitted when new tokens are minted to an address
    /// @param to The address receiving the minted tokens
    /// @param amount The amount of tokens that were minted
    event Mint(address indexed to, uint256 amount);

    /// @notice Emitted when a new quote token is staged for this token
    /// @param updater The account that staged the new quote token
    /// @param nextQuoteToken The quote token that has been staged
    event NextQuoteTokenSet(address indexed updater, ITIP20 indexed nextQuoteToken);

    /// @notice Emitted when the pause state of the token changes
    /// @param updater The account that changed the pause state
    /// @param isPaused The new pause state; true if paused, false if unpaused
    event PauseStateUpdate(address indexed updater, bool isPaused);

    /// @notice Emitted when the quote token update process is completed
    /// @param updater The account that completed the quote token update
    /// @param newQuoteToken The new quote token that has been set
    event QuoteTokenUpdate(address indexed updater, ITIP20 indexed newQuoteToken);

    /// @notice Emitted when a holder sets or updates their reward recipient address
    /// @param holder The token holder configuring the recipient
    /// @param recipient The address that will receive claimed rewards
    event RewardRecipientSet(address indexed holder, address indexed recipient);

    /// @notice Emitted when a reward distribution is scheduled
    /// @param funder The account funding the reward distribution
    /// @param amount The total amount of tokens allocated to the reward
    event RewardDistributed(address indexed funder, uint256 amount);

    /// @notice Emitted when the token's supply cap is updated
    /// @param updater The account that updated the supply cap
    /// @param newSupplyCap The new maximum total supply
    event SupplyCapUpdate(address indexed updater, uint256 indexed newSupplyCap);

    /// @notice Emitted for all token movements, including mints and burns
    /// @param from The address sending tokens (address(0) for mints)
    /// @param to The address receiving tokens (address(0) for burns)
    /// @param amount The amount of tokens transferred
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// @notice Emitted when the transfer policy ID is updated
    /// @param updater The account that updated the transfer policy
    /// @param newPolicyId The new transfer policy ID from the TIP-403 registry
    event TransferPolicyUpdate(address indexed updater, uint64 indexed newPolicyId);

    /// @notice Emitted when a transfer, mint, or burn is performed with an attached memo
    /// @param from The address sending tokens (address(0) for mints)
    /// @param to The address receiving tokens (address(0) for burns)
    /// @param amount The amount of tokens transferred
    /// @param memo The 32-byte memo associated with this movement
    event TransferWithMemo(address indexed from, address indexed to, uint256 amount, bytes32 indexed memo);

    /// @notice Emitted when the membership of a role changes for an account
    /// @param role The role being granted or revoked
    /// @param account The account whose membership was changed
    /// @param sender The account that performed the change
    /// @param hasRole True if the role was granted, false if it was revoked
    event RoleMembershipUpdated(bytes32 indexed role, address indexed account, address indexed sender, bool hasRole);

    /// @notice Emitted when the admin role for a role is updated
    /// @param role The role whose admin role was changed
    /// @param newAdminRole The new admin role for the given role
    /// @param sender The account that performed the update
    event RoleAdminUpdated(bytes32 indexed role, bytes32 indexed newAdminRole, address indexed sender);

    // =========================================================================
    //                                Errors
    // =========================================================================

    /// @notice The token operation is blocked because the contract is currently paused
    error ContractPaused();

    /// @notice The spender does not have enough allowance for the attempted transfer
    error InsufficientAllowance();

    /// @notice The account does not have the required token balance for the operation
    /// @param currentBalance The current balance of the account
    /// @param expectedBalance The required balance for the operation to succeed
    /// @param token The address of the token contract
    error InsufficientBalance(uint256 currentBalance, uint256 expectedBalance, address token);

    /// @notice The provided amount is zero or otherwise invalid for the attempted operation
    error InvalidAmount();

    /// @notice The provided currency identifier is invalid or unsupported
    error InvalidCurrency();

    /// @notice The specified quote token is invalid, incompatible, or would create a circular reference
    error InvalidQuoteToken();

    /// @notice The recipient address is not a valid destination for this operation
    ///         (for example, another TIP-20 token contract)
    error InvalidRecipient();

    /// @notice The specified transfer policy ID does not exist in the TIP-403 registry
    error InvalidTransferPolicyId();

    /// @notice The new supply cap is invalid, for example lower than the current total supply
    error InvalidSupplyCap();

    /// @notice A rewards operation was attempted when no opted-in supply exists
    error NoOptedInSupply();

    /// @notice The configured transfer policy denies authorization for the sender or recipient
    error PolicyForbids();

    /// @notice The attempted operation would cause total supply to exceed the configured supply cap
    error SupplyCapExceeded();

    /// @notice The caller does not have the required role or permission for this operation
    error Unauthorized();
}
