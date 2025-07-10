// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0 ^0.8.28;

// contracts/interfaces/ICapSymbioticVaultFactory.sol

interface ICapSymbioticVaultFactory {
    /// @notice Creates a new vault
    /// @param _owner The owner of the vault, will manage delegations and set deposit limits
    /// @param asset The asset of the vault
    /// @return vault The address of the new vault
    function createVault(address _owner, address asset) external returns (address vault, address stakerRewards);
}

// node_modules/@symbioticfi/core/src/interfaces/IVaultConfigurator.sol

interface IVaultConfigurator {
    /**
     * @notice Initial parameters needed for a vault with a delegator and a slasher deployment.
     * @param version entity's version to use
     * @param owner initial owner of the entity
     * @param vaultParams parameters for the vault initialization
     * @param delegatorIndex delegator's index of the implementation to deploy
     * @param delegatorParams parameters for the delegator initialization
     * @param withSlasher whether to deploy a slasher or not
     * @param slasherIndex slasher's index of the implementation to deploy (used only if withSlasher == true)
     * @param slasherParams parameters for the slasher initialization (used only if withSlasher == true)
     */
    struct InitParams {
        uint64 version;
        address owner;
        bytes vaultParams;
        uint64 delegatorIndex;
        bytes delegatorParams;
        bool withSlasher;
        uint64 slasherIndex;
        bytes slasherParams;
    }

    /**
     * @notice Get the vault factory's address.
     * @return address of the vault factory
     */
    function VAULT_FACTORY() external view returns (address);

    /**
     * @notice Get the delegator factory's address.
     * @return address of the delegator factory
     */
    function DELEGATOR_FACTORY() external view returns (address);

    /**
     * @notice Get the slasher factory's address.
     * @return address of the slasher factory
     */
    function SLASHER_FACTORY() external view returns (address);

    /**
     * @notice Create a new vault with a delegator and a slasher.
     * @param params initial parameters needed for a vault with a delegator and a slasher deployment
     * @return vault address of the vault
     * @return delegator address of the delegator
     * @return slasher address of the slasher
     */
    function create(InitParams calldata params) external returns (address vault, address delegator, address slasher);
}

// node_modules/@symbioticfi/core/src/interfaces/common/IEntity.sol

interface IEntity {
    error NotInitialized();

    /**
     * @notice Get the factory's address.
     * @return address of the factory
     */
    function FACTORY() external view returns (address);

    /**
     * @notice Get the entity's type.
     * @return type of the entity
     */
    function TYPE() external view returns (uint64);

    /**
     * @notice Initialize this entity contract by using a given data.
     * @param data some data to use
     */
    function initialize(bytes calldata data) external;
}

// node_modules/@symbioticfi/core/src/interfaces/common/IMigratableEntity.sol

interface IMigratableEntity {
    error AlreadyInitialized();
    error NotFactory();
    error NotInitialized();

    /**
     * @notice Get the factory's address.
     * @return address of the factory
     */
    function FACTORY() external view returns (address);

    /**
     * @notice Get the entity's version.
     * @return version of the entity
     * @dev Starts from 1.
     */
    function version() external view returns (uint64);

    /**
     * @notice Initialize this entity contract by using a given data and setting a particular version and owner.
     * @param initialVersion initial version of the entity
     * @param owner initial owner of the entity
     * @param data some data to use
     */
    function initialize(uint64 initialVersion, address owner, bytes calldata data) external;

    /**
     * @notice Migrate this entity to a particular newer version using a given data.
     * @param newVersion new version of the entity
     * @param data some data to use
     */
    function migrate(uint64 newVersion, bytes calldata data) external;
}

// node_modules/@symbioticfi/core/src/interfaces/common/IRegistry.sol

interface IRegistry {
    error EntityNotExist();

    /**
     * @notice Emitted when an entity is added.
     * @param entity address of the added entity
     */
    event AddEntity(address indexed entity);

    /**
     * @notice Get if a given address is an entity.
     * @param account address to check
     * @return if the given address is an entity
     */
    function isEntity(address account) external view returns (bool);

    /**
     * @notice Get a total number of entities.
     * @return total number of entities added
     */
    function totalEntities() external view returns (uint256);

    /**
     * @notice Get an entity given its index.
     * @param index index of the entity to get
     * @return address of the entity
     */
    function entity(uint256 index) external view returns (address);
}

// node_modules/@symbioticfi/core/src/interfaces/slasher/IBurner.sol

interface IBurner {
    /**
     * @notice Called when a slash happens.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param amount virtual amount of the collateral slashed
     * @param captureTimestamp time point when the stake was captured
     */
    function onSlash(bytes32 subnetwork, address operator, uint256 amount, uint48 captureTimestamp) external;
}

// node_modules/@symbioticfi/core/src/interfaces/vault/IVaultStorage.sol

interface IVaultStorage {
    error InvalidTimestamp();
    error NoPreviousEpoch();

    /**
     * @notice Get a deposit whitelist enabler/disabler's role.
     * @return identifier of the whitelist enabler/disabler role
     */
    function DEPOSIT_WHITELIST_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get a depositor whitelist status setter's role.
     * @return identifier of the depositor whitelist status setter role
     */
    function DEPOSITOR_WHITELIST_ROLE() external view returns (bytes32);

    /**
     * @notice Get a deposit limit enabler/disabler's role.
     * @return identifier of the deposit limit enabler/disabler role
     */
    function IS_DEPOSIT_LIMIT_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get a deposit limit setter's role.
     * @return identifier of the deposit limit setter role
     */
    function DEPOSIT_LIMIT_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get the delegator factory's address.
     * @return address of the delegator factory
     */
    function DELEGATOR_FACTORY() external view returns (address);

    /**
     * @notice Get the slasher factory's address.
     * @return address of the slasher factory
     */
    function SLASHER_FACTORY() external view returns (address);

    /**
     * @notice Get a vault collateral.
     * @return address of the underlying collateral
     */
    function collateral() external view returns (address);

    /**
     * @notice Get a burner to issue debt to (e.g., 0xdEaD or some unwrapper contract).
     * @return address of the burner
     */
    function burner() external view returns (address);

    /**
     * @notice Get a delegator (it delegates the vault's stake to networks and operators).
     * @return address of the delegator
     */
    function delegator() external view returns (address);

    /**
     * @notice Get if the delegator is initialized.
     * @return if the delegator is initialized
     */
    function isDelegatorInitialized() external view returns (bool);

    /**
     * @notice Get a slasher (it provides networks a slashing mechanism).
     * @return address of the slasher
     */
    function slasher() external view returns (address);

    /**
     * @notice Get if the slasher is initialized.
     * @return if the slasher is initialized
     */
    function isSlasherInitialized() external view returns (bool);

    /**
     * @notice Get a time point of the epoch duration set.
     * @return time point of the epoch duration set
     */
    function epochDurationInit() external view returns (uint48);

    /**
     * @notice Get a duration of the vault epoch.
     * @return duration of the epoch
     */
    function epochDuration() external view returns (uint48);

    /**
     * @notice Get an epoch at a given timestamp.
     * @param timestamp time point to get the epoch at
     * @return epoch at the timestamp
     * @dev Reverts if the timestamp is less than the start of the epoch 0.
     */
    function epochAt(uint48 timestamp) external view returns (uint256);

    /**
     * @notice Get a current vault epoch.
     * @return current epoch
     */
    function currentEpoch() external view returns (uint256);

    /**
     * @notice Get a start of the current vault epoch.
     * @return start of the current epoch
     */
    function currentEpochStart() external view returns (uint48);

    /**
     * @notice Get a start of the previous vault epoch.
     * @return start of the previous epoch
     * @dev Reverts if the current epoch is 0.
     */
    function previousEpochStart() external view returns (uint48);

    /**
     * @notice Get a start of the next vault epoch.
     * @return start of the next epoch
     */
    function nextEpochStart() external view returns (uint48);

    /**
     * @notice Get if the deposit whitelist is enabled.
     * @return if the deposit whitelist is enabled
     */
    function depositWhitelist() external view returns (bool);

    /**
     * @notice Get if a given account is whitelisted as a depositor.
     * @param account address to check
     * @return if the account is whitelisted as a depositor
     */
    function isDepositorWhitelisted(address account) external view returns (bool);

    /**
     * @notice Get if the deposit limit is set.
     * @return if the deposit limit is set
     */
    function isDepositLimit() external view returns (bool);

    /**
     * @notice Get a deposit limit (maximum amount of the active stake that can be in the vault simultaneously).
     * @return deposit limit
     */
    function depositLimit() external view returns (uint256);

    /**
     * @notice Get a total number of active shares in the vault at a given timestamp using a hint.
     * @param timestamp time point to get the total number of active shares at
     * @param hint hint for the checkpoint index
     * @return total number of active shares at the timestamp
     */
    function activeSharesAt(uint48 timestamp, bytes memory hint) external view returns (uint256);

    /**
     * @notice Get a total number of active shares in the vault.
     * @return total number of active shares
     */
    function activeShares() external view returns (uint256);

    /**
     * @notice Get a total amount of active stake in the vault at a given timestamp using a hint.
     * @param timestamp time point to get the total active stake at
     * @param hint hint for the checkpoint index
     * @return total amount of active stake at the timestamp
     */
    function activeStakeAt(uint48 timestamp, bytes memory hint) external view returns (uint256);

    /**
     * @notice Get a total amount of active stake in the vault.
     * @return total amount of active stake
     */
    function activeStake() external view returns (uint256);

    /**
     * @notice Get a total number of active shares for a particular account at a given timestamp using a hint.
     * @param account account to get the number of active shares for
     * @param timestamp time point to get the number of active shares for the account at
     * @param hint hint for the checkpoint index
     * @return number of active shares for the account at the timestamp
     */
    function activeSharesOfAt(address account, uint48 timestamp, bytes memory hint) external view returns (uint256);

    /**
     * @notice Get a number of active shares for a particular account.
     * @param account account to get the number of active shares for
     * @return number of active shares for the account
     */
    function activeSharesOf(address account) external view returns (uint256);

    /**
     * @notice Get a total amount of the withdrawals at a given epoch.
     * @param epoch epoch to get the total amount of the withdrawals at
     * @return total amount of the withdrawals at the epoch
     */
    function withdrawals(uint256 epoch) external view returns (uint256);

    /**
     * @notice Get a total number of withdrawal shares at a given epoch.
     * @param epoch epoch to get the total number of withdrawal shares at
     * @return total number of withdrawal shares at the epoch
     */
    function withdrawalShares(uint256 epoch) external view returns (uint256);

    /**
     * @notice Get a number of withdrawal shares for a particular account at a given epoch (zero if claimed).
     * @param epoch epoch to get the number of withdrawal shares for the account at
     * @param account account to get the number of withdrawal shares for
     * @return number of withdrawal shares for the account at the epoch
     */
    function withdrawalSharesOf(uint256 epoch, address account) external view returns (uint256);

    /**
     * @notice Get if the withdrawals are claimed for a particular account at a given epoch.
     * @param epoch epoch to check the withdrawals for the account at
     * @param account account to check the withdrawals for
     * @return if the withdrawals are claimed for the account at the epoch
     */
    function isWithdrawalsClaimed(uint256 epoch, address account) external view returns (bool);
}

// node_modules/@symbioticfi/rewards/src/interfaces/stakerRewards/IStakerRewards.sol

interface IStakerRewards {
    /**
     * @notice Emitted when a reward is distributed.
     * @param network network on behalf of which the reward is distributed
     * @param token address of the token
     * @param amount amount of tokens
     * @param data some used data
     */
    event DistributeRewards(address indexed network, address indexed token, uint256 amount, bytes data);

    /**
     * @notice Get a version of the staker rewards contract (different versions mean different interfaces).
     * @return version of the staker rewards contract
     * @dev Must return 1 for this one.
     */
    function version() external view returns (uint64);

    /**
     * @notice Get an amount of rewards claimable by a particular account of a given token.
     * @param token address of the token
     * @param account address of the claimer
     * @param data some data to use
     * @return amount of claimable tokens
     */
    function claimable(address token, address account, bytes calldata data) external view returns (uint256);

    /**
     * @notice Distribute rewards on behalf of a particular network using a given token.
     * @param network network on behalf of which the reward to distribute
     * @param token address of the token
     * @param amount amount of tokens
     * @param data some data to use
     */
    function distributeRewards(address network, address token, uint256 amount, bytes calldata data) external;

    /**
     * @notice Claim rewards using a given token.
     * @param recipient address of the tokens' recipient
     * @param token address of the token
     * @param data some data to use
     */
    function claimRewards(address recipient, address token, bytes calldata data) external;
}

// node_modules/@symbioticfi/burners/src/interfaces/router/IBurnerRouter.sol

interface IBurnerRouter is IBurner {
    error AlreadySet();
    error DuplicateNetworkReceiver();
    error DuplicateOperatorNetworkReceiver();
    error InsufficientBalance();
    error InvalidCollateral();
    error InvalidReceiver();
    error InvalidReceiverSetEpochsDelay();
    error NotReady();

    /**
     * @notice Structure for a value of `address` type.
     * @param value value of `address` type
     */
    struct Address {
        address value;
    }

    /**
     * @notice Structure for a pending value of `address` type.
     * @param value pending value of `address` type
     * @param timestamp timestamp since which the pending value can be used
     */
    struct PendingAddress {
        address value;
        uint48 timestamp;
    }

    /**
     * @notice Structure for a value of `uint48` type.
     * @param value value of `uint48` type
     */
    struct Uint48 {
        uint48 value;
    }

    /**
     * @notice Structure for a pending value of `uint48` type.
     * @param value pending value of `uint48` type
     * @param timestamp timestamp since which the pending value can be used
     */
    struct PendingUint48 {
        uint48 value;
        uint48 timestamp;
    }

    /**
     * @notice Structure used to set a `receiver` for a slashing `network`.
     * @param network address of the slashing network
     * @param receiver address of the recipient of the slashed funds
     */
    struct NetworkReceiver {
        address network;
        address receiver;
    }

    /**
     * @notice Structure used to set a `receiver` for a slashed `operator` by a slashing `network`.
     * @param network address of the slashing network
     * @param operator address of the slashed operator
     * @param receiver address of the recipient of the slashed funds
     */
    struct OperatorNetworkReceiver {
        address network;
        address operator;
        address receiver;
    }

    /**
     * @notice Initial parameters needed for a router deployment.
     * @param owner manager of the router's receivers
     * @param collateral router's underlying collateral (MUST be the same as the vault's underlying collateral)
     * @param delay delay for setting a new receiver or changing the delay itself (in seconds)
     * @param globalReceiver address of the global receiver of the slashed funds (if no receiver is set for a network or operator)
     * @param networkReceivers array of network receivers to set on deployment (network => receiver)
     * @param operatorNetworkReceivers array of operator network receivers to set on deployment (network-operator => receiver)
     */
    struct InitParams {
        address owner;
        address collateral;
        uint48 delay;
        address globalReceiver;
        NetworkReceiver[] networkReceivers;
        OperatorNetworkReceiver[] operatorNetworkReceivers;
    }

    /**
     * @notice Emitted when a transfer from the router to the receiver is triggered.
     * @param receiver address of the receiver
     * @param amount amount of the transfer
     */
    event TriggerTransfer(address indexed receiver, uint256 amount);

    /**
     * @notice Emitted when a global receiver is set (becomes pending for a `delay`).
     * @param receiver address of the receiver
     */
    event SetGlobalReceiver(address receiver);

    /**
     * @notice Emitted when a pending global receiver is accepted.
     */
    event AcceptGlobalReceiver();

    /**
     * @notice Emitted when a network receiver is set (becomes pending for a `delay`).
     * @param network address of the network
     * @param receiver address of the receiver
     */
    event SetNetworkReceiver(address indexed network, address receiver);

    /**
     * @notice Emitted when a pending network receiver is accepted.
     * @param network address of the network
     */
    event AcceptNetworkReceiver(address indexed network);

    /**
     * @notice Emitted when an operator network receiver is set (becomes pending for a `delay`).
     * @param network address of the network
     * @param operator address of the operator
     * @param receiver address of the receiver
     */
    event SetOperatorNetworkReceiver(address indexed network, address indexed operator, address receiver);

    /**
     * @notice Emitted when a pending operator network receiver is accepted.
     * @param network address of the network
     * @param operator address of the operator
     */
    event AcceptOperatorNetworkReceiver(address indexed network, address indexed operator);

    /**
     * @notice Emitted when a delay is set (becomes pending for a `delay`).
     * @param delay new delay
     */
    event SetDelay(uint48 delay);

    /**
     * @notice Emitted when a pending delay is accepted.
     */
    event AcceptDelay();

    /**
     * @notice Get a router collateral.
     * @return address of the underlying collateral
     */
    function collateral() external view returns (address);

    /**
     * @notice Get a router last checked balance.
     * @return last balance of the router
     */
    function lastBalance() external view returns (uint256);

    /**
     * @notice Get a router delay.
     * @return delay for setting a new receiver or changing the delay itself (in seconds)
     */
    function delay() external view returns (uint48);

    /**
     * @notice Get a router pending delay.
     * @return value pending delay
     * @return timestamp timestamp since which the pending delay can be used
     */
    function pendingDelay() external view returns (uint48, uint48);

    /**
     * @notice Get a router global receiver.
     * @return address of the global receiver of the slashed funds
     */
    function globalReceiver() external view returns (address);

    /**
     * @notice Get a router pending global receiver.
     * @return value pending global receiver
     * @return timestamp timestamp since which the pending global receiver can be used
     */
    function pendingGlobalReceiver() external view returns (address, uint48);

    /**
     * @notice Get a router receiver for a slashing network.
     * @param network address of the slashing network
     * @return address of the receiver
     */
    function networkReceiver(address network) external view returns (address);

    /**
     * @notice Get a router pending receiver for a slashing network.
     * @param network address of the slashing network
     * @return value pending receiver
     * @return timestamp timestamp since which the pending receiver can be used
     */
    function pendingNetworkReceiver(address network) external view returns (address, uint48);

    /**
     * @notice Get a router receiver for a slashed operator by a slashing network.
     * @param network address of the slashing network
     * @param operator address of the slashed operator
     * @return address of the receiver
     */
    function operatorNetworkReceiver(address network, address operator) external view returns (address);

    /**
     * @notice Get a router pending receiver for a slashed operator by a slashing network.
     * @param network address of the slashing network
     * @param operator address of the slashed operator
     * @return value pending receiver
     * @return timestamp timestamp since which the pending receiver can be used
     */
    function pendingOperatorNetworkReceiver(address network, address operator)
        external
        view
        returns (address, uint48);

    /**
     * @notice Get a receiver balance of unclaimed collateral.
     * @param receiver address of the receiver
     * @return amount of the unclaimed collateral tokens
     */
    function balanceOf(address receiver) external view returns (uint256);

    /**
     * @notice Trigger a transfer of the unclaimed collateral to the receiver.
     * @param receiver address of the receiver
     * @return amount of the transfer
     */
    function triggerTransfer(address receiver) external returns (uint256 amount);

    /**
     * @notice Set a new global receiver of the slashed funds.
     * @param receiver address of the new receiver
     */
    function setGlobalReceiver(address receiver) external;

    /**
     * @notice Accept a pending global receiver.
     */
    function acceptGlobalReceiver() external;

    /**
     * @notice Set a new receiver for a slashing network.
     * @param network address of the slashing network
     * @param receiver address of the new receiver
     */
    function setNetworkReceiver(address network, address receiver) external;

    /**
     * @notice Accept a pending receiver for a slashing network.
     * @param network address of the slashing network
     */
    function acceptNetworkReceiver(address network) external;

    /**
     * @notice Set a new receiver for a slashed operator by a slashing network.
     * @param network address of the slashing network
     * @param operator address of the slashed operator
     * @param receiver address of the new receiver
     */
    function setOperatorNetworkReceiver(address network, address operator, address receiver) external;

    /**
     * @notice Accept a pending receiver for a slashed operator by a slashing network.
     * @param network address of the slashing network
     * @param operator address of the slashed operator
     */
    function acceptOperatorNetworkReceiver(address network, address operator) external;

    /**
     * @notice Set a new delay for setting a new receiver or changing the delay itself.
     * @param newDelay new delay (in seconds)
     */
    function setDelay(uint48 newDelay) external;

    /**
     * @notice Accept a pending delay.
     */
    function acceptDelay() external;
}

// node_modules/@symbioticfi/core/src/interfaces/delegator/IBaseDelegator.sol

interface IBaseDelegator is IEntity {
    error AlreadySet();
    error InsufficientHookGas();
    error NotNetwork();
    error NotSlasher();
    error NotVault();

    /**
     * @notice Base parameters needed for delegators' deployment.
     * @param defaultAdminRoleHolder address of the initial DEFAULT_ADMIN_ROLE holder
     * @param hook address of the hook contract
     * @param hookSetRoleHolder address of the initial HOOK_SET_ROLE holder
     */
    struct BaseParams {
        address defaultAdminRoleHolder;
        address hook;
        address hookSetRoleHolder;
    }

    /**
     * @notice Base hints for a stake.
     * @param operatorVaultOptInHint hint for the operator-vault opt-in
     * @param operatorNetworkOptInHint hint for the operator-network opt-in
     */
    struct StakeBaseHints {
        bytes operatorVaultOptInHint;
        bytes operatorNetworkOptInHint;
    }

    /**
     * @notice Emitted when a subnetwork's maximum limit is set.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param amount new maximum subnetwork's limit (how much stake the subnetwork is ready to get)
     */
    event SetMaxNetworkLimit(bytes32 indexed subnetwork, uint256 amount);

    /**
     * @notice Emitted when a slash happens.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param amount amount of the collateral to be slashed
     * @param captureTimestamp time point when the stake was captured
     */
    event OnSlash(bytes32 indexed subnetwork, address indexed operator, uint256 amount, uint48 captureTimestamp);

    /**
     * @notice Emitted when a hook is set.
     * @param hook address of the hook
     */
    event SetHook(address indexed hook);

    /**
     * @notice Get a version of the delegator (different versions mean different interfaces).
     * @return version of the delegator
     * @dev Must return 1 for this one.
     */
    function VERSION() external view returns (uint64);

    /**
     * @notice Get the network registry's address.
     * @return address of the network registry
     */
    function NETWORK_REGISTRY() external view returns (address);

    /**
     * @notice Get the vault factory's address.
     * @return address of the vault factory
     */
    function VAULT_FACTORY() external view returns (address);

    /**
     * @notice Get the operator-vault opt-in service's address.
     * @return address of the operator-vault opt-in service
     */
    function OPERATOR_VAULT_OPT_IN_SERVICE() external view returns (address);

    /**
     * @notice Get the operator-network opt-in service's address.
     * @return address of the operator-network opt-in service
     */
    function OPERATOR_NETWORK_OPT_IN_SERVICE() external view returns (address);

    /**
     * @notice Get a gas limit for the hook.
     * @return value of the hook gas limit
     */
    function HOOK_GAS_LIMIT() external view returns (uint256);

    /**
     * @notice Get a reserve gas between the gas limit check and the hook's execution.
     * @return value of the reserve gas
     */
    function HOOK_RESERVE() external view returns (uint256);

    /**
     * @notice Get a hook setter's role.
     * @return identifier of the hook setter role
     */
    function HOOK_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get the vault's address.
     * @return address of the vault
     */
    function vault() external view returns (address);

    /**
     * @notice Get the hook's address.
     * @return address of the hook
     * @dev The hook can have arbitrary logic under certain functions, however, it doesn't affect the stake guarantees.
     */
    function hook() external view returns (address);

    /**
     * @notice Get a particular subnetwork's maximum limit
     *         (meaning the subnetwork is not ready to get more as a stake).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @return maximum limit of the subnetwork
     */
    function maxNetworkLimit(bytes32 subnetwork) external view returns (uint256);

    /**
     * @notice Get a stake that a given subnetwork could be able to slash for a certain operator at a given timestamp
     *         until the end of the consequent epoch using hints (if no cross-slashing and no slashings by the subnetwork).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param timestamp time point to capture the stake at
     * @param hints hints for the checkpoints' indexes
     * @return slashable stake at the given timestamp until the end of the consequent epoch
     * @dev Warning: it is not safe to use timestamp >= current one for the stake capturing, as it can change later.
     */
    function stakeAt(bytes32 subnetwork, address operator, uint48 timestamp, bytes memory hints)
        external
        view
        returns (uint256);

    /**
     * @notice Get a stake that a given subnetwork will be able to slash
     *         for a certain operator until the end of the next epoch (if no cross-slashing and no slashings by the subnetwork).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @return slashable stake until the end of the next epoch
     * @dev Warning: this function is not safe to use for stake capturing, as it can change by the end of the block.
     */
    function stake(bytes32 subnetwork, address operator) external view returns (uint256);

    /**
     * @notice Set a maximum limit for a subnetwork (how much stake the subnetwork is ready to get).
     * identifier identifier of the subnetwork
     * @param amount new maximum subnetwork's limit
     * @dev Only a network can call this function.
     */
    function setMaxNetworkLimit(uint96 identifier, uint256 amount) external;

    /**
     * @notice Set a new hook.
     * @param hook address of the hook
     * @dev Only a HOOK_SET_ROLE holder can call this function.
     *      The hook can have arbitrary logic under certain functions, however, it doesn't affect the stake guarantees.
     */
    function setHook(address hook) external;

    /**
     * @notice Called when a slash happens.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param amount amount of the collateral slashed
     * @param captureTimestamp time point when the stake was captured
     * @param data some additional data
     * @dev Only the vault's slasher can call this function.
     */
    function onSlash(bytes32 subnetwork, address operator, uint256 amount, uint48 captureTimestamp, bytes calldata data)
        external;
}

// node_modules/@symbioticfi/core/src/interfaces/slasher/IBaseSlasher.sol

interface IBaseSlasher is IEntity {
    error NoBurner();
    error InsufficientBurnerGas();
    error NotNetworkMiddleware();
    error NotVault();

    /**
     * @notice Base parameters needed for slashers' deployment.
     * @param isBurnerHook if the burner is needed to be called on a slashing
     */
    struct BaseParams {
        bool isBurnerHook;
    }

    /**
     * @notice Hints for a slashable stake.
     * @param stakeHints hints for the stake checkpoints
     * @param cumulativeSlashFromHint hint for the cumulative slash amount at a capture timestamp
     */
    struct SlashableStakeHints {
        bytes stakeHints;
        bytes cumulativeSlashFromHint;
    }

    /**
     * @notice General data for the delegator.
     * @param slasherType type of the slasher
     * @param data slasher-dependent data for the delegator
     */
    struct GeneralDelegatorData {
        uint64 slasherType;
        bytes data;
    }

    /**
     * @notice Get a gas limit for the burner.
     * @return value of the burner gas limit
     */
    function BURNER_GAS_LIMIT() external view returns (uint256);

    /**
     * @notice Get a reserve gas between the gas limit check and the burner's execution.
     * @return value of the reserve gas
     */
    function BURNER_RESERVE() external view returns (uint256);

    /**
     * @notice Get the vault factory's address.
     * @return address of the vault factory
     */
    function VAULT_FACTORY() external view returns (address);

    /**
     * @notice Get the network middleware service's address.
     * @return address of the network middleware service
     */
    function NETWORK_MIDDLEWARE_SERVICE() external view returns (address);

    /**
     * @notice Get the vault's address.
     * @return address of the vault to perform slashings on
     */
    function vault() external view returns (address);

    /**
     * @notice Get if the burner is needed to be called on a slashing.
     * @return if the burner is a hook
     */
    function isBurnerHook() external view returns (bool);

    /**
     * @notice Get the latest capture timestamp that was slashed on a subnetwork.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @return latest capture timestamp that was slashed
     */
    function latestSlashedCaptureTimestamp(bytes32 subnetwork, address operator) external view returns (uint48);

    /**
     * @notice Get a cumulative slash amount for an operator on a subnetwork until a given timestamp (inclusively) using a hint.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param timestamp time point to get the cumulative slash amount until (inclusively)
     * @param hint hint for the checkpoint index
     * @return cumulative slash amount until the given timestamp (inclusively)
     */
    function cumulativeSlashAt(bytes32 subnetwork, address operator, uint48 timestamp, bytes memory hint)
        external
        view
        returns (uint256);

    /**
     * @notice Get a cumulative slash amount for an operator on a subnetwork.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @return cumulative slash amount
     */
    function cumulativeSlash(bytes32 subnetwork, address operator) external view returns (uint256);

    /**
     * @notice Get a slashable amount of a stake got at a given capture timestamp using hints.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param captureTimestamp time point to get the stake amount at
     * @param hints hints for the checkpoints' indexes
     * @return slashable amount of the stake
     */
    function slashableStake(bytes32 subnetwork, address operator, uint48 captureTimestamp, bytes memory hints)
        external
        view
        returns (uint256);
}

// node_modules/@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewards.sol

interface IDefaultStakerRewards is IStakerRewards {
    error AlreadySet();
    error HighAdminFee();
    error InsufficientAdminFee();
    error InsufficientReward();
    error InvalidAdminFee();
    error InvalidHintsLength();
    error InvalidRecipient();
    error InvalidRewardTimestamp();
    error MissingRoles();
    error NoRewardsToClaim();
    error NotNetwork();
    error NotNetworkMiddleware();
    error NotVault();

    /**
     * @notice Initial parameters needed for a staker rewards contract deployment.
     * @param vault address of the vault to get stakers' data from
     * @param adminFee admin fee (up to ADMIN_FEE_BASE inclusively)
     * @param defaultAdminRoleHolder address of the initial DEFAULT_ADMIN_ROLE holder
     * @param adminFeeClaimRoleHolder address of the initial ADMIN_FEE_CLAIM_ROLE holder
     * @param adminFeeSetRoleHolder address of the initial ADMIN_FEE_SET_ROLE holder
     */
    struct InitParams {
        address vault;
        uint256 adminFee;
        address defaultAdminRoleHolder;
        address adminFeeClaimRoleHolder;
        address adminFeeSetRoleHolder;
    }

    /**
     * @notice Structure for a reward distribution.
     * @param amount amount of tokens to be distributed (admin fee is excluded)
     * @param timestamp time point stakes must taken into account at
     */
    struct RewardDistribution {
        uint256 amount;
        uint48 timestamp;
    }

    /**
     * @notice Emitted when rewards are claimed.
     * @param token address of the token claimed
     * @param network address of the network
     * @param claimer account that claimed the reward
     * @param recipient account that received the reward
     * @param firstRewardIndex first index of the claimed rewards
     * @param numRewards number of rewards claimed
     * @param amount amount of tokens claimed
     */
    event ClaimRewards(
        address indexed token,
        address indexed network,
        address indexed claimer,
        address recipient,
        uint256 firstRewardIndex,
        uint256 numRewards,
        uint256 amount
    );

    /**
     * @notice Emitted when an admin fee is claimed.
     * @param recipient account that received the fee
     * @param amount amount of the fee claimed
     */
    event ClaimAdminFee(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when an admin fee is set.
     * @param adminFee admin fee
     */
    event SetAdminFee(uint256 adminFee);

    /**
     * @notice Get the maximum admin fee (= 100%).
     * @return maximum admin fee
     */
    function ADMIN_FEE_BASE() external view returns (uint256);

    /**
     * @notice Get the admin fee claimer's role.
     * @return identifier of the admin fee claimer role
     */
    function ADMIN_FEE_CLAIM_ROLE() external view returns (bytes32);

    /**
     * @notice Get the admin fee setter's role.
     * @return identifier of the admin fee setter role
     */
    function ADMIN_FEE_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get the vault factory's address.
     * @return address of the vault factory
     */
    function VAULT_FACTORY() external view returns (address);

    /**
     * @notice Get the network middleware service's address.
     * @return address of the network middleware service
     */
    function NETWORK_MIDDLEWARE_SERVICE() external view returns (address);

    /**
     * @notice Get the vault's address.
     * @return address of the vault
     */
    function VAULT() external view returns (address);

    /**
     * @notice Get an admin fee.
     * @return admin fee
     */
    function adminFee() external view returns (uint256);

    /**
     * @notice Get a total number of rewards using a particular token for a given network.
     * @param token address of the token
     * @param network address of the network
     * @return total number of the rewards using the token by the network
     */
    function rewardsLength(address token, address network) external view returns (uint256);

    /**
     * @notice Get a particular reward distribution.
     * @param token address of the token
     * @param network address of the network
     * @param rewardIndex index of the reward distribution using the token
     * @return amount amount of tokens to be distributed
     * @return timestamp time point stakes must taken into account at
     */
    function rewards(address token, address network, uint256 rewardIndex)
        external
        view
        returns (uint256 amount, uint48 timestamp);

    /**
     * @notice Get the first index of the unclaimed rewards using a particular token by a given account.
     * @param account address of the account
     * @param token address of the token
     * @param network address of the network
     * @return first index of the unclaimed rewards
     */
    function lastUnclaimedReward(address account, address token, address network) external view returns (uint256);

    /**
     * @notice Get a claimable admin fee amount for a particular token.
     * @param token address of the token
     * @return claimable admin fee
     */
    function claimableAdminFee(address token) external view returns (uint256);

    /**
     * @notice Claim an admin fee.
     * @param recipient account that will receive the fee
     * @param token address of the token
     * @dev Only the vault owner can call this function.
     */
    function claimAdminFee(address recipient, address token) external;

    /**
     * @notice Set an admin fee.
     * @param adminFee admin fee (up to ADMIN_FEE_BASE inclusively)
     * @dev Only the ADMIN_FEE_SET_ROLE holder can call this function.
     */
    function setAdminFee(uint256 adminFee) external;
}

// node_modules/@symbioticfi/core/src/interfaces/delegator/INetworkRestakeDelegator.sol

interface INetworkRestakeDelegator is IBaseDelegator {
    error DuplicateRoleHolder();
    error ExceedsMaxNetworkLimit();
    error MissingRoleHolders();
    error ZeroAddressRoleHolder();

    /**
     * @notice Hints for a stake.
     * @param baseHints base hints
     * @param activeStakeHint hint for the active stake checkpoint
     * @param networkLimitHint hint for the subnetwork limit checkpoint
     * @param totalOperatorNetworkSharesHint hint for the total operator-subnetwork shares checkpoint
     * @param operatorNetworkSharesHint hint for the operator-subnetwork shares checkpoint
     */
    struct StakeHints {
        bytes baseHints;
        bytes activeStakeHint;
        bytes networkLimitHint;
        bytes totalOperatorNetworkSharesHint;
        bytes operatorNetworkSharesHint;
    }

    /**
     * @notice Initial parameters needed for a full restaking delegator deployment.
     * @param baseParams base parameters for delegators' deployment
     * @param networkLimitSetRoleHolders array of addresses of the initial NETWORK_LIMIT_SET_ROLE holders
     * @param operatorNetworkSharesSetRoleHolders array of addresses of the initial OPERATOR_NETWORK_SHARES_SET_ROLE holders
     */
    struct InitParams {
        IBaseDelegator.BaseParams baseParams;
        address[] networkLimitSetRoleHolders;
        address[] operatorNetworkSharesSetRoleHolders;
    }

    /**
     * @notice Emitted when a subnetwork's limit is set.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param amount new subnetwork's limit (how much stake the vault curator is ready to give to the subnetwork)
     */
    event SetNetworkLimit(bytes32 indexed subnetwork, uint256 amount);

    /**
     * @notice Emitted when an operator's shares inside a subnetwork are set.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param shares new operator's shares inside the subnetwork (what percentage,
     *               which is equal to the shares divided by the total operators' shares,
     *               of the subnetwork's stake the vault curator is ready to give to the operator)
     */
    event SetOperatorNetworkShares(bytes32 indexed subnetwork, address indexed operator, uint256 shares);

    /**
     * @notice Get a subnetwork limit setter's role.
     * @return identifier of the subnetwork limit setter role
     */
    function NETWORK_LIMIT_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get an operator-subnetwork shares setter's role.
     * @return identifier of the operator-subnetwork shares setter role
     */
    function OPERATOR_NETWORK_SHARES_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get a subnetwork's limit at a given timestamp using a hint
     *         (how much stake the vault curator is ready to give to the subnetwork).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param timestamp time point to get the subnetwork limit at
     * @param hint hint for checkpoint index
     * @return limit of the subnetwork at the given timestamp
     */
    function networkLimitAt(bytes32 subnetwork, uint48 timestamp, bytes memory hint) external view returns (uint256);

    /**
     * @notice Get a subnetwork's limit (how much stake the vault curator is ready to give to the subnetwork).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @return limit of the subnetwork
     */
    function networkLimit(bytes32 subnetwork) external view returns (uint256);

    /**
     * @notice Get a sum of operators' shares for a subnetwork at a given timestamp using a hint.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param timestamp time point to get the total operators' shares at
     * @param hint hint for checkpoint index
     * @return total shares of the operators for the subnetwork at the given timestamp
     */
    function totalOperatorNetworkSharesAt(bytes32 subnetwork, uint48 timestamp, bytes memory hint)
        external
        view
        returns (uint256);

    /**
     * @notice Get a sum of operators' shares for a subnetwork.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @return total shares of the operators for the subnetwork
     */
    function totalOperatorNetworkShares(bytes32 subnetwork) external view returns (uint256);

    /**
     * @notice Get an operator's shares for a subnetwork at a given timestamp using a hint (what percentage,
     *         which is equal to the shares divided by the total operators' shares,
     *         of the subnetwork's stake the vault curator is ready to give to the operator).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param timestamp time point to get the operator's shares at
     * @param hint hint for checkpoint index
     * @return shares of the operator for the subnetwork at the given timestamp
     */
    function operatorNetworkSharesAt(bytes32 subnetwork, address operator, uint48 timestamp, bytes memory hint)
        external
        view
        returns (uint256);

    /**
     * @notice Get an operator's shares for a subnetwork (what percentage,
     *         which is equal to the shares divided by the total operators' shares,
     *         of the subnetwork's stake the vault curator is ready to give to the operator).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @return shares of the operator for the subnetwork
     */
    function operatorNetworkShares(bytes32 subnetwork, address operator) external view returns (uint256);

    /**
     * @notice Set a subnetwork's limit (how much stake the vault curator is ready to give to the subnetwork).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param amount new limit of the subnetwork
     * @dev Only a NETWORK_LIMIT_SET_ROLE holder can call this function.
     */
    function setNetworkLimit(bytes32 subnetwork, uint256 amount) external;

    /**
     * @notice Set an operator's shares for a subnetwork (what percentage,
     *         which is equal to the shares divided by the total operators' shares,
     *         of the subnetwork's stake the vault curator is ready to give to the operator).
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param shares new shares of the operator for the subnetwork
     * @dev Only an OPERATOR_NETWORK_SHARES_SET_ROLE holder can call this function.
     */
    function setOperatorNetworkShares(bytes32 subnetwork, address operator, uint256 shares) external;
}

// node_modules/@symbioticfi/core/src/interfaces/slasher/ISlasher.sol

interface ISlasher is IBaseSlasher {
    error InsufficientSlash();
    error InvalidCaptureTimestamp();

    /**
     * @notice Initial parameters needed for a slasher deployment.
     * @param baseParams base parameters for slashers' deployment
     */
    struct InitParams {
        IBaseSlasher.BaseParams baseParams;
    }

    /**
     * @notice Hints for a slash.
     * @param slashableStakeHints hints for the slashable stake checkpoints
     */
    struct SlashHints {
        bytes slashableStakeHints;
    }

    /**
     * @notice Extra data for the delegator.
     * @param slashableStake amount of the slashable stake before the slash (cache)
     * @param stakeAt amount of the stake at the capture time (cache)
     */
    struct DelegatorData {
        uint256 slashableStake;
        uint256 stakeAt;
    }

    /**
     * @notice Emitted when a slash is performed.
     * @param subnetwork subnetwork that requested the slash
     * @param operator operator that is slashed
     * @param slashedAmount virtual amount of the collateral slashed
     * @param captureTimestamp time point when the stake was captured
     */
    event Slash(bytes32 indexed subnetwork, address indexed operator, uint256 slashedAmount, uint48 captureTimestamp);

    /**
     * @notice Perform a slash using a subnetwork for a particular operator by a given amount using hints.
     * @param subnetwork full identifier of the subnetwork (address of the network concatenated with the uint96 identifier)
     * @param operator address of the operator
     * @param amount maximum amount of the collateral to be slashed
     * @param captureTimestamp time point when the stake was captured
     * @param hints hints for checkpoints' indexes
     * @return slashedAmount virtual amount of the collateral slashed
     * @dev Only a network middleware can call this function.
     */
    function slash(bytes32 subnetwork, address operator, uint256 amount, uint48 captureTimestamp, bytes calldata hints)
        external
        returns (uint256 slashedAmount);
}

// node_modules/@symbioticfi/core/src/interfaces/vault/IVault.sol

interface IVault is IMigratableEntity, IVaultStorage {
    error AlreadyClaimed();
    error AlreadySet();
    error DelegatorAlreadyInitialized();
    error DepositLimitReached();
    error InsufficientClaim();
    error InsufficientDeposit();
    error InsufficientRedemption();
    error InsufficientWithdrawal();
    error InvalidAccount();
    error InvalidCaptureEpoch();
    error InvalidClaimer();
    error InvalidCollateral();
    error InvalidDelegator();
    error InvalidEpoch();
    error InvalidEpochDuration();
    error InvalidLengthEpochs();
    error InvalidOnBehalfOf();
    error InvalidRecipient();
    error InvalidSlasher();
    error MissingRoles();
    error NotDelegator();
    error NotSlasher();
    error NotWhitelistedDepositor();
    error SlasherAlreadyInitialized();
    error TooMuchRedeem();
    error TooMuchWithdraw();

    /**
     * @notice Initial parameters needed for a vault deployment.
     * @param collateral vault's underlying collateral
     * @param burner vault's burner to issue debt to (e.g., 0xdEaD or some unwrapper contract)
     * @param epochDuration duration of the vault epoch (it determines sync points for withdrawals)
     * @param depositWhitelist if enabling deposit whitelist
     * @param isDepositLimit if enabling deposit limit
     * @param depositLimit deposit limit (maximum amount of the collateral that can be in the vault simultaneously)
     * @param defaultAdminRoleHolder address of the initial DEFAULT_ADMIN_ROLE holder
     * @param depositWhitelistSetRoleHolder address of the initial DEPOSIT_WHITELIST_SET_ROLE holder
     * @param depositorWhitelistRoleHolder address of the initial DEPOSITOR_WHITELIST_ROLE holder
     * @param isDepositLimitSetRoleHolder address of the initial IS_DEPOSIT_LIMIT_SET_ROLE holder
     * @param depositLimitSetRoleHolder address of the initial DEPOSIT_LIMIT_SET_ROLE holder
     */
    struct InitParams {
        address collateral;
        address burner;
        uint48 epochDuration;
        bool depositWhitelist;
        bool isDepositLimit;
        uint256 depositLimit;
        address defaultAdminRoleHolder;
        address depositWhitelistSetRoleHolder;
        address depositorWhitelistRoleHolder;
        address isDepositLimitSetRoleHolder;
        address depositLimitSetRoleHolder;
    }

    /**
     * @notice Hints for an active balance.
     * @param activeSharesOfHint hint for the active shares of checkpoint
     * @param activeStakeHint hint for the active stake checkpoint
     * @param activeSharesHint hint for the active shares checkpoint
     */
    struct ActiveBalanceOfHints {
        bytes activeSharesOfHint;
        bytes activeStakeHint;
        bytes activeSharesHint;
    }

    /**
     * @notice Emitted when a deposit is made.
     * @param depositor account that made the deposit
     * @param onBehalfOf account the deposit was made on behalf of
     * @param amount amount of the collateral deposited
     * @param shares amount of the active shares minted
     */
    event Deposit(address indexed depositor, address indexed onBehalfOf, uint256 amount, uint256 shares);

    /**
     * @notice Emitted when a withdrawal is made.
     * @param withdrawer account that made the withdrawal
     * @param claimer account that needs to claim the withdrawal
     * @param amount amount of the collateral withdrawn
     * @param burnedShares amount of the active shares burned
     * @param mintedShares amount of the epoch withdrawal shares minted
     */
    event Withdraw(
        address indexed withdrawer, address indexed claimer, uint256 amount, uint256 burnedShares, uint256 mintedShares
    );

    /**
     * @notice Emitted when a claim is made.
     * @param claimer account that claimed
     * @param recipient account that received the collateral
     * @param epoch epoch the collateral was claimed for
     * @param amount amount of the collateral claimed
     */
    event Claim(address indexed claimer, address indexed recipient, uint256 epoch, uint256 amount);

    /**
     * @notice Emitted when a batch claim is made.
     * @param claimer account that claimed
     * @param recipient account that received the collateral
     * @param epochs epochs the collateral was claimed for
     * @param amount amount of the collateral claimed
     */
    event ClaimBatch(address indexed claimer, address indexed recipient, uint256[] epochs, uint256 amount);

    /**
     * @notice Emitted when a slash happens.
     * @param amount amount of the collateral to slash
     * @param captureTimestamp time point when the stake was captured
     * @param slashedAmount real amount of the collateral slashed
     */
    event OnSlash(uint256 amount, uint48 captureTimestamp, uint256 slashedAmount);

    /**
     * @notice Emitted when a deposit whitelist status is enabled/disabled.
     * @param status if enabled deposit whitelist
     */
    event SetDepositWhitelist(bool status);

    /**
     * @notice Emitted when a depositor whitelist status is set.
     * @param account account for which the whitelist status is set
     * @param status if whitelisted the account
     */
    event SetDepositorWhitelistStatus(address indexed account, bool status);

    /**
     * @notice Emitted when a deposit limit status is enabled/disabled.
     * @param status if enabled deposit limit
     */
    event SetIsDepositLimit(bool status);

    /**
     * @notice Emitted when a deposit limit is set.
     * @param limit deposit limit (maximum amount of the collateral that can be in the vault simultaneously)
     */
    event SetDepositLimit(uint256 limit);

    /**
     * @notice Emitted when a delegator is set.
     * @param delegator vault's delegator to delegate the stake to networks and operators
     * @dev Can be set only once.
     */
    event SetDelegator(address indexed delegator);

    /**
     * @notice Emitted when a slasher is set.
     * @param slasher vault's slasher to provide a slashing mechanism to networks
     * @dev Can be set only once.
     */
    event SetSlasher(address indexed slasher);

    /**
     * @notice Check if the vault is fully initialized (a delegator and a slasher are set).
     * @return if the vault is fully initialized
     */
    function isInitialized() external view returns (bool);

    /**
     * @notice Get a total amount of the collateral that can be slashed.
     * @return total amount of the slashable collateral
     */
    function totalStake() external view returns (uint256);

    /**
     * @notice Get an active balance for a particular account at a given timestamp using hints.
     * @param account account to get the active balance for
     * @param timestamp time point to get the active balance for the account at
     * @param hints hints for checkpoints' indexes
     * @return active balance for the account at the timestamp
     */
    function activeBalanceOfAt(address account, uint48 timestamp, bytes calldata hints)
        external
        view
        returns (uint256);

    /**
     * @notice Get an active balance for a particular account.
     * @param account account to get the active balance for
     * @return active balance for the account
     */
    function activeBalanceOf(address account) external view returns (uint256);

    /**
     * @notice Get withdrawals for a particular account at a given epoch (zero if claimed).
     * @param epoch epoch to get the withdrawals for the account at
     * @param account account to get the withdrawals for
     * @return withdrawals for the account at the epoch
     */
    function withdrawalsOf(uint256 epoch, address account) external view returns (uint256);

    /**
     * @notice Get a total amount of the collateral that can be slashed for a given account.
     * @param account account to get the slashable collateral for
     * @return total amount of the account's slashable collateral
     */
    function slashableBalanceOf(address account) external view returns (uint256);

    /**
     * @notice Deposit collateral into the vault.
     * @param onBehalfOf account the deposit is made on behalf of
     * @param amount amount of the collateral to deposit
     * @return depositedAmount real amount of the collateral deposited
     * @return mintedShares amount of the active shares minted
     */
    function deposit(address onBehalfOf, uint256 amount)
        external
        returns (uint256 depositedAmount, uint256 mintedShares);

    /**
     * @notice Withdraw collateral from the vault (it will be claimable after the next epoch).
     * @param claimer account that needs to claim the withdrawal
     * @param amount amount of the collateral to withdraw
     * @return burnedShares amount of the active shares burned
     * @return mintedShares amount of the epoch withdrawal shares minted
     */
    function withdraw(address claimer, uint256 amount) external returns (uint256 burnedShares, uint256 mintedShares);

    /**
     * @notice Redeem collateral from the vault (it will be claimable after the next epoch).
     * @param claimer account that needs to claim the withdrawal
     * @param shares amount of the active shares to redeem
     * @return withdrawnAssets amount of the collateral withdrawn
     * @return mintedShares amount of the epoch withdrawal shares minted
     */
    function redeem(address claimer, uint256 shares) external returns (uint256 withdrawnAssets, uint256 mintedShares);

    /**
     * @notice Claim collateral from the vault.
     * @param recipient account that receives the collateral
     * @param epoch epoch to claim the collateral for
     * @return amount amount of the collateral claimed
     */
    function claim(address recipient, uint256 epoch) external returns (uint256 amount);

    /**
     * @notice Claim collateral from the vault for multiple epochs.
     * @param recipient account that receives the collateral
     * @param epochs epochs to claim the collateral for
     * @return amount amount of the collateral claimed
     */
    function claimBatch(address recipient, uint256[] calldata epochs) external returns (uint256 amount);

    /**
     * @notice Slash callback for burning collateral.
     * @param amount amount to slash
     * @param captureTimestamp time point when the stake was captured
     * @return slashedAmount real amount of the collateral slashed
     * @dev Only the slasher can call this function.
     */
    function onSlash(uint256 amount, uint48 captureTimestamp) external returns (uint256 slashedAmount);

    /**
     * @notice Enable/disable deposit whitelist.
     * @param status if enabling deposit whitelist
     * @dev Only a DEPOSIT_WHITELIST_SET_ROLE holder can call this function.
     */
    function setDepositWhitelist(bool status) external;

    /**
     * @notice Set a depositor whitelist status.
     * @param account account for which the whitelist status is set
     * @param status if whitelisting the account
     * @dev Only a DEPOSITOR_WHITELIST_ROLE holder can call this function.
     */
    function setDepositorWhitelistStatus(address account, bool status) external;

    /**
     * @notice Enable/disable deposit limit.
     * @param status if enabling deposit limit
     * @dev Only a IS_DEPOSIT_LIMIT_SET_ROLE holder can call this function.
     */
    function setIsDepositLimit(bool status) external;

    /**
     * @notice Set a deposit limit.
     * @param limit deposit limit (maximum amount of the collateral that can be in the vault simultaneously)
     * @dev Only a DEPOSIT_LIMIT_SET_ROLE holder can call this function.
     */
    function setDepositLimit(uint256 limit) external;

    /**
     * @notice Set a delegator.
     * @param delegator vault's delegator to delegate the stake to networks and operators
     * @dev Can be set only once.
     */
    function setDelegator(address delegator) external;

    /**
     * @notice Set a slasher.
     * @param slasher vault's slasher to provide a slashing mechanism to networks
     * @dev Can be set only once.
     */
    function setSlasher(address slasher) external;
}

// node_modules/@symbioticfi/burners/src/interfaces/router/IBurnerRouterFactory.sol

interface IBurnerRouterFactory is IRegistry {
    /**
     * @notice Create a burner router contract.
     * @param params initial parameters needed for a burner router contract deployment
     * @return address of the created burner router contract
     */
    function create(IBurnerRouter.InitParams calldata params) external returns (address);
}

// node_modules/@symbioticfi/rewards/src/interfaces/defaultStakerRewards/IDefaultStakerRewardsFactory.sol

interface IDefaultStakerRewardsFactory is IRegistry {
    /**
     * @notice Create a default staker rewards contract for a given vault.
     * @param params initial parameters needed for a staker rewards contract deployment
     * @return address of the created staker rewards contract
     */
    function create(IDefaultStakerRewards.InitParams calldata params) external returns (address);
}

// contracts/delegation/providers/symbiotic/CapSymbioticVaultFactory.sol

/// @title Cap Symbiotic Vault Factory
/// @author Cap Labs
/// @notice This contract creates new vaults compliant with the cap system
contract CapSymbioticVaultFactory is ICapSymbioticVaultFactory {
    enum DelegatorType {
        NETWORK_RESTAKE,
        FULL_RESTAKE,
        OPERATOR_SPECIFIC,
        OPERATOR_NETWORK_SPECIFIC
    }

    enum SlasherType {
        INSTANT,
        VETO
    }

    IVaultConfigurator public immutable vaultConfigurator;
    IBurnerRouterFactory public immutable burnerRouterFactory;
    IDefaultStakerRewardsFactory public immutable defaultStakerRewardsFactory;
    address public immutable middleware;
    uint48 public epochDuration;

    constructor(
        address _vaultConfigurator,
        address _burnerRouterFactory,
        address _defaultStakerRewardsFactory,
        address _middleware
    ) {
        vaultConfigurator = IVaultConfigurator(_vaultConfigurator);
        burnerRouterFactory = IBurnerRouterFactory(_burnerRouterFactory);
        defaultStakerRewardsFactory = IDefaultStakerRewardsFactory(_defaultStakerRewardsFactory);
        middleware = _middleware;
        epochDuration = 7 days;
    }

    /// @inheritdoc ICapSymbioticVaultFactory
    function createVault(address _owner, address _asset) external returns (address vault, address stakerRewards) {
        address burner = _deployBurner(_asset);

        address[] memory limitSetter = new address[](1);
        limitSetter[0] = _owner;

        IVaultConfigurator.InitParams memory params = IVaultConfigurator.InitParams({
            version: 1,
            owner: address(0),
            vaultParams: abi.encode(
                IVault.InitParams({
                    collateral: _asset,
                    burner: burner,
                    epochDuration: epochDuration,
                    depositWhitelist: false,
                    isDepositLimit: false,
                    depositLimit: 0,
                    defaultAdminRoleHolder: address(0),
                    depositWhitelistSetRoleHolder: _owner,
                    depositorWhitelistRoleHolder: _owner,
                    isDepositLimitSetRoleHolder: _owner,
                    depositLimitSetRoleHolder: _owner
                })
            ),
            delegatorIndex: uint64(DelegatorType.NETWORK_RESTAKE),
            delegatorParams: abi.encode(
                INetworkRestakeDelegator.InitParams({
                    baseParams: IBaseDelegator.BaseParams({
                        defaultAdminRoleHolder: address(0),
                        hook: address(0),
                        hookSetRoleHolder: address(0)
                    }),
                    networkLimitSetRoleHolders: limitSetter,
                    operatorNetworkSharesSetRoleHolders: limitSetter
                })
            ),
            withSlasher: true,
            slasherIndex: uint64(SlasherType.INSTANT),
            slasherParams: abi.encode(ISlasher.InitParams({ baseParams: IBaseSlasher.BaseParams({ isBurnerHook: true }) }))
        });

        (vault,,) = vaultConfigurator.create(params);

        stakerRewards = defaultStakerRewardsFactory.create(
            IDefaultStakerRewards.InitParams({
                vault: vault,
                adminFee: 0,
                defaultAdminRoleHolder: _owner,
                adminFeeClaimRoleHolder: _owner,
                adminFeeSetRoleHolder: _owner
            })
        );
    }

    // @dev Deploys a new burner router
    function _deployBurner(address _collateral) internal returns (address) {
        return burnerRouterFactory.create(
            IBurnerRouter.InitParams({
                owner: address(0),
                collateral: _collateral,
                delay: 1,
                globalReceiver: middleware,
                networkReceivers: new IBurnerRouter.NetworkReceiver[](0),
                operatorNetworkReceivers: new IBurnerRouter.OperatorNetworkReceiver[](0)
            })
        );
    }
}
