// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20 ^0.8.28;

// contracts/interfaces/ILender.sol

/// @title ILender
/// @author kexley, Cap Labs
/// @notice Interface for the Lender contract
interface ILender {
    /// @dev Storage struct for the Lender contract
    /// @param delegation Address of the delegation contract that manages agent permissions
    /// @param oracle Address of the oracle contract used for price feeds
    /// @param reservesData Mapping of asset address to reserve data
    /// @param reservesList Mapping of reserve ID to asset address
    /// @param reservesCount Total number of reserves
    /// @param agentConfig Mapping of agent address to configuration
    /// @param liquidationStart Mapping of agent address to liquidation start time
    /// @param targetHealth Target health ratio for liquidations (scaled by 1e27)
    /// @param grace Grace period in seconds before an agent becomes liquidatable
    /// @param expiry Period in seconds after which liquidation rights expire
    /// @param bonusCap Maximum bonus percentage for liquidators (scaled by 1e27)
    /// @param emergencyLiquidationThreshold Health threshold below which grace periods are ignored
    struct LenderStorage {
        // Addresses
        address delegation;
        address oracle;
        // Reserve configuration
        mapping(address => ReserveData) reservesData;
        mapping(uint256 => address) reservesList;
        uint16 reservesCount;
        // Agent configuration
        mapping(address => AgentConfigurationMap) agentConfig;
        mapping(address => uint256) liquidationStart;
        // Liquidation parameters
        uint256 targetHealth;
        uint256 grace;
        uint256 expiry;
        uint256 bonusCap;
        uint256 emergencyLiquidationThreshold;
    }

    /// @dev Reserve data
    /// @param id Id of the reserve
    /// @param vault Address of the vault
    /// @param debtToken Address of the debt token
    /// @param interestReceiver Address of the interest receiver
    /// @param decimals Decimals of the asset
    /// @param paused True if the asset is paused, false otherwise
    /// @param debt Total debt of the asset
    /// @param totalUnrealizedInterest Total unrealized interest for the asset
    /// @param unrealizedInterest Unrealized interest for each agent
    /// @param lastRealizationTime Last time interest was realized for each agent
    /// @param minBorrow Minimum borrow amount for the asset
    struct ReserveData {
        uint256 id;
        address vault;
        address debtToken;
        address interestReceiver;
        uint8 decimals;
        bool paused;
        uint256 debt;
        uint256 totalUnrealizedInterest;
        mapping(address => uint256) unrealizedInterest;
        mapping(address => uint256) lastRealizationTime;
        uint256 minBorrow;
    }

    /// @dev Agent configuration map
    /// @param data Data of the agent configuration
    struct AgentConfigurationMap {
        uint256 data;
    }

    /// @dev Borrow parameters
    /// @param agent Address of the agent
    /// @param asset Asset to borrow
    /// @param amount Amount to borrow
    /// @param receiver Receiver of the borrowed asset
    /// @param maxBorrow True if the maximum amount is being borrowed, false otherwise
    struct BorrowParams {
        address agent;
        address asset;
        uint256 amount;
        address receiver;
        bool maxBorrow;
    }

    /// @dev Repay parameters
    /// @param agent Address of the agent
    /// @param asset Asset to repay
    /// @param amount Amount to repay
    /// @param caller Caller of the repay function
    struct RepayParams {
        address agent;
        address asset;
        uint256 amount;
        address caller;
    }

    /// @dev Realize restaker interest parameters
    /// @param agent Agent to realize interest for
    /// @param asset Asset to realize interest for
    struct RealizeRestakerInterestParams {
        address agent;
        address asset;
    }

    /// @dev Add asset parameters
    /// @param asset Asset to add
    /// @param vault Address of the vault
    /// @param debtToken Address of the debt token
    /// @param interestReceiver Address of the interest receiver
    /// @param bonusCap Bonus cap for liquidations
    struct AddAssetParams {
        address asset;
        address vault;
        address debtToken;
        address interestReceiver;
        uint256 bonusCap;
        uint256 minBorrow;
    }

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @dev Invalid target health
    error InvalidTargetHealth();

    /// @dev Grace period greater than or equal to expiry
    error GraceGreaterThanExpiry();

    /// @dev Expiry less than or equal to grace
    error ExpiryLessThanGrace();

    /// @dev Invalid bonus cap
    error InvalidBonusCap();

    /// @notice Initialize the lender
    /// @param _accessControl Access control address
    /// @param _delegation Delegation address
    /// @param _oracle Oracle address
    /// @param _targetHealth Target health after liquidations
    /// @param _grace Grace period before an agent becomes liquidatable
    /// @param _expiry Expiry period after which an agent cannot be liquidated until called again
    /// @param _bonusCap Bonus cap for liquidations
    /// @param _emergencyLiquidationThreshold Liquidation threshold below which grace periods are voided
    function initialize(
        address _accessControl,
        address _delegation,
        address _oracle,
        uint256 _targetHealth,
        uint256 _grace,
        uint256 _expiry,
        uint256 _bonusCap,
        uint256 _emergencyLiquidationThreshold
    ) external;

    /// @notice Borrow an asset
    /// @param _asset Asset to borrow
    /// @param _amount Amount to borrow
    /// @param _receiver Receiver of the borrowed asset
    /// @return borrowed Actual amount borrowed
    function borrow(address _asset, uint256 _amount, address _receiver) external returns (uint256 borrowed);

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount to repay
    /// @param _agent Repay on behalf of another borrower
    /// @return repaid Actual amount repaid
    function repay(address _asset, uint256 _amount, address _agent) external returns (uint256 repaid);

    /// @notice Realize interest for an asset
    /// @param _asset Asset to realize interest for
    /// @return actualRealized Actual amount realized
    function realizeInterest(address _asset) external returns (uint256 actualRealized);

    /// @notice Realize interest for restaker debt of an agent for an asset
    /// @param _agent Agent to realize interest for
    /// @param _asset Asset to realize interest for
    /// @return actualRealized Actual amount realized
    function realizeRestakerInterest(address _agent, address _asset) external returns (uint256 actualRealized);

    /// @notice Open liquidation window of an agent when the health is below 1
    /// @param _agent Agent address
    function openLiquidation(address _agent) external;

    /// @notice Close liquidation window of an agent when the health is above 1
    /// @param _agent Agent address
    function closeLiquidation(address _agent) external;

    /// @notice Liquidate an agent when the health is below 1
    /// @param _agent Agent address
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay on behalf of the agent
    /// @param _minLiquidatedValue Minimum value of the liquidation returned to the liquidator
    /// @return liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(address _agent, address _asset, uint256 _amount, uint256 _minLiquidatedValue)
        external
        returns (uint256 liquidatedValue);

    /// @notice Add an asset to the Lender
    /// @param _params Parameters to add an asset
    function addAsset(AddAssetParams calldata _params) external;

    /// @notice Remove asset from lending when there is no borrows
    /// @param _asset Asset address
    function removeAsset(address _asset) external;

    /// @notice Pause an asset from being borrowed
    /// @param _asset Asset address
    /// @param _pause True if pausing or false if unpausing
    function pauseAsset(address _asset, bool _pause) external;

    /// @notice Set the interest receiver for an asset
    /// @param _asset Asset address
    /// @param _interestReceiver Interest receiver address
    function setInterestReceiver(address _asset, address _interestReceiver) external;

    /// @notice Set the minimum borrow amount for an asset
    /// @param _asset Asset address
    /// @param _minBorrow Minimum borrow amount in asset decimals
    function setMinBorrow(address _asset, uint256 _minBorrow) external;

    /// @notice Set the grace period
    /// @param _grace Grace period in seconds
    function setGrace(uint256 _grace) external;

    /// @notice Set the expiry period
    /// @param _expiry Expiry period in seconds
    function setExpiry(uint256 _expiry) external;

    /// @notice Set the bonus cap
    /// @param _bonusCap Bonus cap in percentage ray decimals
    function setBonusCap(uint256 _bonusCap) external;

    /// @notice Get the accrued restaker interest for an agent for a specific asset
    /// @param _agent Agent address to check accrued restaker interest for
    /// @param _asset Asset to check accrued restaker interest for
    /// @return accruedInterest Accrued restaker interest in asset decimals
    function accruedRestakerInterest(address _agent, address _asset) external view returns (uint256 accruedInterest);

    /// @notice Get the total number of reserves
    /// @return count Number of reserves
    function reservesCount() external view returns (uint256 count);

    /// @notice Calculate the agent data
    /// @param _agent Address of agent
    /// @return totalDelegation Total delegation of an agent in USD, encoded with 8 decimals
    /// @return totalSlashableCollateral Total slashable collateral of an agent in USD, encoded with 8 decimals
    /// @return totalDebt Total debt of an agent in USD, encoded with 8 decimals
    /// @return ltv Loan to value ratio, encoded in ray (1e27)
    /// @return liquidationThreshold Liquidation ratio of an agent, encoded in ray (1e27)
    /// @return health Health status of an agent, encoded in ray (1e27)
    function agent(address _agent)
        external
        view
        returns (
            uint256 totalDelegation,
            uint256 totalSlashableCollateral,
            uint256 totalDebt,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 health
        );

    /// @notice Get the bonus cap
    /// @return bonusCap Bonus cap in percentage ray decimals
    function bonusCap() external view returns (uint256 bonusCap);

    /// @notice Get the current debt balances for an agent for a specific asset
    /// @param _agent Agent address to check debt for
    /// @param _asset Asset to check debt for
    /// @return totalDebt Total debt amount in asset decimals
    function debt(address _agent, address _asset) external view returns (uint256 totalDebt);

    /// @notice Calculate the maximum interest that can be realized
    /// @param _asset Asset to calculate max realization for
    /// @return _maxRealization Maximum interest that can be realized
    function maxRealization(address _asset) external view returns (uint256 _maxRealization);

    /// @notice Calculate the maximum interest that can be realized for a restaker
    /// @param _agent Agent to calculate max realization for
    /// @param _asset Asset to calculate max realization for
    /// @return newRealizedInterest Maximum interest that can be realized
    /// @return newUnrealizedInterest Unrealized interest that will be added to the debt
    function maxRestakerRealization(address _agent, address _asset)
        external
        view
        returns (uint256 newRealizedInterest, uint256 newUnrealizedInterest);

    /// @notice Get the emergency liquidation threshold
    function emergencyLiquidationThreshold() external view returns (uint256 emergencyLiquidationThreshold);

    /// @notice Get the expiry period
    /// @return expiry Expiry period in seconds
    function expiry() external view returns (uint256 expiry);

    /// @notice Get the grace period
    /// @return grace Grace period in seconds
    function grace() external view returns (uint256 grace);

    /// @notice Get the target health ratio
    /// @return targetHealth Target health ratio scaled to 1e27
    function targetHealth() external view returns (uint256 targetHealth);

    /// @notice The liquidation start time for an agent
    /// @param _agent Address of the agent
    /// @return startTime Timestamp when liquidation was initiated
    function liquidationStart(address _agent) external view returns (uint256 startTime);

    /// @notice Calculate the maximum amount that can be borrowed for a given asset
    /// @param _agent Agent address
    /// @param _asset Asset to borrow
    /// @return maxBorrowableAmount Maximum amount that can be borrowed in asset decimals
    function maxBorrowable(address _agent, address _asset) external view returns (uint256 maxBorrowableAmount);

    /// @notice Calculate the maximum amount that can be liquidated for a given asset
    /// @param _agent Agent address
    /// @param _asset Asset to liquidate
    /// @return maxLiquidatableAmount Maximum amount that can be liquidated in asset decimals
    function maxLiquidatable(address _agent, address _asset) external view returns (uint256 maxLiquidatableAmount);

    /// @notice Calculate the maximum bonus for a liquidation in percentage ray decimals
    /// @param _agent Agent address
    /// @return maxBonus Maximum bonus in percentage ray decimals
    function bonus(address _agent) external view returns (uint256 maxBonus);

    /// @notice The reserve data for an asset
    /// @param _asset Address of the asset
    /// @return id Id of the reserve
    /// @return vault Address of the vault
    /// @return debtToken Address of the debt token
    /// @return interestReceiver Address of the interest receiver
    /// @return decimals Decimals of the asset
    /// @return paused True if the asset is paused, false otherwise
    function reservesData(address _asset)
        external
        view
        returns (
            uint256 id,
            address vault,
            address debtToken,
            address interestReceiver,
            uint8 decimals,
            bool paused,
            uint256 minBorrow
        );

    /// @notice Get the unrealized restaker interest for an agent for a specific asset
    /// @dev This amount was not yet realized due to low reserves for the asset
    /// @param _agent Agent address
    /// @param _asset Asset to check unrealized interest for
    /// @return _unrealizedInterest Unrealized interest in asset decimals
    function unrealizedInterest(address _agent, address _asset) external view returns (uint256 _unrealizedInterest);
}

// contracts/interfaces/IOracleTypes.sol

/// @title Oracle Types
/// @author kexley, Cap Labs
/// @notice Oracle types
interface IOracleTypes {
    /// @notice Oracle data
    /// @param adapter Adapter address
    /// @param payload Payload for the adapter
    struct OracleData {
        address adapter;
        bytes payload;
    }
}

// contracts/interfaces/IRestakerRewardReceiver.sol

/// @title Restaker Reward Receiver Interface
/// @author Cap Labs
/// @notice Interface for contracts that can receive and distribute rewards from restaking
interface IRestakerRewardReceiver {
    /// @notice Distribute rewards accumulated by the agent borrowing
    /// @param _agent Agent address
    /// @param _token Token address
    function distributeRewards(address _agent, address _token) external;
}

// node_modules/@openzeppelin/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC-20 standard as defined in the ERC.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// node_modules/@openzeppelin/contracts/utils/Comparators.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/Comparators.sol)

/**
 * @dev Provides a set of functions to compare values.
 *
 * _Available since v5.1._
 */
library Comparators {
    function lt(uint256 a, uint256 b) internal pure returns (bool) {
        return a < b;
    }

    function gt(uint256 a, uint256 b) internal pure returns (bool) {
        return a > b;
    }
}

// node_modules/@openzeppelin/contracts/utils/Panic.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/Panic.sol)

/**
 * @dev Helper library for emitting standardized panic codes.
 *
 * ```solidity
 * contract Example {
 *      using Panic for uint256;
 *
 *      // Use any of the declared internal constants
 *      function foo() { Panic.GENERIC.panic(); }
 *
 *      // Alternatively
 *      function foo() { Panic.panic(Panic.GENERIC); }
 * }
 * ```
 *
 * Follows the list from https://github.com/ethereum/solidity/blob/v0.8.24/libsolutil/ErrorCodes.h[libsolutil].
 *
 * _Available since v5.1._
 */
// slither-disable-next-line unused-state
library Panic {
    /// @dev generic / unspecified error
    uint256 internal constant GENERIC = 0x00;
    /// @dev used by the assert() builtin
    uint256 internal constant ASSERT = 0x01;
    /// @dev arithmetic underflow or overflow
    uint256 internal constant UNDER_OVERFLOW = 0x11;
    /// @dev division or modulo by zero
    uint256 internal constant DIVISION_BY_ZERO = 0x12;
    /// @dev enum conversion error
    uint256 internal constant ENUM_CONVERSION_ERROR = 0x21;
    /// @dev invalid encoding in storage
    uint256 internal constant STORAGE_ENCODING_ERROR = 0x22;
    /// @dev empty array pop
    uint256 internal constant EMPTY_ARRAY_POP = 0x31;
    /// @dev array out of bounds access
    uint256 internal constant ARRAY_OUT_OF_BOUNDS = 0x32;
    /// @dev resource error (too large allocation or too large array)
    uint256 internal constant RESOURCE_ERROR = 0x41;
    /// @dev calling invalid internal function
    uint256 internal constant INVALID_INTERNAL_FUNCTION = 0x51;

    /// @dev Reverts with a panic code. Recommended to use with
    /// the internal constants with predefined codes.
    function panic(uint256 code) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, 0x4e487b71)
            mstore(0x20, code)
            revert(0x1c, 0x24)
        }
    }
}

// node_modules/@openzeppelin/contracts/utils/SlotDerivation.sol

// OpenZeppelin Contracts (last updated v5.3.0) (utils/SlotDerivation.sol)
// This file was procedurally generated from scripts/generate/templates/SlotDerivation.js.

/**
 * @dev Library for computing storage (and transient storage) locations from namespaces and deriving slots
 * corresponding to standard patterns. The derivation method for array and mapping matches the storage layout used by
 * the solidity language / compiler.
 *
 * See https://docs.soliditylang.org/en/v0.8.20/internals/layout_in_storage.html#mappings-and-dynamic-arrays[Solidity docs for mappings and dynamic arrays.].
 *
 * Example usage:
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using StorageSlot for bytes32;
 *     using SlotDerivation for bytes32;
 *
 *     // Declare a namespace
 *     string private constant _NAMESPACE = "<namespace>"; // eg. OpenZeppelin.Slot
 *
 *     function setValueInNamespace(uint256 key, address newValue) internal {
 *         _NAMESPACE.erc7201Slot().deriveMapping(key).getAddressSlot().value = newValue;
 *     }
 *
 *     function getValueInNamespace(uint256 key) internal view returns (address) {
 *         return _NAMESPACE.erc7201Slot().deriveMapping(key).getAddressSlot().value;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {StorageSlot}.
 *
 * NOTE: This library provides a way to manipulate storage locations in a non-standard way. Tooling for checking
 * upgrade safety will ignore the slots accessed through this library.
 *
 * _Available since v5.1._
 */
library SlotDerivation {
    /**
     * @dev Derive an ERC-7201 slot from a string (namespace).
     */
    function erc7201Slot(string memory namespace) internal pure returns (bytes32 slot) {
        assembly ("memory-safe") {
            mstore(0x00, sub(keccak256(add(namespace, 0x20), mload(namespace)), 1))
            slot := and(keccak256(0x00, 0x20), not(0xff))
        }
    }

    /**
     * @dev Add an offset to a slot to get the n-th element of a structure or an array.
     */
    function offset(bytes32 slot, uint256 pos) internal pure returns (bytes32 result) {
        unchecked {
            return bytes32(uint256(slot) + pos);
        }
    }

    /**
     * @dev Derive the location of the first element in an array from the slot where the length is stored.
     */
    function deriveArray(bytes32 slot) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, slot)
            result := keccak256(0x00, 0x20)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, address key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, and(key, shr(96, not(0))))
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bool key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, iszero(iszero(key)))
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bytes32 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, uint256 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, int256 key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0x00, key)
            mstore(0x20, slot)
            result := keccak256(0x00, 0x40)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, string memory key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let length := mload(key)
            let begin := add(key, 0x20)
            let end := add(begin, length)
            let cache := mload(end)
            mstore(end, slot)
            result := keccak256(begin, add(length, 0x20))
            mstore(end, cache)
        }
    }

    /**
     * @dev Derive the location of a mapping element from the key.
     */
    function deriveMapping(bytes32 slot, bytes memory key) internal pure returns (bytes32 result) {
        assembly ("memory-safe") {
            let length := mload(key)
            let begin := add(key, 0x20)
            let end := add(begin, length)
            let cache := mload(end)
            mstore(end, slot)
            result := keccak256(begin, add(length, 0x20))
            mstore(end, cache)
        }
    }
}

// node_modules/@openzeppelin/contracts/utils/StorageSlot.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/StorageSlot.sol)
// This file was procedurally generated from scripts/generate/templates/StorageSlot.js.

/**
 * @dev Library for reading and writing primitive types to specific storage slots.
 *
 * Storage slots are often used to avoid storage conflict when dealing with upgradeable contracts.
 * This library helps with reading and writing to such slots without the need for inline assembly.
 *
 * The functions in this library return Slot structs that contain a `value` member that can be used to read or write.
 *
 * Example usage to set ERC-1967 implementation slot:
 * ```solidity
 * contract ERC1967 {
 *     // Define the slot. Alternatively, use the SlotDerivation library to derive the slot.
 *     bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
 *
 *     function _getImplementation() internal view returns (address) {
 *         return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
 *     }
 *
 *     function _setImplementation(address newImplementation) internal {
 *         require(newImplementation.code.length > 0);
 *         StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = newImplementation;
 *     }
 * }
 * ```
 *
 * TIP: Consider using this library along with {SlotDerivation}.
 */
library StorageSlot {
    struct AddressSlot {
        address value;
    }

    struct BooleanSlot {
        bool value;
    }

    struct Bytes32Slot {
        bytes32 value;
    }

    struct Uint256Slot {
        uint256 value;
    }

    struct Int256Slot {
        int256 value;
    }

    struct StringSlot {
        string value;
    }

    struct BytesSlot {
        bytes value;
    }

    /**
     * @dev Returns an `AddressSlot` with member `value` located at `slot`.
     */
    function getAddressSlot(bytes32 slot) internal pure returns (AddressSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `BooleanSlot` with member `value` located at `slot`.
     */
    function getBooleanSlot(bytes32 slot) internal pure returns (BooleanSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Bytes32Slot` with member `value` located at `slot`.
     */
    function getBytes32Slot(bytes32 slot) internal pure returns (Bytes32Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Uint256Slot` with member `value` located at `slot`.
     */
    function getUint256Slot(bytes32 slot) internal pure returns (Uint256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `Int256Slot` with member `value` located at `slot`.
     */
    function getInt256Slot(bytes32 slot) internal pure returns (Int256Slot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns a `StringSlot` with member `value` located at `slot`.
     */
    function getStringSlot(bytes32 slot) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `StringSlot` representation of the string storage pointer `store`.
     */
    function getStringSlot(string storage store) internal pure returns (StringSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }

    /**
     * @dev Returns a `BytesSlot` with member `value` located at `slot`.
     */
    function getBytesSlot(bytes32 slot) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := slot
        }
    }

    /**
     * @dev Returns an `BytesSlot` representation of the bytes storage pointer `store`.
     */
    function getBytesSlot(bytes storage store) internal pure returns (BytesSlot storage r) {
        assembly ("memory-safe") {
            r.slot := store.slot
        }
    }
}

// node_modules/@openzeppelin/contracts/utils/introspection/IERC165.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/introspection/IERC165.sol)

/**
 * @dev Interface of the ERC-165 standard, as defined in the
 * https://eips.ethereum.org/EIPS/eip-165[ERC].
 *
 * Implementers can declare support of contract interfaces, which can then be
 * queried by others ({ERC165Checker}).
 *
 * For an implementation, see {ERC165}.
 */
interface IERC165 {
    /**
     * @dev Returns true if this contract implements the interface defined by
     * `interfaceId`. See the corresponding
     * https://eips.ethereum.org/EIPS/eip-165#how-interfaces-are-identified[ERC section]
     * to learn more about how these ids are created.
     *
     * This function call must use less than 30 000 gas.
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

// node_modules/@openzeppelin/contracts/utils/math/SafeCast.sol

// OpenZeppelin Contracts (last updated v5.1.0) (utils/math/SafeCast.sol)
// This file was procedurally generated from scripts/generate/templates/SafeCast.js.

/**
 * @dev Wrappers over Solidity's uintXX/intXX/bool casting operators with added overflow
 * checks.
 *
 * Downcasting from uint256/int256 in Solidity does not revert on overflow. This can
 * easily result in undesired exploitation or bugs, since developers usually
 * assume that overflows raise errors. `SafeCast` restores this intuition by
 * reverting the transaction when such an operation overflows.
 *
 * Using this library instead of the unchecked operations eliminates an entire
 * class of bugs, so it's recommended to use it always.
 */
library SafeCast {
    /**
     * @dev Value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);

    /**
     * @dev An int value doesn't fit in an uint of `bits` size.
     */
    error SafeCastOverflowedIntToUint(int256 value);

    /**
     * @dev Value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedIntDowncast(uint8 bits, int256 value);

    /**
     * @dev An uint value doesn't fit in an int of `bits` size.
     */
    error SafeCastOverflowedUintToInt(uint256 value);

    /**
     * @dev Returns the downcasted uint248 from uint256, reverting on
     * overflow (when the input is greater than largest uint248).
     *
     * Counterpart to Solidity's `uint248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toUint248(uint256 value) internal pure returns (uint248) {
        if (value > type(uint248).max) {
            revert SafeCastOverflowedUintDowncast(248, value);
        }
        return uint248(value);
    }

    /**
     * @dev Returns the downcasted uint240 from uint256, reverting on
     * overflow (when the input is greater than largest uint240).
     *
     * Counterpart to Solidity's `uint240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toUint240(uint256 value) internal pure returns (uint240) {
        if (value > type(uint240).max) {
            revert SafeCastOverflowedUintDowncast(240, value);
        }
        return uint240(value);
    }

    /**
     * @dev Returns the downcasted uint232 from uint256, reverting on
     * overflow (when the input is greater than largest uint232).
     *
     * Counterpart to Solidity's `uint232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toUint232(uint256 value) internal pure returns (uint232) {
        if (value > type(uint232).max) {
            revert SafeCastOverflowedUintDowncast(232, value);
        }
        return uint232(value);
    }

    /**
     * @dev Returns the downcasted uint224 from uint256, reverting on
     * overflow (when the input is greater than largest uint224).
     *
     * Counterpart to Solidity's `uint224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toUint224(uint256 value) internal pure returns (uint224) {
        if (value > type(uint224).max) {
            revert SafeCastOverflowedUintDowncast(224, value);
        }
        return uint224(value);
    }

    /**
     * @dev Returns the downcasted uint216 from uint256, reverting on
     * overflow (when the input is greater than largest uint216).
     *
     * Counterpart to Solidity's `uint216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toUint216(uint256 value) internal pure returns (uint216) {
        if (value > type(uint216).max) {
            revert SafeCastOverflowedUintDowncast(216, value);
        }
        return uint216(value);
    }

    /**
     * @dev Returns the downcasted uint208 from uint256, reverting on
     * overflow (when the input is greater than largest uint208).
     *
     * Counterpart to Solidity's `uint208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toUint208(uint256 value) internal pure returns (uint208) {
        if (value > type(uint208).max) {
            revert SafeCastOverflowedUintDowncast(208, value);
        }
        return uint208(value);
    }

    /**
     * @dev Returns the downcasted uint200 from uint256, reverting on
     * overflow (when the input is greater than largest uint200).
     *
     * Counterpart to Solidity's `uint200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toUint200(uint256 value) internal pure returns (uint200) {
        if (value > type(uint200).max) {
            revert SafeCastOverflowedUintDowncast(200, value);
        }
        return uint200(value);
    }

    /**
     * @dev Returns the downcasted uint192 from uint256, reverting on
     * overflow (when the input is greater than largest uint192).
     *
     * Counterpart to Solidity's `uint192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toUint192(uint256 value) internal pure returns (uint192) {
        if (value > type(uint192).max) {
            revert SafeCastOverflowedUintDowncast(192, value);
        }
        return uint192(value);
    }

    /**
     * @dev Returns the downcasted uint184 from uint256, reverting on
     * overflow (when the input is greater than largest uint184).
     *
     * Counterpart to Solidity's `uint184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toUint184(uint256 value) internal pure returns (uint184) {
        if (value > type(uint184).max) {
            revert SafeCastOverflowedUintDowncast(184, value);
        }
        return uint184(value);
    }

    /**
     * @dev Returns the downcasted uint176 from uint256, reverting on
     * overflow (when the input is greater than largest uint176).
     *
     * Counterpart to Solidity's `uint176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toUint176(uint256 value) internal pure returns (uint176) {
        if (value > type(uint176).max) {
            revert SafeCastOverflowedUintDowncast(176, value);
        }
        return uint176(value);
    }

    /**
     * @dev Returns the downcasted uint168 from uint256, reverting on
     * overflow (when the input is greater than largest uint168).
     *
     * Counterpart to Solidity's `uint168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toUint168(uint256 value) internal pure returns (uint168) {
        if (value > type(uint168).max) {
            revert SafeCastOverflowedUintDowncast(168, value);
        }
        return uint168(value);
    }

    /**
     * @dev Returns the downcasted uint160 from uint256, reverting on
     * overflow (when the input is greater than largest uint160).
     *
     * Counterpart to Solidity's `uint160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toUint160(uint256 value) internal pure returns (uint160) {
        if (value > type(uint160).max) {
            revert SafeCastOverflowedUintDowncast(160, value);
        }
        return uint160(value);
    }

    /**
     * @dev Returns the downcasted uint152 from uint256, reverting on
     * overflow (when the input is greater than largest uint152).
     *
     * Counterpart to Solidity's `uint152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toUint152(uint256 value) internal pure returns (uint152) {
        if (value > type(uint152).max) {
            revert SafeCastOverflowedUintDowncast(152, value);
        }
        return uint152(value);
    }

    /**
     * @dev Returns the downcasted uint144 from uint256, reverting on
     * overflow (when the input is greater than largest uint144).
     *
     * Counterpart to Solidity's `uint144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toUint144(uint256 value) internal pure returns (uint144) {
        if (value > type(uint144).max) {
            revert SafeCastOverflowedUintDowncast(144, value);
        }
        return uint144(value);
    }

    /**
     * @dev Returns the downcasted uint136 from uint256, reverting on
     * overflow (when the input is greater than largest uint136).
     *
     * Counterpart to Solidity's `uint136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toUint136(uint256 value) internal pure returns (uint136) {
        if (value > type(uint136).max) {
            revert SafeCastOverflowedUintDowncast(136, value);
        }
        return uint136(value);
    }

    /**
     * @dev Returns the downcasted uint128 from uint256, reverting on
     * overflow (when the input is greater than largest uint128).
     *
     * Counterpart to Solidity's `uint128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) {
            revert SafeCastOverflowedUintDowncast(128, value);
        }
        return uint128(value);
    }

    /**
     * @dev Returns the downcasted uint120 from uint256, reverting on
     * overflow (when the input is greater than largest uint120).
     *
     * Counterpart to Solidity's `uint120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toUint120(uint256 value) internal pure returns (uint120) {
        if (value > type(uint120).max) {
            revert SafeCastOverflowedUintDowncast(120, value);
        }
        return uint120(value);
    }

    /**
     * @dev Returns the downcasted uint112 from uint256, reverting on
     * overflow (when the input is greater than largest uint112).
     *
     * Counterpart to Solidity's `uint112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toUint112(uint256 value) internal pure returns (uint112) {
        if (value > type(uint112).max) {
            revert SafeCastOverflowedUintDowncast(112, value);
        }
        return uint112(value);
    }

    /**
     * @dev Returns the downcasted uint104 from uint256, reverting on
     * overflow (when the input is greater than largest uint104).
     *
     * Counterpart to Solidity's `uint104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toUint104(uint256 value) internal pure returns (uint104) {
        if (value > type(uint104).max) {
            revert SafeCastOverflowedUintDowncast(104, value);
        }
        return uint104(value);
    }

    /**
     * @dev Returns the downcasted uint96 from uint256, reverting on
     * overflow (when the input is greater than largest uint96).
     *
     * Counterpart to Solidity's `uint96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toUint96(uint256 value) internal pure returns (uint96) {
        if (value > type(uint96).max) {
            revert SafeCastOverflowedUintDowncast(96, value);
        }
        return uint96(value);
    }

    /**
     * @dev Returns the downcasted uint88 from uint256, reverting on
     * overflow (when the input is greater than largest uint88).
     *
     * Counterpart to Solidity's `uint88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toUint88(uint256 value) internal pure returns (uint88) {
        if (value > type(uint88).max) {
            revert SafeCastOverflowedUintDowncast(88, value);
        }
        return uint88(value);
    }

    /**
     * @dev Returns the downcasted uint80 from uint256, reverting on
     * overflow (when the input is greater than largest uint80).
     *
     * Counterpart to Solidity's `uint80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toUint80(uint256 value) internal pure returns (uint80) {
        if (value > type(uint80).max) {
            revert SafeCastOverflowedUintDowncast(80, value);
        }
        return uint80(value);
    }

    /**
     * @dev Returns the downcasted uint72 from uint256, reverting on
     * overflow (when the input is greater than largest uint72).
     *
     * Counterpart to Solidity's `uint72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toUint72(uint256 value) internal pure returns (uint72) {
        if (value > type(uint72).max) {
            revert SafeCastOverflowedUintDowncast(72, value);
        }
        return uint72(value);
    }

    /**
     * @dev Returns the downcasted uint64 from uint256, reverting on
     * overflow (when the input is greater than largest uint64).
     *
     * Counterpart to Solidity's `uint64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) {
            revert SafeCastOverflowedUintDowncast(64, value);
        }
        return uint64(value);
    }

    /**
     * @dev Returns the downcasted uint56 from uint256, reverting on
     * overflow (when the input is greater than largest uint56).
     *
     * Counterpart to Solidity's `uint56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toUint56(uint256 value) internal pure returns (uint56) {
        if (value > type(uint56).max) {
            revert SafeCastOverflowedUintDowncast(56, value);
        }
        return uint56(value);
    }

    /**
     * @dev Returns the downcasted uint48 from uint256, reverting on
     * overflow (when the input is greater than largest uint48).
     *
     * Counterpart to Solidity's `uint48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toUint48(uint256 value) internal pure returns (uint48) {
        if (value > type(uint48).max) {
            revert SafeCastOverflowedUintDowncast(48, value);
        }
        return uint48(value);
    }

    /**
     * @dev Returns the downcasted uint40 from uint256, reverting on
     * overflow (when the input is greater than largest uint40).
     *
     * Counterpart to Solidity's `uint40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toUint40(uint256 value) internal pure returns (uint40) {
        if (value > type(uint40).max) {
            revert SafeCastOverflowedUintDowncast(40, value);
        }
        return uint40(value);
    }

    /**
     * @dev Returns the downcasted uint32 from uint256, reverting on
     * overflow (when the input is greater than largest uint32).
     *
     * Counterpart to Solidity's `uint32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toUint32(uint256 value) internal pure returns (uint32) {
        if (value > type(uint32).max) {
            revert SafeCastOverflowedUintDowncast(32, value);
        }
        return uint32(value);
    }

    /**
     * @dev Returns the downcasted uint24 from uint256, reverting on
     * overflow (when the input is greater than largest uint24).
     *
     * Counterpart to Solidity's `uint24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toUint24(uint256 value) internal pure returns (uint24) {
        if (value > type(uint24).max) {
            revert SafeCastOverflowedUintDowncast(24, value);
        }
        return uint24(value);
    }

    /**
     * @dev Returns the downcasted uint16 from uint256, reverting on
     * overflow (when the input is greater than largest uint16).
     *
     * Counterpart to Solidity's `uint16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toUint16(uint256 value) internal pure returns (uint16) {
        if (value > type(uint16).max) {
            revert SafeCastOverflowedUintDowncast(16, value);
        }
        return uint16(value);
    }

    /**
     * @dev Returns the downcasted uint8 from uint256, reverting on
     * overflow (when the input is greater than largest uint8).
     *
     * Counterpart to Solidity's `uint8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toUint8(uint256 value) internal pure returns (uint8) {
        if (value > type(uint8).max) {
            revert SafeCastOverflowedUintDowncast(8, value);
        }
        return uint8(value);
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        if (value < 0) {
            revert SafeCastOverflowedIntToUint(value);
        }
        return uint256(value);
    }

    /**
     * @dev Returns the downcasted int248 from int256, reverting on
     * overflow (when the input is less than smallest int248 or
     * greater than largest int248).
     *
     * Counterpart to Solidity's `int248` operator.
     *
     * Requirements:
     *
     * - input must fit into 248 bits
     */
    function toInt248(int256 value) internal pure returns (int248 downcasted) {
        downcasted = int248(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(248, value);
        }
    }

    /**
     * @dev Returns the downcasted int240 from int256, reverting on
     * overflow (when the input is less than smallest int240 or
     * greater than largest int240).
     *
     * Counterpart to Solidity's `int240` operator.
     *
     * Requirements:
     *
     * - input must fit into 240 bits
     */
    function toInt240(int256 value) internal pure returns (int240 downcasted) {
        downcasted = int240(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(240, value);
        }
    }

    /**
     * @dev Returns the downcasted int232 from int256, reverting on
     * overflow (when the input is less than smallest int232 or
     * greater than largest int232).
     *
     * Counterpart to Solidity's `int232` operator.
     *
     * Requirements:
     *
     * - input must fit into 232 bits
     */
    function toInt232(int256 value) internal pure returns (int232 downcasted) {
        downcasted = int232(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(232, value);
        }
    }

    /**
     * @dev Returns the downcasted int224 from int256, reverting on
     * overflow (when the input is less than smallest int224 or
     * greater than largest int224).
     *
     * Counterpart to Solidity's `int224` operator.
     *
     * Requirements:
     *
     * - input must fit into 224 bits
     */
    function toInt224(int256 value) internal pure returns (int224 downcasted) {
        downcasted = int224(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(224, value);
        }
    }

    /**
     * @dev Returns the downcasted int216 from int256, reverting on
     * overflow (when the input is less than smallest int216 or
     * greater than largest int216).
     *
     * Counterpart to Solidity's `int216` operator.
     *
     * Requirements:
     *
     * - input must fit into 216 bits
     */
    function toInt216(int256 value) internal pure returns (int216 downcasted) {
        downcasted = int216(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(216, value);
        }
    }

    /**
     * @dev Returns the downcasted int208 from int256, reverting on
     * overflow (when the input is less than smallest int208 or
     * greater than largest int208).
     *
     * Counterpart to Solidity's `int208` operator.
     *
     * Requirements:
     *
     * - input must fit into 208 bits
     */
    function toInt208(int256 value) internal pure returns (int208 downcasted) {
        downcasted = int208(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(208, value);
        }
    }

    /**
     * @dev Returns the downcasted int200 from int256, reverting on
     * overflow (when the input is less than smallest int200 or
     * greater than largest int200).
     *
     * Counterpart to Solidity's `int200` operator.
     *
     * Requirements:
     *
     * - input must fit into 200 bits
     */
    function toInt200(int256 value) internal pure returns (int200 downcasted) {
        downcasted = int200(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(200, value);
        }
    }

    /**
     * @dev Returns the downcasted int192 from int256, reverting on
     * overflow (when the input is less than smallest int192 or
     * greater than largest int192).
     *
     * Counterpart to Solidity's `int192` operator.
     *
     * Requirements:
     *
     * - input must fit into 192 bits
     */
    function toInt192(int256 value) internal pure returns (int192 downcasted) {
        downcasted = int192(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(192, value);
        }
    }

    /**
     * @dev Returns the downcasted int184 from int256, reverting on
     * overflow (when the input is less than smallest int184 or
     * greater than largest int184).
     *
     * Counterpart to Solidity's `int184` operator.
     *
     * Requirements:
     *
     * - input must fit into 184 bits
     */
    function toInt184(int256 value) internal pure returns (int184 downcasted) {
        downcasted = int184(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(184, value);
        }
    }

    /**
     * @dev Returns the downcasted int176 from int256, reverting on
     * overflow (when the input is less than smallest int176 or
     * greater than largest int176).
     *
     * Counterpart to Solidity's `int176` operator.
     *
     * Requirements:
     *
     * - input must fit into 176 bits
     */
    function toInt176(int256 value) internal pure returns (int176 downcasted) {
        downcasted = int176(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(176, value);
        }
    }

    /**
     * @dev Returns the downcasted int168 from int256, reverting on
     * overflow (when the input is less than smallest int168 or
     * greater than largest int168).
     *
     * Counterpart to Solidity's `int168` operator.
     *
     * Requirements:
     *
     * - input must fit into 168 bits
     */
    function toInt168(int256 value) internal pure returns (int168 downcasted) {
        downcasted = int168(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(168, value);
        }
    }

    /**
     * @dev Returns the downcasted int160 from int256, reverting on
     * overflow (when the input is less than smallest int160 or
     * greater than largest int160).
     *
     * Counterpart to Solidity's `int160` operator.
     *
     * Requirements:
     *
     * - input must fit into 160 bits
     */
    function toInt160(int256 value) internal pure returns (int160 downcasted) {
        downcasted = int160(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(160, value);
        }
    }

    /**
     * @dev Returns the downcasted int152 from int256, reverting on
     * overflow (when the input is less than smallest int152 or
     * greater than largest int152).
     *
     * Counterpart to Solidity's `int152` operator.
     *
     * Requirements:
     *
     * - input must fit into 152 bits
     */
    function toInt152(int256 value) internal pure returns (int152 downcasted) {
        downcasted = int152(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(152, value);
        }
    }

    /**
     * @dev Returns the downcasted int144 from int256, reverting on
     * overflow (when the input is less than smallest int144 or
     * greater than largest int144).
     *
     * Counterpart to Solidity's `int144` operator.
     *
     * Requirements:
     *
     * - input must fit into 144 bits
     */
    function toInt144(int256 value) internal pure returns (int144 downcasted) {
        downcasted = int144(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(144, value);
        }
    }

    /**
     * @dev Returns the downcasted int136 from int256, reverting on
     * overflow (when the input is less than smallest int136 or
     * greater than largest int136).
     *
     * Counterpart to Solidity's `int136` operator.
     *
     * Requirements:
     *
     * - input must fit into 136 bits
     */
    function toInt136(int256 value) internal pure returns (int136 downcasted) {
        downcasted = int136(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(136, value);
        }
    }

    /**
     * @dev Returns the downcasted int128 from int256, reverting on
     * overflow (when the input is less than smallest int128 or
     * greater than largest int128).
     *
     * Counterpart to Solidity's `int128` operator.
     *
     * Requirements:
     *
     * - input must fit into 128 bits
     */
    function toInt128(int256 value) internal pure returns (int128 downcasted) {
        downcasted = int128(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(128, value);
        }
    }

    /**
     * @dev Returns the downcasted int120 from int256, reverting on
     * overflow (when the input is less than smallest int120 or
     * greater than largest int120).
     *
     * Counterpart to Solidity's `int120` operator.
     *
     * Requirements:
     *
     * - input must fit into 120 bits
     */
    function toInt120(int256 value) internal pure returns (int120 downcasted) {
        downcasted = int120(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(120, value);
        }
    }

    /**
     * @dev Returns the downcasted int112 from int256, reverting on
     * overflow (when the input is less than smallest int112 or
     * greater than largest int112).
     *
     * Counterpart to Solidity's `int112` operator.
     *
     * Requirements:
     *
     * - input must fit into 112 bits
     */
    function toInt112(int256 value) internal pure returns (int112 downcasted) {
        downcasted = int112(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(112, value);
        }
    }

    /**
     * @dev Returns the downcasted int104 from int256, reverting on
     * overflow (when the input is less than smallest int104 or
     * greater than largest int104).
     *
     * Counterpart to Solidity's `int104` operator.
     *
     * Requirements:
     *
     * - input must fit into 104 bits
     */
    function toInt104(int256 value) internal pure returns (int104 downcasted) {
        downcasted = int104(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(104, value);
        }
    }

    /**
     * @dev Returns the downcasted int96 from int256, reverting on
     * overflow (when the input is less than smallest int96 or
     * greater than largest int96).
     *
     * Counterpart to Solidity's `int96` operator.
     *
     * Requirements:
     *
     * - input must fit into 96 bits
     */
    function toInt96(int256 value) internal pure returns (int96 downcasted) {
        downcasted = int96(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(96, value);
        }
    }

    /**
     * @dev Returns the downcasted int88 from int256, reverting on
     * overflow (when the input is less than smallest int88 or
     * greater than largest int88).
     *
     * Counterpart to Solidity's `int88` operator.
     *
     * Requirements:
     *
     * - input must fit into 88 bits
     */
    function toInt88(int256 value) internal pure returns (int88 downcasted) {
        downcasted = int88(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(88, value);
        }
    }

    /**
     * @dev Returns the downcasted int80 from int256, reverting on
     * overflow (when the input is less than smallest int80 or
     * greater than largest int80).
     *
     * Counterpart to Solidity's `int80` operator.
     *
     * Requirements:
     *
     * - input must fit into 80 bits
     */
    function toInt80(int256 value) internal pure returns (int80 downcasted) {
        downcasted = int80(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(80, value);
        }
    }

    /**
     * @dev Returns the downcasted int72 from int256, reverting on
     * overflow (when the input is less than smallest int72 or
     * greater than largest int72).
     *
     * Counterpart to Solidity's `int72` operator.
     *
     * Requirements:
     *
     * - input must fit into 72 bits
     */
    function toInt72(int256 value) internal pure returns (int72 downcasted) {
        downcasted = int72(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(72, value);
        }
    }

    /**
     * @dev Returns the downcasted int64 from int256, reverting on
     * overflow (when the input is less than smallest int64 or
     * greater than largest int64).
     *
     * Counterpart to Solidity's `int64` operator.
     *
     * Requirements:
     *
     * - input must fit into 64 bits
     */
    function toInt64(int256 value) internal pure returns (int64 downcasted) {
        downcasted = int64(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(64, value);
        }
    }

    /**
     * @dev Returns the downcasted int56 from int256, reverting on
     * overflow (when the input is less than smallest int56 or
     * greater than largest int56).
     *
     * Counterpart to Solidity's `int56` operator.
     *
     * Requirements:
     *
     * - input must fit into 56 bits
     */
    function toInt56(int256 value) internal pure returns (int56 downcasted) {
        downcasted = int56(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(56, value);
        }
    }

    /**
     * @dev Returns the downcasted int48 from int256, reverting on
     * overflow (when the input is less than smallest int48 or
     * greater than largest int48).
     *
     * Counterpart to Solidity's `int48` operator.
     *
     * Requirements:
     *
     * - input must fit into 48 bits
     */
    function toInt48(int256 value) internal pure returns (int48 downcasted) {
        downcasted = int48(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(48, value);
        }
    }

    /**
     * @dev Returns the downcasted int40 from int256, reverting on
     * overflow (when the input is less than smallest int40 or
     * greater than largest int40).
     *
     * Counterpart to Solidity's `int40` operator.
     *
     * Requirements:
     *
     * - input must fit into 40 bits
     */
    function toInt40(int256 value) internal pure returns (int40 downcasted) {
        downcasted = int40(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(40, value);
        }
    }

    /**
     * @dev Returns the downcasted int32 from int256, reverting on
     * overflow (when the input is less than smallest int32 or
     * greater than largest int32).
     *
     * Counterpart to Solidity's `int32` operator.
     *
     * Requirements:
     *
     * - input must fit into 32 bits
     */
    function toInt32(int256 value) internal pure returns (int32 downcasted) {
        downcasted = int32(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(32, value);
        }
    }

    /**
     * @dev Returns the downcasted int24 from int256, reverting on
     * overflow (when the input is less than smallest int24 or
     * greater than largest int24).
     *
     * Counterpart to Solidity's `int24` operator.
     *
     * Requirements:
     *
     * - input must fit into 24 bits
     */
    function toInt24(int256 value) internal pure returns (int24 downcasted) {
        downcasted = int24(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(24, value);
        }
    }

    /**
     * @dev Returns the downcasted int16 from int256, reverting on
     * overflow (when the input is less than smallest int16 or
     * greater than largest int16).
     *
     * Counterpart to Solidity's `int16` operator.
     *
     * Requirements:
     *
     * - input must fit into 16 bits
     */
    function toInt16(int256 value) internal pure returns (int16 downcasted) {
        downcasted = int16(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(16, value);
        }
    }

    /**
     * @dev Returns the downcasted int8 from int256, reverting on
     * overflow (when the input is less than smallest int8 or
     * greater than largest int8).
     *
     * Counterpart to Solidity's `int8` operator.
     *
     * Requirements:
     *
     * - input must fit into 8 bits
     */
    function toInt8(int256 value) internal pure returns (int8 downcasted) {
        downcasted = int8(value);
        if (downcasted != value) {
            revert SafeCastOverflowedIntDowncast(8, value);
        }
    }

    /**
     * @dev Converts an unsigned uint256 into a signed int256.
     *
     * Requirements:
     *
     * - input must be less than or equal to maxInt256.
     */
    function toInt256(uint256 value) internal pure returns (int256) {
        // Note: Unsafe cast below is okay because `type(int256).max` is guaranteed to be positive
        if (value > uint256(type(int256).max)) {
            revert SafeCastOverflowedUintToInt(value);
        }
        return int256(value);
    }

    /**
     * @dev Cast a boolean (false or true) to a uint256 (0 or 1) with no jump.
     */
    function toUint(bool b) internal pure returns (uint256 u) {
        assembly ("memory-safe") {
            u := iszero(iszero(b))
        }
    }
}

// contracts/interfaces/IPriceOracle.sol

/// @title IPriceOracle
/// @author kexley, Cap Labs
/// @notice Interface for the price oracle
interface IPriceOracle is IOracleTypes {
    /// @notice Storage for the price oracle
    /// @param oracleData Oracle data for each asset
    /// @param backupOracleData Backup oracle data for each asset
    /// @param staleness Staleness period for each asset
    struct PriceOracleStorage {
        mapping(address => IOracleTypes.OracleData) oracleData;
        mapping(address => IOracleTypes.OracleData) backupOracleData;
        mapping(address => uint256) staleness;
    }

    /// @dev Set oracle data
    event SetPriceOracleData(address asset, IOracleTypes.OracleData data);

    /// @dev Set backup oracle data
    event SetPriceBackupOracleData(address asset, IOracleTypes.OracleData data);

    /// @dev Set the staleness period for asset prices
    event SetStaleness(address asset, uint256 staleness);

    /// @dev Price error
    error PriceError(address asset);

    /// @notice Set the oracle data for an asset
    /// @param _asset Asset address to set oracle data for
    /// @param _oracleData Oracle data configuration to set for the asset
    function setPriceOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData) external;

    /// @notice Set the backup oracle data for an asset
    /// @param _asset Asset address to set backup oracle data for
    /// @param _oracleData Backup oracle data configuration to set for the asset
    function setPriceBackupOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData) external;

    /// @notice Set the staleness period for asset prices
    /// @param _asset Asset address to set staleness period for
    /// @param _staleness Staleness period in seconds for asset prices
    function setStaleness(address _asset, uint256 _staleness) external;

    /// @notice Get the price for an asset
    /// @param _asset Asset address to get price for
    /// @return price Current price of the asset
    /// @return lastUpdated Last updated timestamp
    function getPrice(address _asset) external view returns (uint256 price, uint256 lastUpdated);

    /// @notice View the oracle data for an asset
    /// @param _asset Asset address to get oracle data for
    /// @return data Oracle data configuration for the asset
    function priceOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data);

    /// @notice View the backup oracle data for an asset
    /// @param _asset Asset address to get backup oracle data for
    /// @return data Backup oracle data configuration for the asset
    function priceBackupOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data);

    /// @notice View the staleness period for asset prices
    /// @param _asset Asset address to get staleness period for
    /// @return assetStaleness Staleness period in seconds for asset prices
    function staleness(address _asset) external view returns (uint256 assetStaleness);
}

// contracts/interfaces/IRateOracle.sol

/// @title IRateOracle
/// @author kexley, Cap Labs
/// @notice Interface for the rate oracle
interface IRateOracle is IOracleTypes {
    /// @dev Storage for the rate oracle
    /// @param marketOracleData Oracle data for the market rate
    /// @param utilizationOracleData Oracle data for the utilization rate
    /// @param benchmarkRate Benchmark rate for each asset
    /// @param restakerRate Restaker rate for each agent
    struct RateOracleStorage {
        mapping(address => IOracleTypes.OracleData) marketOracleData;
        mapping(address => IOracleTypes.OracleData) utilizationOracleData;
        mapping(address => uint256) benchmarkRate;
        mapping(address => uint256) restakerRate;
    }

    /// @dev Set market oracle data
    event SetMarketOracleData(address asset, IOracleTypes.OracleData data);

    /// @dev Set utilization oracle data
    event SetUtilizationOracleData(address asset, IOracleTypes.OracleData data);

    /// @dev Set benchmark rate
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    event SetBenchmarkRate(address asset, uint256 rate);

    /// @dev Set restaker rate
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    event SetRestakerRate(address agent, uint256 rate);

    /// @notice Set a market source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setMarketOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData) external;

    /// @notice Set a utilization source for an asset
    /// @param _asset Asset address
    /// @param _oracleData Oracle data
    function setUtilizationOracleData(address _asset, IOracleTypes.OracleData calldata _oracleData) external;

    /// @notice Update the minimum interest rate for an asset
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    /// @param _asset Asset address
    /// @param _rate New interest rate
    function setBenchmarkRate(address _asset, uint256 _rate) external;

    /// @notice Update the rate at which an agent accrues interest explicitly to pay restakers
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    /// @param _agent Agent address
    /// @param _rate New interest rate
    function setRestakerRate(address _agent, uint256 _rate) external;

    /// @notice Fetch the market rate for an asset being borrowed
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    /// @param _asset Asset address
    /// @return rate Borrow interest rate
    function marketRate(address _asset) external returns (uint256 rate);

    /// @notice View the utilization rate for an asset
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    /// @param _asset Asset address
    /// @return rate Utilization rate
    function utilizationRate(address _asset) external returns (uint256 rate);

    /// @notice View the benchmark rate for an asset
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    /// @param _asset Asset address
    /// @return rate Benchmark rate
    function benchmarkRate(address _asset) external view returns (uint256 rate);

    /// @notice View the restaker rate for an agent
    /// @dev Rate value is encoded in ray (27 decimals) and encodes yearly rates
    /// @param _agent Agent address
    /// @return rate Restaker rate
    function restakerRate(address _agent) external view returns (uint256 rate);

    /// @notice View the market oracle data for an asset
    /// @param _asset Asset address
    /// @return data Oracle data for an asset
    function marketOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data);

    /// @notice View the utilization oracle data for an asset
    /// @param _asset Asset address
    /// @return data Oracle data for an asset
    function utilizationOracleData(address _asset) external view returns (IOracleTypes.OracleData memory data);
}

// contracts/lendingPool/libraries/configuration/AgentConfiguration.sol

/// @title AgentConfiguration library
/// @author kexley, Cap Labs
/// @notice Implements the bitmap logic to handle the agent configuration
library AgentConfiguration {
    /// @dev Invalid reserve index
    error InvalidReserveIndex();

    /// @notice Sets if the user is borrowing the reserve identified by reserveIndex
    /// @param self The configuration object
    /// @param reserveIndex The index of the reserve in the bitmap
    /// @param borrowing True if the user is borrowing the reserve, false otherwise
    function setBorrowing(ILender.AgentConfigurationMap storage self, uint256 reserveIndex, bool borrowing) internal {
        unchecked {
            if (reserveIndex >= 256) revert InvalidReserveIndex();
            uint256 bit = 1 << (reserveIndex << 1);
            if (borrowing) {
                self.data |= bit;
            } else {
                self.data &= ~bit;
            }
        }
    }

    /// @notice Validate a user has been using the reserve for borrowing
    /// @param self The configuration object
    /// @param reserveIndex The index of the reserve in the bitmap
    /// @return True if the user has been using a reserve for borrowing, false otherwise
    function isBorrowing(ILender.AgentConfigurationMap memory self, uint256 reserveIndex)
        internal
        pure
        returns (bool)
    {
        unchecked {
            if (reserveIndex >= 256) revert InvalidReserveIndex();
            return (self.data >> (reserveIndex << 1)) & 1 != 0;
        }
    }
}

// node_modules/@openzeppelin/contracts/interfaces/IERC165.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC165.sol)

// node_modules/@openzeppelin/contracts/interfaces/IERC20.sol

// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC20.sol)

// node_modules/@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol

// OpenZeppelin Contracts (last updated v5.1.0) (token/ERC20/extensions/IERC20Metadata.sol)

/**
 * @dev Interface for the optional metadata functions from the ERC-20 standard.
 */
interface IERC20Metadata is IERC20 {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

// contracts/interfaces/IDebtToken.sol

/// @title IDebtToken
/// @author kexley, Cap Labs
/// @notice Interface for the DebtToken contract
interface IDebtToken is IERC20Metadata {
    /// @dev Debt token storage
    /// @param asset Asset address
    /// @param oracle Oracle address
    /// @param index Index
    /// @param lastIndexUpdate Last index update
    /// @param interestRate Interest rate
    struct DebtTokenStorage {
        address asset;
        address oracle;
        uint256 index;
        uint256 lastIndexUpdate;
        uint256 interestRate;
    }

    /// @notice Initialize the debt token
    /// @param _accessControl Access control address
    /// @param _asset Asset address
    /// @param _oracle Oracle address
    function initialize(address _accessControl, address _asset, address _oracle) external;

    /// @notice Lender will mint debt tokens to match the amount debt owed by an agent
    /// @param to Address to mint tokens to
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external;

    /// @notice Lender will burn debt tokens when the debt is repaid by an agent
    /// @param from Burn tokens from agent
    /// @param amount Amount to burn
    function burn(address from, uint256 amount) external;

    /// @notice Get the current index
    /// @return currentIndex The current index
    function index() external view returns (uint256 currentIndex);
}

// node_modules/@openzeppelin/contracts/utils/math/Math.sol

// OpenZeppelin Contracts (last updated v5.3.0) (utils/math/Math.sol)

/**
 * @dev Standard math utilities missing in the Solidity language.
 */
library Math {
    enum Rounding {
        Floor, // Toward negative infinity
        Ceil, // Toward positive infinity
        Trunc, // Toward zero
        Expand // Away from zero

    }

    /**
     * @dev Return the 512-bit addition of two uint256.
     *
     * The result is stored in two 256 variables such that sum = high * 2²⁵⁶ + low.
     */
    function add512(uint256 a, uint256 b) internal pure returns (uint256 high, uint256 low) {
        assembly ("memory-safe") {
            low := add(a, b)
            high := lt(low, a)
        }
    }

    /**
     * @dev Return the 512-bit multiplication of two uint256.
     *
     * The result is stored in two 256 variables such that product = high * 2²⁵⁶ + low.
     */
    function mul512(uint256 a, uint256 b) internal pure returns (uint256 high, uint256 low) {
        // 512-bit multiply [high low] = x * y. Compute the product mod 2²⁵⁶ and mod 2²⁵⁶ - 1, then use
        // the Chinese Remainder Theorem to reconstruct the 512 bit result. The result is stored in two 256
        // variables such that product = high * 2²⁵⁶ + low.
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }

    /**
     * @dev Returns the addition of two unsigned integers, with a success flag (no overflow).
     */
    function tryAdd(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a + b;
            success = c >= a;
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the subtraction of two unsigned integers, with a success flag (no overflow).
     */
    function trySub(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a - b;
            success = c <= a;
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the multiplication of two unsigned integers, with a success flag (no overflow).
     */
    function tryMul(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            uint256 c = a * b;
            assembly ("memory-safe") {
                // Only true when the multiplication doesn't overflow
                // (c / a == b) || (a == 0)
                success := or(eq(div(c, a), b), iszero(a))
            }
            // equivalent to: success ? c : 0
            result = c * SafeCast.toUint(success);
        }
    }

    /**
     * @dev Returns the division of two unsigned integers, with a success flag (no division by zero).
     */
    function tryDiv(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            success = b > 0;
            assembly ("memory-safe") {
                // The `DIV` opcode returns zero when the denominator is 0.
                result := div(a, b)
            }
        }
    }

    /**
     * @dev Returns the remainder of dividing two unsigned integers, with a success flag (no division by zero).
     */
    function tryMod(uint256 a, uint256 b) internal pure returns (bool success, uint256 result) {
        unchecked {
            success = b > 0;
            assembly ("memory-safe") {
                // The `MOD` opcode returns zero when the denominator is 0.
                result := mod(a, b)
            }
        }
    }

    /**
     * @dev Unsigned saturating addition, bounds to `2²⁵⁶ - 1` instead of overflowing.
     */
    function saturatingAdd(uint256 a, uint256 b) internal pure returns (uint256) {
        (bool success, uint256 result) = tryAdd(a, b);
        return ternary(success, result, type(uint256).max);
    }

    /**
     * @dev Unsigned saturating subtraction, bounds to zero instead of overflowing.
     */
    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        (, uint256 result) = trySub(a, b);
        return result;
    }

    /**
     * @dev Unsigned saturating multiplication, bounds to `2²⁵⁶ - 1` instead of overflowing.
     */
    function saturatingMul(uint256 a, uint256 b) internal pure returns (uint256) {
        (bool success, uint256 result) = tryMul(a, b);
        return ternary(success, result, type(uint256).max);
    }

    /**
     * @dev Branchless ternary evaluation for `a ? b : c`. Gas costs are constant.
     *
     * IMPORTANT: This function may reduce bytecode size and consume less gas when used standalone.
     * However, the compiler may optimize Solidity ternary operations (i.e. `a ? b : c`) to only compute
     * one branch when needed, making this function more expensive.
     */
    function ternary(bool condition, uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            // branchless ternary works because:
            // b ^ (a ^ b) == a
            // b ^ 0 == b
            return b ^ ((a ^ b) * SafeCast.toUint(condition));
        }
    }

    /**
     * @dev Returns the largest of two numbers.
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return ternary(a > b, a, b);
    }

    /**
     * @dev Returns the smallest of two numbers.
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return ternary(a < b, a, b);
    }

    /**
     * @dev Returns the average of two numbers. The result is rounded towards
     * zero.
     */
    function average(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b) / 2 can overflow.
        return (a & b) + (a ^ b) / 2;
    }

    /**
     * @dev Returns the ceiling of the division of two numbers.
     *
     * This differs from standard division with `/` in that it rounds towards infinity instead
     * of rounding towards zero.
     */
    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b == 0) {
            // Guarantee the same behavior as in a regular Solidity division.
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }

        // The following calculation ensures accurate ceiling division without overflow.
        // Since a is non-zero, (a - 1) / b will not overflow.
        // The largest possible result occurs when (a - 1) / b is type(uint256).max,
        // but the largest value we can obtain is type(uint256).max - 1, which happens
        // when a = type(uint256).max and b = 1.
        unchecked {
            return SafeCast.toUint(a > 0) * ((a - 1) / b + 1);
        }
    }

    /**
     * @dev Calculates floor(x * y / denominator) with full precision. Throws if result overflows a uint256 or
     * denominator == 0.
     *
     * Original credit to Remco Bloemen under MIT license (https://xn--2-umb.com/21/muldiv) with further edits by
     * Uniswap Labs also under MIT license.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            (uint256 high, uint256 low) = mul512(x, y);

            // Handle non-overflow cases, 256 by 256 division.
            if (high == 0) {
                // Solidity will revert if denominator == 0, unlike the div opcode on its own.
                // The surrounding unchecked block does not change this fact.
                // See https://docs.soliditylang.org/en/latest/control-structures.html#checked-or-unchecked-arithmetic.
                return low / denominator;
            }

            // Make sure the result is less than 2²⁵⁶. Also prevents denominator == 0.
            if (denominator <= high) {
                Panic.panic(ternary(denominator == 0, Panic.DIVISION_BY_ZERO, Panic.UNDER_OVERFLOW));
            }

            ///////////////////////////////////////////////
            // 512 by 256 division.
            ///////////////////////////////////////////////

            // Make division exact by subtracting the remainder from [high low].
            uint256 remainder;
            assembly ("memory-safe") {
                // Compute remainder using mulmod.
                remainder := mulmod(x, y, denominator)

                // Subtract 256 bit number from 512 bit number.
                high := sub(high, gt(remainder, low))
                low := sub(low, remainder)
            }

            // Factor powers of two out of denominator and compute largest power of two divisor of denominator.
            // Always >= 1. See https://cs.stackexchange.com/q/138556/92363.

            uint256 twos = denominator & (0 - denominator);
            assembly ("memory-safe") {
                // Divide denominator by twos.
                denominator := div(denominator, twos)

                // Divide [high low] by twos.
                low := div(low, twos)

                // Flip twos such that it is 2²⁵⁶ / twos. If twos is zero, then it becomes one.
                twos := add(div(sub(0, twos), twos), 1)
            }

            // Shift in bits from high into low.
            low |= high * twos;

            // Invert denominator mod 2²⁵⁶. Now that denominator is an odd number, it has an inverse modulo 2²⁵⁶ such
            // that denominator * inv ≡ 1 mod 2²⁵⁶. Compute the inverse by starting with a seed that is correct for
            // four bits. That is, denominator * inv ≡ 1 mod 2⁴.
            uint256 inverse = (3 * denominator) ^ 2;

            // Use the Newton-Raphson iteration to improve the precision. Thanks to Hensel's lifting lemma, this also
            // works in modular arithmetic, doubling the correct bits in each step.
            inverse *= 2 - denominator * inverse; // inverse mod 2⁸
            inverse *= 2 - denominator * inverse; // inverse mod 2¹⁶
            inverse *= 2 - denominator * inverse; // inverse mod 2³²
            inverse *= 2 - denominator * inverse; // inverse mod 2⁶⁴
            inverse *= 2 - denominator * inverse; // inverse mod 2¹²⁸
            inverse *= 2 - denominator * inverse; // inverse mod 2²⁵⁶

            // Because the division is now exact we can divide by multiplying with the modular inverse of denominator.
            // This will give us the correct result modulo 2²⁵⁶. Since the preconditions guarantee that the outcome is
            // less than 2²⁵⁶, this is the final result. We don't need to compute the high bits of the result and high
            // is no longer required.
            result = low * inverse;
            return result;
        }
    }

    /**
     * @dev Calculates x * y / denominator with full precision, following the selected rounding direction.
     */
    function mulDiv(uint256 x, uint256 y, uint256 denominator, Rounding rounding) internal pure returns (uint256) {
        return mulDiv(x, y, denominator) + SafeCast.toUint(unsignedRoundsUp(rounding) && mulmod(x, y, denominator) > 0);
    }

    /**
     * @dev Calculates floor(x * y >> n) with full precision. Throws if result overflows a uint256.
     */
    function mulShr(uint256 x, uint256 y, uint8 n) internal pure returns (uint256 result) {
        unchecked {
            (uint256 high, uint256 low) = mul512(x, y);
            if (high >= 1 << n) {
                Panic.panic(Panic.UNDER_OVERFLOW);
            }
            return (high << (256 - n)) | (low >> n);
        }
    }

    /**
     * @dev Calculates x * y >> n with full precision, following the selected rounding direction.
     */
    function mulShr(uint256 x, uint256 y, uint8 n, Rounding rounding) internal pure returns (uint256) {
        return mulShr(x, y, n) + SafeCast.toUint(unsignedRoundsUp(rounding) && mulmod(x, y, 1 << n) > 0);
    }

    /**
     * @dev Calculate the modular multiplicative inverse of a number in Z/nZ.
     *
     * If n is a prime, then Z/nZ is a field. In that case all elements are inversible, except 0.
     * If n is not a prime, then Z/nZ is not a field, and some elements might not be inversible.
     *
     * If the input value is not inversible, 0 is returned.
     *
     * NOTE: If you know for sure that n is (big) a prime, it may be cheaper to use Fermat's little theorem and get the
     * inverse using `Math.modExp(a, n - 2, n)`. See {invModPrime}.
     */
    function invMod(uint256 a, uint256 n) internal pure returns (uint256) {
        unchecked {
            if (n == 0) return 0;

            // The inverse modulo is calculated using the Extended Euclidean Algorithm (iterative version)
            // Used to compute integers x and y such that: ax + ny = gcd(a, n).
            // When the gcd is 1, then the inverse of a modulo n exists and it's x.
            // ax + ny = 1
            // ax = 1 + (-y)n
            // ax ≡ 1 (mod n) # x is the inverse of a modulo n

            // If the remainder is 0 the gcd is n right away.
            uint256 remainder = a % n;
            uint256 gcd = n;

            // Therefore the initial coefficients are:
            // ax + ny = gcd(a, n) = n
            // 0a + 1n = n
            int256 x = 0;
            int256 y = 1;

            while (remainder != 0) {
                uint256 quotient = gcd / remainder;

                (gcd, remainder) = (
                    // The old remainder is the next gcd to try.
                    remainder,
                    // Compute the next remainder.
                    // Can't overflow given that (a % gcd) * (gcd // (a % gcd)) <= gcd
                    // where gcd is at most n (capped to type(uint256).max)
                    gcd - remainder * quotient
                );

                (x, y) = (
                    // Increment the coefficient of a.
                    y,
                    // Decrement the coefficient of n.
                    // Can overflow, but the result is casted to uint256 so that the
                    // next value of y is "wrapped around" to a value between 0 and n - 1.
                    x - y * int256(quotient)
                );
            }

            if (gcd != 1) return 0; // No inverse exists.
            return ternary(x < 0, n - uint256(-x), uint256(x)); // Wrap the result if it's negative.
        }
    }

    /**
     * @dev Variant of {invMod}. More efficient, but only works if `p` is known to be a prime greater than `2`.
     *
     * From https://en.wikipedia.org/wiki/Fermat%27s_little_theorem[Fermat's little theorem], we know that if p is
     * prime, then `a**(p-1) ≡ 1 mod p`. As a consequence, we have `a * a**(p-2) ≡ 1 mod p`, which means that
     * `a**(p-2)` is the modular multiplicative inverse of a in Fp.
     *
     * NOTE: this function does NOT check that `p` is a prime greater than `2`.
     */
    function invModPrime(uint256 a, uint256 p) internal view returns (uint256) {
        unchecked {
            return Math.modExp(a, p - 2, p);
        }
    }

    /**
     * @dev Returns the modular exponentiation of the specified base, exponent and modulus (b ** e % m)
     *
     * Requirements:
     * - modulus can't be zero
     * - underlying staticcall to precompile must succeed
     *
     * IMPORTANT: The result is only valid if the underlying call succeeds. When using this function, make
     * sure the chain you're using it on supports the precompiled contract for modular exponentiation
     * at address 0x05 as specified in https://eips.ethereum.org/EIPS/eip-198[EIP-198]. Otherwise,
     * the underlying function will succeed given the lack of a revert, but the result may be incorrectly
     * interpreted as 0.
     */
    function modExp(uint256 b, uint256 e, uint256 m) internal view returns (uint256) {
        (bool success, uint256 result) = tryModExp(b, e, m);
        if (!success) {
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }
        return result;
    }

    /**
     * @dev Returns the modular exponentiation of the specified base, exponent and modulus (b ** e % m).
     * It includes a success flag indicating if the operation succeeded. Operation will be marked as failed if trying
     * to operate modulo 0 or if the underlying precompile reverted.
     *
     * IMPORTANT: The result is only valid if the success flag is true. When using this function, make sure the chain
     * you're using it on supports the precompiled contract for modular exponentiation at address 0x05 as specified in
     * https://eips.ethereum.org/EIPS/eip-198[EIP-198]. Otherwise, the underlying function will succeed given the lack
     * of a revert, but the result may be incorrectly interpreted as 0.
     */
    function tryModExp(uint256 b, uint256 e, uint256 m) internal view returns (bool success, uint256 result) {
        if (m == 0) return (false, 0);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            // | Offset    | Content    | Content (Hex)                                                      |
            // |-----------|------------|--------------------------------------------------------------------|
            // | 0x00:0x1f | size of b  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x20:0x3f | size of e  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x40:0x5f | size of m  | 0x0000000000000000000000000000000000000000000000000000000000000020 |
            // | 0x60:0x7f | value of b | 0x<.............................................................b> |
            // | 0x80:0x9f | value of e | 0x<.............................................................e> |
            // | 0xa0:0xbf | value of m | 0x<.............................................................m> |
            mstore(ptr, 0x20)
            mstore(add(ptr, 0x20), 0x20)
            mstore(add(ptr, 0x40), 0x20)
            mstore(add(ptr, 0x60), b)
            mstore(add(ptr, 0x80), e)
            mstore(add(ptr, 0xa0), m)

            // Given the result < m, it's guaranteed to fit in 32 bytes,
            // so we can use the memory scratch space located at offset 0.
            success := staticcall(gas(), 0x05, ptr, 0xc0, 0x00, 0x20)
            result := mload(0x00)
        }
    }

    /**
     * @dev Variant of {modExp} that supports inputs of arbitrary length.
     */
    function modExp(bytes memory b, bytes memory e, bytes memory m) internal view returns (bytes memory) {
        (bool success, bytes memory result) = tryModExp(b, e, m);
        if (!success) {
            Panic.panic(Panic.DIVISION_BY_ZERO);
        }
        return result;
    }

    /**
     * @dev Variant of {tryModExp} that supports inputs of arbitrary length.
     */
    function tryModExp(bytes memory b, bytes memory e, bytes memory m)
        internal
        view
        returns (bool success, bytes memory result)
    {
        if (_zeroBytes(m)) return (false, new bytes(0));

        uint256 mLen = m.length;

        // Encode call args in result and move the free memory pointer
        result = abi.encodePacked(b.length, e.length, mLen, b, e, m);

        assembly ("memory-safe") {
            let dataPtr := add(result, 0x20)
            // Write result on top of args to avoid allocating extra memory.
            success := staticcall(gas(), 0x05, dataPtr, mload(result), dataPtr, mLen)
            // Overwrite the length.
            // result.length > returndatasize() is guaranteed because returndatasize() == m.length
            mstore(result, mLen)
            // Set the memory pointer after the returned data.
            mstore(0x40, add(dataPtr, mLen))
        }
    }

    /**
     * @dev Returns whether the provided byte array is zero.
     */
    function _zeroBytes(bytes memory byteArray) private pure returns (bool) {
        for (uint256 i = 0; i < byteArray.length; ++i) {
            if (byteArray[i] != 0) {
                return false;
            }
        }
        return true;
    }

    /**
     * @dev Returns the square root of a number. If the number is not a perfect square, the value is rounded
     * towards zero.
     *
     * This method is based on Newton's method for computing square roots; the algorithm is restricted to only
     * using integer operations.
     */
    function sqrt(uint256 a) internal pure returns (uint256) {
        unchecked {
            // Take care of easy edge cases when a == 0 or a == 1
            if (a <= 1) {
                return a;
            }

            // In this function, we use Newton's method to get a root of `f(x) := x² - a`. It involves building a
            // sequence x_n that converges toward sqrt(a). For each iteration x_n, we also define the error between
            // the current value as `ε_n = | x_n - sqrt(a) |`.
            //
            // For our first estimation, we consider `e` the smallest power of 2 which is bigger than the square root
            // of the target. (i.e. `2**(e-1) ≤ sqrt(a) < 2**e`). We know that `e ≤ 128` because `(2¹²⁸)² = 2²⁵⁶` is
            // bigger than any uint256.
            //
            // By noticing that
            // `2**(e-1) ≤ sqrt(a) < 2**e → (2**(e-1))² ≤ a < (2**e)² → 2**(2*e-2) ≤ a < 2**(2*e)`
            // we can deduce that `e - 1` is `log2(a) / 2`. We can thus compute `x_n = 2**(e-1)` using a method similar
            // to the msb function.
            uint256 aa = a;
            uint256 xn = 1;

            if (aa >= (1 << 128)) {
                aa >>= 128;
                xn <<= 64;
            }
            if (aa >= (1 << 64)) {
                aa >>= 64;
                xn <<= 32;
            }
            if (aa >= (1 << 32)) {
                aa >>= 32;
                xn <<= 16;
            }
            if (aa >= (1 << 16)) {
                aa >>= 16;
                xn <<= 8;
            }
            if (aa >= (1 << 8)) {
                aa >>= 8;
                xn <<= 4;
            }
            if (aa >= (1 << 4)) {
                aa >>= 4;
                xn <<= 2;
            }
            if (aa >= (1 << 2)) {
                xn <<= 1;
            }

            // We now have x_n such that `x_n = 2**(e-1) ≤ sqrt(a) < 2**e = 2 * x_n`. This implies ε_n ≤ 2**(e-1).
            //
            // We can refine our estimation by noticing that the middle of that interval minimizes the error.
            // If we move x_n to equal 2**(e-1) + 2**(e-2), then we reduce the error to ε_n ≤ 2**(e-2).
            // This is going to be our x_0 (and ε_0)
            xn = (3 * xn) >> 1; // ε_0 := | x_0 - sqrt(a) | ≤ 2**(e-2)

            // From here, Newton's method give us:
            // x_{n+1} = (x_n + a / x_n) / 2
            //
            // One should note that:
            // x_{n+1}² - a = ((x_n + a / x_n) / 2)² - a
            //              = ((x_n² + a) / (2 * x_n))² - a
            //              = (x_n⁴ + 2 * a * x_n² + a²) / (4 * x_n²) - a
            //              = (x_n⁴ + 2 * a * x_n² + a² - 4 * a * x_n²) / (4 * x_n²)
            //              = (x_n⁴ - 2 * a * x_n² + a²) / (4 * x_n²)
            //              = (x_n² - a)² / (2 * x_n)²
            //              = ((x_n² - a) / (2 * x_n))²
            //              ≥ 0
            // Which proves that for all n ≥ 1, sqrt(a) ≤ x_n
            //
            // This gives us the proof of quadratic convergence of the sequence:
            // ε_{n+1} = | x_{n+1} - sqrt(a) |
            //         = | (x_n + a / x_n) / 2 - sqrt(a) |
            //         = | (x_n² + a - 2*x_n*sqrt(a)) / (2 * x_n) |
            //         = | (x_n - sqrt(a))² / (2 * x_n) |
            //         = | ε_n² / (2 * x_n) |
            //         = ε_n² / | (2 * x_n) |
            //
            // For the first iteration, we have a special case where x_0 is known:
            // ε_1 = ε_0² / | (2 * x_0) |
            //     ≤ (2**(e-2))² / (2 * (2**(e-1) + 2**(e-2)))
            //     ≤ 2**(2*e-4) / (3 * 2**(e-1))
            //     ≤ 2**(e-3) / 3
            //     ≤ 2**(e-3-log2(3))
            //     ≤ 2**(e-4.5)
            //
            // For the following iterations, we use the fact that, 2**(e-1) ≤ sqrt(a) ≤ x_n:
            // ε_{n+1} = ε_n² / | (2 * x_n) |
            //         ≤ (2**(e-k))² / (2 * 2**(e-1))
            //         ≤ 2**(2*e-2*k) / 2**e
            //         ≤ 2**(e-2*k)
            xn = (xn + a / xn) >> 1; // ε_1 := | x_1 - sqrt(a) | ≤ 2**(e-4.5)  -- special case, see above
            xn = (xn + a / xn) >> 1; // ε_2 := | x_2 - sqrt(a) | ≤ 2**(e-9)    -- general case with k = 4.5
            xn = (xn + a / xn) >> 1; // ε_3 := | x_3 - sqrt(a) | ≤ 2**(e-18)   -- general case with k = 9
            xn = (xn + a / xn) >> 1; // ε_4 := | x_4 - sqrt(a) | ≤ 2**(e-36)   -- general case with k = 18
            xn = (xn + a / xn) >> 1; // ε_5 := | x_5 - sqrt(a) | ≤ 2**(e-72)   -- general case with k = 36
            xn = (xn + a / xn) >> 1; // ε_6 := | x_6 - sqrt(a) | ≤ 2**(e-144)  -- general case with k = 72

            // Because e ≤ 128 (as discussed during the first estimation phase), we know have reached a precision
            // ε_6 ≤ 2**(e-144) < 1. Given we're operating on integers, then we can ensure that xn is now either
            // sqrt(a) or sqrt(a) + 1.
            return xn - SafeCast.toUint(xn > a / xn);
        }
    }

    /**
     * @dev Calculates sqrt(a), following the selected rounding direction.
     */
    function sqrt(uint256 a, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = sqrt(a);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && result * result < a);
        }
    }

    /**
     * @dev Return the log in base 2 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log2(uint256 x) internal pure returns (uint256 r) {
        // If value has upper 128 bits set, log2 result is at least 128
        r = SafeCast.toUint(x > 0xffffffffffffffffffffffffffffffff) << 7;
        // If upper 64 bits of 128-bit half set, add 64 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffffffffffff) << 6;
        // If upper 32 bits of 64-bit half set, add 32 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffff) << 5;
        // If upper 16 bits of 32-bit half set, add 16 to result
        r |= SafeCast.toUint((x >> r) > 0xffff) << 4;
        // If upper 8 bits of 16-bit half set, add 8 to result
        r |= SafeCast.toUint((x >> r) > 0xff) << 3;
        // If upper 4 bits of 8-bit half set, add 4 to result
        r |= SafeCast.toUint((x >> r) > 0xf) << 2;

        // Shifts value right by the current result and use it as an index into this lookup table:
        //
        // | x (4 bits) |  index  | table[index] = MSB position |
        // |------------|---------|-----------------------------|
        // |    0000    |    0    |        table[0] = 0         |
        // |    0001    |    1    |        table[1] = 0         |
        // |    0010    |    2    |        table[2] = 1         |
        // |    0011    |    3    |        table[3] = 1         |
        // |    0100    |    4    |        table[4] = 2         |
        // |    0101    |    5    |        table[5] = 2         |
        // |    0110    |    6    |        table[6] = 2         |
        // |    0111    |    7    |        table[7] = 2         |
        // |    1000    |    8    |        table[8] = 3         |
        // |    1001    |    9    |        table[9] = 3         |
        // |    1010    |   10    |        table[10] = 3        |
        // |    1011    |   11    |        table[11] = 3        |
        // |    1100    |   12    |        table[12] = 3        |
        // |    1101    |   13    |        table[13] = 3        |
        // |    1110    |   14    |        table[14] = 3        |
        // |    1111    |   15    |        table[15] = 3        |
        //
        // The lookup table is represented as a 32-byte value with the MSB positions for 0-15 in the last 16 bytes.
        assembly ("memory-safe") {
            r := or(r, byte(shr(r, x), 0x0000010102020202030303030303030300000000000000000000000000000000))
        }
    }

    /**
     * @dev Return the log in base 2, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log2(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log2(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 1 << result < value);
        }
    }

    /**
     * @dev Return the log in base 10 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     */
    function log10(uint256 value) internal pure returns (uint256) {
        uint256 result = 0;
        unchecked {
            if (value >= 10 ** 64) {
                value /= 10 ** 64;
                result += 64;
            }
            if (value >= 10 ** 32) {
                value /= 10 ** 32;
                result += 32;
            }
            if (value >= 10 ** 16) {
                value /= 10 ** 16;
                result += 16;
            }
            if (value >= 10 ** 8) {
                value /= 10 ** 8;
                result += 8;
            }
            if (value >= 10 ** 4) {
                value /= 10 ** 4;
                result += 4;
            }
            if (value >= 10 ** 2) {
                value /= 10 ** 2;
                result += 2;
            }
            if (value >= 10 ** 1) {
                result += 1;
            }
        }
        return result;
    }

    /**
     * @dev Return the log in base 10, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log10(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log10(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 10 ** result < value);
        }
    }

    /**
     * @dev Return the log in base 256 of a positive value rounded towards zero.
     * Returns 0 if given 0.
     *
     * Adding one to the result gives the number of pairs of hex symbols needed to represent `value` as a hex string.
     */
    function log256(uint256 x) internal pure returns (uint256 r) {
        // If value has upper 128 bits set, log2 result is at least 128
        r = SafeCast.toUint(x > 0xffffffffffffffffffffffffffffffff) << 7;
        // If upper 64 bits of 128-bit half set, add 64 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffffffffffff) << 6;
        // If upper 32 bits of 64-bit half set, add 32 to result
        r |= SafeCast.toUint((x >> r) > 0xffffffff) << 5;
        // If upper 16 bits of 32-bit half set, add 16 to result
        r |= SafeCast.toUint((x >> r) > 0xffff) << 4;
        // Add 1 if upper 8 bits of 16-bit half set, and divide accumulated result by 8
        return (r >> 3) | SafeCast.toUint((x >> r) > 0xff);
    }

    /**
     * @dev Return the log in base 256, following the selected rounding direction, of a positive value.
     * Returns 0 if given 0.
     */
    function log256(uint256 value, Rounding rounding) internal pure returns (uint256) {
        unchecked {
            uint256 result = log256(value);
            return result + SafeCast.toUint(unsignedRoundsUp(rounding) && 1 << (result << 3) < value);
        }
    }

    /**
     * @dev Returns whether a provided rounding mode is considered rounding up for unsigned integers.
     */
    function unsignedRoundsUp(Rounding rounding) internal pure returns (bool) {
        return uint8(rounding) % 2 == 1;
    }
}

// contracts/interfaces/IOracle.sol

/// @title Oracle
/// @author kexley, Cap Labs
/// @notice Price and rate oracles are unified
interface IOracle is IPriceOracle, IRateOracle {
    /// @notice Initialize the oracle
    /// @param _accessControl Access control address
    function initialize(address _accessControl) external;
}

// node_modules/@openzeppelin/contracts/interfaces/IERC1363.sol

// OpenZeppelin Contracts (last updated v5.1.0) (interfaces/IERC1363.sol)

/**
 * @title IERC1363
 * @dev Interface of the ERC-1363 standard as defined in the https://eips.ethereum.org/EIPS/eip-1363[ERC-1363].
 *
 * Defines an extension interface for ERC-20 tokens that supports executing code on a recipient contract
 * after `transfer` or `transferFrom`, or code on a spender contract after `approve`, in a single transaction.
 */
interface IERC1363 is IERC20, IERC165 {
    /*
     * Note: the ERC-165 identifier for this interface is 0xb0202a11.
     * 0xb0202a11 ===
     *   bytes4(keccak256('transferAndCall(address,uint256)')) ^
     *   bytes4(keccak256('transferAndCall(address,uint256,bytes)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256)')) ^
     *   bytes4(keccak256('transferFromAndCall(address,address,uint256,bytes)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256)')) ^
     *   bytes4(keccak256('approveAndCall(address,uint256,bytes)'))
     */

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferAndCall(address to, uint256 value, bytes calldata data) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the allowance mechanism
     * and then calls {IERC1363Receiver-onTransferReceived} on `to`.
     * @param from The address which you want to send tokens from.
     * @param to The address which you want to transfer to.
     * @param value The amount of tokens to be transferred.
     * @param data Additional data with no specified format, sent in call to `to`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function transferFromAndCall(address from, address to, uint256 value, bytes calldata data)
        external
        returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value) external returns (bool);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens and then calls {IERC1363Spender-onApprovalReceived} on `spender`.
     * @param spender The address which will spend the funds.
     * @param value The amount of tokens to be spent.
     * @param data Additional data with no specified format, sent in call to `spender`.
     * @return A boolean value indicating whether the operation succeeded unless throwing.
     */
    function approveAndCall(address spender, uint256 value, bytes calldata data) external returns (bool);
}

// node_modules/@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v5.3.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC-20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    /**
     * @dev An operation with an ERC-20 token failed.
     */
    error SafeERC20FailedOperation(address token);

    /**
     * @dev Indicates a failed `decreaseAllowance` request.
     */
    error SafeERC20FailedDecreaseAllowance(address spender, uint256 currentAllowance, uint256 requestedDecrease);

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Variant of {safeTransfer} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransfer(IERC20 token, address to, uint256 value) internal returns (bool) {
        return _callOptionalReturnBool(token, abi.encodeCall(token.transfer, (to, value)));
    }

    /**
     * @dev Variant of {safeTransferFrom} that returns a bool instead of reverting if the operation is not successful.
     */
    function trySafeTransferFrom(IERC20 token, address from, address to, uint256 value) internal returns (bool) {
        return _callOptionalReturnBool(token, abi.encodeCall(token.transferFrom, (from, to, value)));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        forceApprove(token, spender, oldAllowance + value);
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `requestedDecrease`. If `token` returns no
     * value, non-reverting calls are assumed to be successful.
     *
     * IMPORTANT: If the token implements ERC-7674 (ERC-20 with temporary allowance), and if the "client"
     * smart contract uses ERC-7674 to set temporary allowances, then the "client" smart contract should avoid using
     * this function. Performing a {safeIncreaseAllowance} or {safeDecreaseAllowance} operation on a token contract
     * that has a non-zero temporary allowance (for that particular owner-spender) will result in unexpected behavior.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 requestedDecrease) internal {
        unchecked {
            uint256 currentAllowance = token.allowance(address(this), spender);
            if (currentAllowance < requestedDecrease) {
                revert SafeERC20FailedDecreaseAllowance(spender, currentAllowance, requestedDecrease);
            }
            forceApprove(token, spender, currentAllowance - requestedDecrease);
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Meant to be used with tokens that require the approval
     * to be set to zero before setting it to a non-zero value, such as USDT.
     *
     * NOTE: If the token implements ERC-7674, this function will not modify any temporary allowance. This function
     * only sets the "standard" allowance. Any temporary allowance will remain active, in addition to the value being
     * set here.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeCall(token.approve, (spender, value));

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeCall(token.approve, (spender, 0)));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Performs an {ERC1363} transferAndCall, with a fallback to the simple {ERC20} transfer if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            safeTransfer(token, to, value);
        } else if (!token.transferAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} transferFromAndCall, with a fallback to the simple {ERC20} transferFrom if the target
     * has no code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * Reverts if the returned value is other than `true`.
     */
    function transferFromAndCallRelaxed(IERC1363 token, address from, address to, uint256 value, bytes memory data)
        internal
    {
        if (to.code.length == 0) {
            safeTransferFrom(token, from, to, value);
        } else if (!token.transferFromAndCall(from, to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Performs an {ERC1363} approveAndCall, with a fallback to the simple {ERC20} approve if the target has no
     * code. This can be used to implement an {ERC721}-like safe transfer that rely on {ERC1363} checks when
     * targeting contracts.
     *
     * NOTE: When the recipient address (`to`) has no code (i.e. is an EOA), this function behaves as {forceApprove}.
     * Opposedly, when the recipient address (`to`) has code, this function only attempts to call {ERC1363-approveAndCall}
     * once without retrying, and relies on the returned value to be true.
     *
     * Reverts if the returned value is other than `true`.
     */
    function approveAndCallRelaxed(IERC1363 token, address to, uint256 value, bytes memory data) internal {
        if (to.code.length == 0) {
            forceApprove(token, to, value);
        } else if (!token.approveAndCall(to, value, data)) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturnBool} that reverts if call fails to meet the requirements.
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            // bubble errors
            if iszero(success) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            returnSize := returndatasize()
            returnValue := mload(0)
        }

        if (returnSize == 0 ? address(token).code.length == 0 : returnValue != 1) {
            revert SafeERC20FailedOperation(address(token));
        }
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silently catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        bool success;
        uint256 returnSize;
        uint256 returnValue;
        assembly ("memory-safe") {
            success := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0x20)
            returnSize := returndatasize()
            returnValue := mload(0)
        }
        return success && (returnSize == 0 ? address(token).code.length > 0 : returnValue == 1);
    }
}

// node_modules/@openzeppelin/contracts/utils/Arrays.sol

// OpenZeppelin Contracts (last updated v5.3.0) (utils/Arrays.sol)
// This file was procedurally generated from scripts/generate/templates/Arrays.js.

/**
 * @dev Collection of functions related to array types.
 */
library Arrays {
    using SlotDerivation for bytes32;
    using StorageSlot for bytes32;

    /**
     * @dev Sort an array of uint256 (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(uint256[] memory array, function(uint256, uint256) pure returns (bool) comp)
        internal
        pure
        returns (uint256[] memory)
    {
        _quickSort(_begin(array), _end(array), comp);
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of uint256 in increasing order.
     */
    function sort(uint256[] memory array) internal pure returns (uint256[] memory) {
        sort(array, Comparators.lt);
        return array;
    }

    /**
     * @dev Sort an array of address (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(address[] memory array, function(address, address) pure returns (bool) comp)
        internal
        pure
        returns (address[] memory)
    {
        sort(_castToUint256Array(array), _castToUint256Comp(comp));
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of address in increasing order.
     */
    function sort(address[] memory array) internal pure returns (address[] memory) {
        sort(_castToUint256Array(array), Comparators.lt);
        return array;
    }

    /**
     * @dev Sort an array of bytes32 (in memory) following the provided comparator function.
     *
     * This function does the sorting "in place", meaning that it overrides the input. The object is returned for
     * convenience, but that returned value can be discarded safely if the caller has a memory pointer to the array.
     *
     * NOTE: this function's cost is `O(n · log(n))` in average and `O(n²)` in the worst case, with n the length of the
     * array. Using it in view functions that are executed through `eth_call` is safe, but one should be very careful
     * when executing this as part of a transaction. If the array being sorted is too large, the sort operation may
     * consume more gas than is available in a block, leading to potential DoS.
     *
     * IMPORTANT: Consider memory side-effects when using custom comparator functions that access memory in an unsafe way.
     */
    function sort(bytes32[] memory array, function(bytes32, bytes32) pure returns (bool) comp)
        internal
        pure
        returns (bytes32[] memory)
    {
        sort(_castToUint256Array(array), _castToUint256Comp(comp));
        return array;
    }

    /**
     * @dev Variant of {sort} that sorts an array of bytes32 in increasing order.
     */
    function sort(bytes32[] memory array) internal pure returns (bytes32[] memory) {
        sort(_castToUint256Array(array), Comparators.lt);
        return array;
    }

    /**
     * @dev Performs a quick sort of a segment of memory. The segment sorted starts at `begin` (inclusive), and stops
     * at end (exclusive). Sorting follows the `comp` comparator.
     *
     * Invariant: `begin <= end`. This is the case when initially called by {sort} and is preserved in subcalls.
     *
     * IMPORTANT: Memory locations between `begin` and `end` are not validated/zeroed. This function should
     * be used only if the limits are within a memory array.
     */
    function _quickSort(uint256 begin, uint256 end, function(uint256, uint256) pure returns (bool) comp) private pure {
        unchecked {
            if (end - begin < 0x40) return;

            // Use first element as pivot
            uint256 pivot = _mload(begin);
            // Position where the pivot should be at the end of the loop
            uint256 pos = begin;

            for (uint256 it = begin + 0x20; it < end; it += 0x20) {
                if (comp(_mload(it), pivot)) {
                    // If the value stored at the iterator's position comes before the pivot, we increment the
                    // position of the pivot and move the value there.
                    pos += 0x20;
                    _swap(pos, it);
                }
            }

            _swap(begin, pos); // Swap pivot into place
            _quickSort(begin, pos, comp); // Sort the left side of the pivot
            _quickSort(pos + 0x20, end, comp); // Sort the right side of the pivot
        }
    }

    /**
     * @dev Pointer to the memory location of the first element of `array`.
     */
    function _begin(uint256[] memory array) private pure returns (uint256 ptr) {
        assembly ("memory-safe") {
            ptr := add(array, 0x20)
        }
    }

    /**
     * @dev Pointer to the memory location of the first memory word (32bytes) after `array`. This is the memory word
     * that comes just after the last element of the array.
     */
    function _end(uint256[] memory array) private pure returns (uint256 ptr) {
        unchecked {
            return _begin(array) + array.length * 0x20;
        }
    }

    /**
     * @dev Load memory word (as a uint256) at location `ptr`.
     */
    function _mload(uint256 ptr) private pure returns (uint256 value) {
        assembly {
            value := mload(ptr)
        }
    }

    /**
     * @dev Swaps the elements memory location `ptr1` and `ptr2`.
     */
    function _swap(uint256 ptr1, uint256 ptr2) private pure {
        assembly {
            let value1 := mload(ptr1)
            let value2 := mload(ptr2)
            mstore(ptr1, value2)
            mstore(ptr2, value1)
        }
    }

    /// @dev Helper: low level cast address memory array to uint256 memory array
    function _castToUint256Array(address[] memory input) private pure returns (uint256[] memory output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast bytes32 memory array to uint256 memory array
    function _castToUint256Array(bytes32[] memory input) private pure returns (uint256[] memory output) {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast address comp function to uint256 comp function
    function _castToUint256Comp(function(address, address) pure returns (bool) input)
        private
        pure
        returns (function(uint256, uint256) pure returns (bool) output)
    {
        assembly {
            output := input
        }
    }

    /// @dev Helper: low level cast bytes32 comp function to uint256 comp function
    function _castToUint256Comp(function(bytes32, bytes32) pure returns (bool) input)
        private
        pure
        returns (function(uint256, uint256) pure returns (bool) output)
    {
        assembly {
            output := input
        }
    }

    /**
     * @dev Searches a sorted `array` and returns the first index that contains
     * a value greater or equal to `element`. If no such index exists (i.e. all
     * values in the array are strictly less than `element`), the array length is
     * returned. Time complexity O(log n).
     *
     * NOTE: The `array` is expected to be sorted in ascending order, and to
     * contain no repeated elements.
     *
     * IMPORTANT: Deprecated. This implementation behaves as {lowerBound} but lacks
     * support for repeated elements in the array. The {lowerBound} function should
     * be used instead.
     */
    function findUpperBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value > element) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        // At this point `low` is the exclusive upper bound. We will return the inclusive upper bound.
        if (low > 0 && unsafeAccess(array, low - 1).value == element) {
            return low - 1;
        } else {
            return low;
        }
    }

    /**
     * @dev Searches an `array` sorted in ascending order and returns the first
     * index that contains a value greater or equal than `element`. If no such index
     * exists (i.e. all values in the array are strictly less than `element`), the array
     * length is returned. Time complexity O(log n).
     *
     * See C++'s https://en.cppreference.com/w/cpp/algorithm/lower_bound[lower_bound].
     */
    function lowerBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value < element) {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            } else {
                high = mid;
            }
        }

        return low;
    }

    /**
     * @dev Searches an `array` sorted in ascending order and returns the first
     * index that contains a value strictly greater than `element`. If no such index
     * exists (i.e. all values in the array are strictly less than `element`), the array
     * length is returned. Time complexity O(log n).
     *
     * See C++'s https://en.cppreference.com/w/cpp/algorithm/upper_bound[upper_bound].
     */
    function upperBound(uint256[] storage array, uint256 element) internal view returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeAccess(array, mid).value > element) {
                high = mid;
            } else {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            }
        }

        return low;
    }

    /**
     * @dev Same as {lowerBound}, but with an array in memory.
     */
    function lowerBoundMemory(uint256[] memory array, uint256 element) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeMemoryAccess(array, mid) < element) {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            } else {
                high = mid;
            }
        }

        return low;
    }

    /**
     * @dev Same as {upperBound}, but with an array in memory.
     */
    function upperBoundMemory(uint256[] memory array, uint256 element) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = array.length;

        if (high == 0) {
            return 0;
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds towards zero (it does integer division with truncation).
            if (unsafeMemoryAccess(array, mid) > element) {
                high = mid;
            } else {
                // this cannot overflow because mid < high
                unchecked {
                    low = mid + 1;
                }
            }
        }

        return low;
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(address[] storage arr, uint256 pos) internal pure returns (StorageSlot.AddressSlot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getAddressSlot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(bytes32[] storage arr, uint256 pos) internal pure returns (StorageSlot.Bytes32Slot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getBytes32Slot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeAccess(uint256[] storage arr, uint256 pos) internal pure returns (StorageSlot.Uint256Slot storage) {
        bytes32 slot;
        assembly ("memory-safe") {
            slot := arr.slot
        }
        return slot.deriveArray().offset(pos).getUint256Slot();
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(address[] memory arr, uint256 pos) internal pure returns (address res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(bytes32[] memory arr, uint256 pos) internal pure returns (bytes32 res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Access an array in an "unsafe" way. Skips solidity "index-out-of-range" check.
     *
     * WARNING: Only use if you are certain `pos` is lower than the array length.
     */
    function unsafeMemoryAccess(uint256[] memory arr, uint256 pos) internal pure returns (uint256 res) {
        assembly {
            res := mload(add(add(arr, 0x20), mul(pos, 0x20)))
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(address[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(bytes32[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }

    /**
     * @dev Helper to set the length of a dynamic array. Directly writing to `.length` is forbidden.
     *
     * WARNING: this does not clear elements if length is reduced, of initialize elements if length is increased.
     */
    function unsafeSetLength(uint256[] storage array, uint256 len) internal {
        assembly ("memory-safe") {
            sstore(array.slot, len)
        }
    }
}

// node_modules/@openzeppelin/contracts/utils/structs/EnumerableSet.sol

// OpenZeppelin Contracts (last updated v5.3.0) (utils/structs/EnumerableSet.sol)
// This file was procedurally generated from scripts/generate/templates/EnumerableSet.js.

/**
 * @dev Library for managing
 * https://en.wikipedia.org/wiki/Set_(abstract_data_type)[sets] of primitive
 * types.
 *
 * Sets have the following properties:
 *
 * - Elements are added, removed, and checked for existence in constant time
 * (O(1)).
 * - Elements are enumerated in O(n). No guarantees are made on the ordering.
 * - Set can be cleared (all elements removed) in O(n).
 *
 * ```solidity
 * contract Example {
 *     // Add the library methods
 *     using EnumerableSet for EnumerableSet.AddressSet;
 *
 *     // Declare a set state variable
 *     EnumerableSet.AddressSet private mySet;
 * }
 * ```
 *
 * As of v3.3.0, sets of type `bytes32` (`Bytes32Set`), `address` (`AddressSet`)
 * and `uint256` (`UintSet`) are supported.
 *
 * [WARNING]
 * ====
 * Trying to delete such a structure from storage will likely result in data corruption, rendering the structure
 * unusable.
 * See https://github.com/ethereum/solidity/pull/11843[ethereum/solidity#11843] for more info.
 *
 * In order to clean an EnumerableSet, you can either remove all elements one by one or create a fresh instance using an
 * array of EnumerableSet.
 * ====
 */
library EnumerableSet {
    // To implement this library for multiple types with as little code
    // repetition as possible, we write it in terms of a generic Set type with
    // bytes32 values.
    // The Set implementation uses private functions, and user-facing
    // implementations (such as AddressSet) are just wrappers around the
    // underlying Set.
    // This means that we can only create new EnumerableSets for types that fit
    // in bytes32.

    struct Set {
        // Storage of set values
        bytes32[] _values;
        // Position is the index of the value in the `values` array plus 1.
        // Position 0 is used to mean a value is not in the set.
        mapping(bytes32 value => uint256) _positions;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function _add(Set storage set, bytes32 value) private returns (bool) {
        if (!_contains(set, value)) {
            set._values.push(value);
            // The value is stored at length-1, but we add 1 to all indexes
            // and use 0 as a sentinel value
            set._positions[value] = set._values.length;
            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function _remove(Set storage set, bytes32 value) private returns (bool) {
        // We cache the value's position to prevent multiple reads from the same storage slot
        uint256 position = set._positions[value];

        if (position != 0) {
            // Equivalent to contains(set, value)
            // To delete an element from the _values array in O(1), we swap the element to delete with the last one in
            // the array, and then remove the last element (sometimes called as 'swap and pop').
            // This modifies the order of the array, as noted in {at}.

            uint256 valueIndex = position - 1;
            uint256 lastIndex = set._values.length - 1;

            if (valueIndex != lastIndex) {
                bytes32 lastValue = set._values[lastIndex];

                // Move the lastValue to the index where the value to delete is
                set._values[valueIndex] = lastValue;
                // Update the tracked position of the lastValue (that was just moved)
                set._positions[lastValue] = position;
            }

            // Delete the slot where the moved value was stored
            set._values.pop();

            // Delete the tracked position for the deleted slot
            delete set._positions[value];

            return true;
        } else {
            return false;
        }
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function _clear(Set storage set) private {
        uint256 len = _length(set);
        for (uint256 i = 0; i < len; ++i) {
            delete set._positions[set._values[i]];
        }
        Arrays.unsafeSetLength(set._values, 0);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function _contains(Set storage set, bytes32 value) private view returns (bool) {
        return set._positions[value] != 0;
    }

    /**
     * @dev Returns the number of values on the set. O(1).
     */
    function _length(Set storage set) private view returns (uint256) {
        return set._values.length;
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function _at(Set storage set, uint256 index) private view returns (bytes32) {
        return set._values[index];
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function _values(Set storage set) private view returns (bytes32[] memory) {
        return set._values;
    }

    // Bytes32Set

    struct Bytes32Set {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _add(set._inner, value);
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(Bytes32Set storage set, bytes32 value) internal returns (bool) {
        return _remove(set._inner, value);
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(Bytes32Set storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(Bytes32Set storage set, bytes32 value) internal view returns (bool) {
        return _contains(set._inner, value);
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(Bytes32Set storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(Bytes32Set storage set, uint256 index) internal view returns (bytes32) {
        return _at(set._inner, index);
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(Bytes32Set storage set) internal view returns (bytes32[] memory) {
        bytes32[] memory store = _values(set._inner);
        bytes32[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // AddressSet

    struct AddressSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(AddressSet storage set, address value) internal returns (bool) {
        return _add(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(AddressSet storage set, address value) internal returns (bool) {
        return _remove(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(AddressSet storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(AddressSet storage set, address value) internal view returns (bool) {
        return _contains(set._inner, bytes32(uint256(uint160(value))));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(AddressSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(AddressSet storage set, uint256 index) internal view returns (address) {
        return address(uint160(uint256(_at(set._inner, index))));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(AddressSet storage set) internal view returns (address[] memory) {
        bytes32[] memory store = _values(set._inner);
        address[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }

    // UintSet

    struct UintSet {
        Set _inner;
    }

    /**
     * @dev Add a value to a set. O(1).
     *
     * Returns true if the value was added to the set, that is if it was not
     * already present.
     */
    function add(UintSet storage set, uint256 value) internal returns (bool) {
        return _add(set._inner, bytes32(value));
    }

    /**
     * @dev Removes a value from a set. O(1).
     *
     * Returns true if the value was removed from the set, that is if it was
     * present.
     */
    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        return _remove(set._inner, bytes32(value));
    }

    /**
     * @dev Removes all the values from a set. O(n).
     *
     * WARNING: Developers should keep in mind that this function has an unbounded cost and using it may render the
     * function uncallable if the set grows to the point where clearing it consumes too much gas to fit in a block.
     */
    function clear(UintSet storage set) internal {
        _clear(set._inner);
    }

    /**
     * @dev Returns true if the value is in the set. O(1).
     */
    function contains(UintSet storage set, uint256 value) internal view returns (bool) {
        return _contains(set._inner, bytes32(value));
    }

    /**
     * @dev Returns the number of values in the set. O(1).
     */
    function length(UintSet storage set) internal view returns (uint256) {
        return _length(set._inner);
    }

    /**
     * @dev Returns the value stored at position `index` in the set. O(1).
     *
     * Note that there are no guarantees on the ordering of values inside the
     * array, and it may change when more values are added or removed.
     *
     * Requirements:
     *
     * - `index` must be strictly less than {length}.
     */
    function at(UintSet storage set, uint256 index) internal view returns (uint256) {
        return uint256(_at(set._inner, index));
    }

    /**
     * @dev Return the entire set in an array
     *
     * WARNING: This operation will copy the entire storage to memory, which can be quite expensive. This is designed
     * to mostly be used by view accessors that are queried without any gas fees. Developers should keep in mind that
     * this function has an unbounded cost, and using it as part of a state-changing function may render the function
     * uncallable if the set grows to a point where copying to memory consumes too much gas to fit in a block.
     */
    function values(UintSet storage set) internal view returns (uint256[] memory) {
        bytes32[] memory store = _values(set._inner);
        uint256[] memory result;

        assembly ("memory-safe") {
            result := store
        }

        return result;
    }
}

// contracts/interfaces/IVault.sol

/// @title Vault interface for storing the backing for cTokens
/// @author kexley, Cap Labs
/// @notice Interface for the Vault contract which handles supplies, borrows and utilization tracking
interface IVault {
    /// @dev Storage for the vault
    /// @param assets List of assets
    /// @param totalSupplies Total supplies of an asset
    /// @param totalBorrows Total borrows of an asset
    /// @param utilizationIndex Utilization index of an asset
    /// @param lastUpdate Last update time of an asset
    /// @param paused Pause state of an asset
    /// @param insuranceFund Insurance fund address
    struct VaultStorage {
        EnumerableSet.AddressSet assets;
        mapping(address => uint256) totalSupplies;
        mapping(address => uint256) totalBorrows;
        mapping(address => uint256) utilizationIndex;
        mapping(address => uint256) lastUpdate;
        mapping(address => bool) paused;
        address insuranceFund;
    }

    /// @dev Parameters for minting or burning
    /// @param asset Asset to mint or burn
    /// @param amountIn Amount of asset to use in the minting or burning
    /// @param amountOut Amount of cap token to mint or burn
    /// @param minAmountOut Minimum amount to mint or burn
    /// @param receiver Receiver of the minting or burning
    /// @param deadline Deadline of the tx
    /// @param fee Fee paid to the insurance fund
    struct MintBurnParams {
        address asset;
        uint256 amountIn;
        uint256 amountOut;
        uint256 minAmountOut;
        address receiver;
        uint256 deadline;
        uint256 fee;
    }

    /// @dev Parameters for redeeming
    /// @param amountIn Amount of cap token to burn
    /// @param amountsOut Amounts of assets to withdraw
    /// @param minAmountsOut Minimum amounts of assets to withdraw
    /// @param receiver Receiver of the withdrawal
    /// @param deadline Deadline of the tx
    /// @param fees Fees paid to the insurance fund
    struct RedeemParams {
        uint256 amountIn;
        uint256[] amountsOut;
        uint256[] minAmountsOut;
        address receiver;
        uint256 deadline;
        uint256[] fees;
    }

    /// @dev Parameters for borrowing
    /// @param asset Asset to borrow
    /// @param amount Amount of asset to borrow
    /// @param receiver Receiver of the borrow
    struct BorrowParams {
        address asset;
        uint256 amount;
        address receiver;
    }

    /// @dev Parameters for repaying
    /// @param asset Asset to repay
    /// @param amount Amount of asset to repay
    struct RepayParams {
        address asset;
        uint256 amount;
    }

    /// @notice Mint the cap token using an asset
    /// @dev This contract must have approval to move asset from msg.sender
    /// @param _asset Whitelisted asset to deposit
    /// @param _amountIn Amount of asset to use in the minting
    /// @param _minAmountOut Minimum amount to mint
    /// @param _receiver Receiver of the minting
    /// @param _deadline Deadline of the tx
    function mint(address _asset, uint256 _amountIn, uint256 _minAmountOut, address _receiver, uint256 _deadline)
        external
        returns (uint256 amountOut);

    /// @notice Burn the cap token for an asset
    /// @dev Asset is withdrawn from the reserve or divested from the underlying vault
    /// @param _asset Asset to withdraw
    /// @param _amountIn Amount of cap token to burn
    /// @param _minAmountOut Minimum amount out to receive
    /// @param _receiver Receiver of the withdrawal
    /// @param _deadline Deadline of the tx
    function burn(address _asset, uint256 _amountIn, uint256 _minAmountOut, address _receiver, uint256 _deadline)
        external
        returns (uint256 amountOut);

    /// @notice Redeem the Cap token for a bundle of assets
    /// @dev Assets are withdrawn from the reserve or divested from the underlying vault
    /// @param _amountIn Amount of Cap token to burn
    /// @param _minAmountsOut Minimum amounts of assets to withdraw
    /// @param _receiver Receiver of the withdrawal
    /// @param _deadline Deadline of the tx
    /// @return amountsOut Amount of assets withdrawn
    function redeem(uint256 _amountIn, uint256[] calldata _minAmountsOut, address _receiver, uint256 _deadline)
        external
        returns (uint256[] memory amountsOut);

    /// @notice Borrow an asset
    /// @dev Whitelisted agents can borrow any amount, LTV is handled by Agent contracts
    /// @param _asset Asset to borrow
    /// @param _amount Amount of asset to borrow
    /// @param _receiver Receiver of the borrow
    function borrow(address _asset, uint256 _amount, address _receiver) external;

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay
    function repay(address _asset, uint256 _amount) external;

    /// @notice Add an asset to the vault list
    /// @param _asset Asset address
    function addAsset(address _asset) external;

    /// @notice Remove an asset from the vault list
    /// @param _asset Asset address
    function removeAsset(address _asset) external;

    /// @notice Pause an asset
    /// @param _asset Asset address
    function pauseAsset(address _asset) external;

    /// @notice Unpause an asset
    /// @param _asset Asset address
    function unpauseAsset(address _asset) external;

    /// @notice Pause all protocol operations
    function pauseProtocol() external;

    /// @notice Unpause all protocol operations
    function unpauseProtocol() external;

    /// @notice Set the insurance fund
    /// @param _insuranceFund Insurance fund address
    function setInsuranceFund(address _insuranceFund) external;

    /// @notice Rescue an unsupported asset
    /// @param _asset Asset to rescue
    /// @param _receiver Receiver of the rescue
    function rescueERC20(address _asset, address _receiver) external;

    /// @notice Get the list of assets supported by the vault
    /// @return assetList List of assets
    function assets() external view returns (address[] memory assetList);

    /// @notice Get the total supplies of an asset
    /// @param _asset Asset address
    /// @return totalSupply Total supply
    function totalSupplies(address _asset) external view returns (uint256 totalSupply);

    /// @notice Get the total borrows of an asset
    /// @param _asset Asset address
    /// @return totalBorrow Total borrow
    function totalBorrows(address _asset) external view returns (uint256 totalBorrow);

    /// @notice Get the pause state of an asset
    /// @param _asset Asset address
    /// @return isPaused Pause state
    function paused(address _asset) external view returns (bool isPaused);

    /// @notice Available balance to borrow
    /// @param _asset Asset to borrow
    /// @return amount Amount available
    function availableBalance(address _asset) external view returns (uint256 amount);

    /// @notice Utilization rate of an asset
    /// @dev Utilization scaled by 1e27
    /// @param _asset Utilized asset
    /// @return ratio Utilization ratio
    function utilization(address _asset) external view returns (uint256 ratio);

    /// @notice Up to date cumulative utilization index of an asset
    /// @dev Utilization scaled by 1e27
    /// @param _asset Utilized asset
    /// @return index Utilization ratio index
    function currentUtilizationIndex(address _asset) external view returns (uint256 index);

    /// @notice Get the insurance fund
    /// @return insuranceFund Insurance fund
    function insuranceFund() external view returns (address);
}

// contracts/interfaces/IDelegation.sol

/// @title IDelegation
/// @author weso, Cap Labs
/// @notice Interface for Delegation contract
interface IDelegation is IRestakerRewardReceiver {
    /// @dev Delegation storage
    /// @param agents Agent addresses
    /// @param agentData Agent data
    /// @param networks Network addresses
    /// @param oracle Oracle address
    /// @param epochDuration Epoch duration
    /// @param ltvBuffer LTV buffer from LT
    struct DelegationStorage {
        EnumerableSet.AddressSet agents;
        mapping(address => AgentData) agentData;
        EnumerableSet.AddressSet networks;
        address oracle;
        uint256 epochDuration;
        uint256 ltvBuffer;
        address feeRecipient;
    }

    /// @dev Agent data
    /// @param network Network address
    /// @param ltv Loan to value ratio
    /// @param liquidationThreshold Liquidation threshold
    /// @param lastBorrow Last borrow timestamp
    struct AgentData {
        address network;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 lastBorrow;
    }

    /// @notice Slash a network
    /// @param network Network address
    /// @param slashShare Slash share
    event SlashNetwork(address network, uint256 slashShare);

    /// @notice Add an agent
    /// @param agent Agent address
    /// @param ltv LTV
    /// @param liquidationThreshold Liquidation threshold
    event AddAgent(address agent, address network, uint256 ltv, uint256 liquidationThreshold);

    /// @notice Modify an agent
    /// @param agent Agent address
    /// @param ltv LTV
    /// @param liquidationThreshold Liquidation threshold
    event ModifyAgent(address agent, uint256 ltv, uint256 liquidationThreshold);

    /// @notice Register a network
    /// @param network Network address
    event RegisterNetwork(address network);

    /// @notice Distribute a reward
    /// @param agent Agent address
    /// @param asset Asset address
    /// @param amount Amount
    event DistributeReward(address agent, address asset, uint256 amount);

    /// @notice Set the ltv buffer
    /// @param ltvBuffer LTV buffer
    event SetLtvBuffer(uint256 ltvBuffer);

    /// @notice Set the fee recipient
    /// @param feeRecipient Fee recipient
    event SetFeeRecipient(address feeRecipient);

    /// @notice Agent does not exist
    error AgentDoesNotExist();

    /// @notice Duplicate agent
    error DuplicateAgent();

    /// @notice Duplicate network
    error DuplicateNetwork();

    /// @notice Network already registered
    error NetworkAlreadyRegistered();

    /// @notice Network does not exist
    error NetworkDoesntExist();

    /// @notice Invalid liquidation threshold
    error InvalidLiquidationThreshold();

    /// @notice Liquidation threshold too close to ltv
    error LiquidationThresholdTooCloseToLtv();

    /// @notice Invalid ltv buffer
    error InvalidLtvBuffer();

    /// @notice Invalid network
    error InvalidNetwork();

    /// @notice No slashable collateral
    error NoSlashableCollateral();

    /// @notice Initialize the contract
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _epochDuration Epoch duration in seconds
    function initialize(address _accessControl, address _oracle, uint256 _epochDuration) external;

    /// @notice The slash function. Calls the underlying networks to slash the delegated capital
    /// @dev Called only by the lender during liquidation
    /// @param _agent The agent who is unhealthy
    /// @param _liquidator The liquidator who receives the funds
    /// @param _amount The USD value of the delegation needed to cover the debt
    function slash(address _agent, address _liquidator, uint256 _amount) external;

    /// @notice Distribute rewards to networks covering an agent proportionally to their coverage
    /// @param _agent The agent address
    /// @param _asset The reward token address
    function distributeRewards(address _agent, address _asset) external;

    /// @notice Set the last borrow timestamp for an agent
    /// @param _agent Agent address
    function setLastBorrow(address _agent) external;

    /// @notice Add agent to be delegated to
    /// @param _agent Agent address
    /// @param _network Network address
    /// @param _ltv Loan to value ratio
    /// @param _liquidationThreshold Liquidation threshold
    function addAgent(address _agent, address _network, uint256 _ltv, uint256 _liquidationThreshold) external;

    /// @notice Modify an agents config only callable by the operator
    /// @param _agent the agent to modify
    /// @param _ltv Loan to value ratio
    /// @param _liquidationThreshold Liquidation threshold
    function modifyAgent(address _agent, uint256 _ltv, uint256 _liquidationThreshold) external;

    /// @notice Register a new network
    /// @param _network Network address
    function registerNetwork(address _network) external;

    /// @notice Set the ltv buffer
    /// @param _ltvBuffer LTV buffer
    function setLtvBuffer(uint256 _ltvBuffer) external;

    /// @notice Set the fee recipient
    /// @param _feeRecipient Fee recipient
    function setFeeRecipient(address _feeRecipient) external;

    /// @notice Get the epoch duration
    /// @return duration Epoch duration in seconds
    /// @dev The duration between epochs. Pretty much the amount of time we have to slash the delegated collateral, if delegation is changed on the symbiotic vault.
    function epochDuration() external view returns (uint256 duration);

    /// @notice Get the current epoch
    /// @return currentEpoch Current epoch
    /// @dev Returns an epoch which we use to fetch the a timestamp in which we had slashable collateral. Will be less than the epoch on the symbiotic vault.
    function epoch() external view returns (uint256 currentEpoch);

    /// @notice Get the ltv buffer
    /// @return buffer LTV buffer
    function ltvBuffer() external view returns (uint256 buffer);

    /// @notice Get the timestamp that is most recent between the last borrow and the epoch -1
    /// @param _agent The agent address
    /// @return _slashTimestamp Timestamp that is most recent between the last borrow and the epoch -1
    function slashTimestamp(address _agent) external view returns (uint48 _slashTimestamp);

    /// @notice How much delegation and agent has available to back their borrows
    /// @param _agent The agent address
    /// @return delegation Amount in USD (8 decimals) that a agent has provided as delegation from the delegators
    function coverage(address _agent) external view returns (uint256 delegation);

    /// @notice How much slashable coverage an agent has available to back their borrows
    /// @param _agent The agent address
    /// @return _slashableCollateral Amount in USD (8 decimals) that a agent has provided as slashable collateral from the delegators
    function slashableCollateral(address _agent) external view returns (uint256 _slashableCollateral);

    /// @notice Fetch active network address
    /// @param _agent Agent address
    /// @return networkAddress network address
    function networks(address _agent) external view returns (address networkAddress);

    /// @notice Fetch active agent addresses
    /// @return agentAddresses Agent addresses
    function agents() external view returns (address[] memory agentAddresses);

    /// @notice The LTV of a specific agent
    /// @param _agent Agent who we are querying
    /// @return currentLtv Loan to value ratio of the agent
    function ltv(address _agent) external view returns (uint256 currentLtv);

    /// @notice Liquidation threshold of the agent
    /// @param _agent Agent who we are querying
    /// @return lt Liquidation threshold of the agent
    function liquidationThreshold(address _agent) external view returns (uint256 lt);

    /// @notice Check if a network exists
    /// @param _network Network address
    /// @return exists True if the network is registered
    function networkExists(address _network) external view returns (bool exists);

    /// @notice Get the fee recipient
    /// @return recipient Fee recipient
    function feeRecipient() external view returns (address recipient);
}

// contracts/lendingPool/libraries/ViewLogic.sol

/// @title View Logic
/// @author kexley, Cap Labs
/// @notice View functions to see the state of an agent's health
library ViewLogic {
    using AgentConfiguration for ILender.AgentConfigurationMap;
    using Math for uint256;

    uint256 constant SECONDS_IN_YEAR = 31536000;

    /// @notice Calculate the maximum amount that can be borrowed for a given asset
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @param _asset Asset to borrow
    /// @return maxBorrowableAmount Maximum amount that can be borrowed in asset decimals
    function maxBorrowable(ILender.LenderStorage storage $, address _agent, address _asset)
        external
        view
        returns (uint256 maxBorrowableAmount)
    {
        (uint256 totalDelegation,, uint256 totalDebt,,, uint256 health) = agent($, _agent);
        uint256 unrealizedInterest = accruedRestakerInterest($, _agent, _asset);

        // health is below liquidation threshold, no borrowing allowed
        if (health < 1e27) return 0;

        uint256 ltv = IDelegation($.delegation).ltv(_agent);
        uint256 borrowCapacity = totalDelegation * ltv / 1e27;

        //  already at or above borrow capacity
        if (totalDebt >= borrowCapacity) return 0;

        // Calculate remaining borrow capacity in USD (8 decimals)
        uint256 remainingCapacity = borrowCapacity - totalDebt;

        // Convert to asset amount using price and decimals
        (uint256 assetPrice,) = IOracle($.oracle).getPrice(_asset);
        if (assetPrice == 0) return 0;

        uint256 assetDecimals = $.reservesData[_asset].decimals;
        maxBorrowableAmount = remainingCapacity * (10 ** assetDecimals) / assetPrice;

        // Get total available assets using the vault's availableBalance function
        uint256 totalAvailable = IVault($.reservesData[_asset].vault).availableBalance(_asset);
        if (totalAvailable < unrealizedInterest) return 0;
        totalAvailable -= unrealizedInterest;

        // Limit maxBorrowableAmount by total available assets
        if (totalAvailable < maxBorrowableAmount) {
            maxBorrowableAmount = totalAvailable;
        }
    }

    /// @notice Calculate the maximum amount that can be liquidated for a given asset
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @param _asset Asset to liquidate
    /// @return maxLiquidatableAmount Maximum amount that can be liquidated in asset decimals
    function maxLiquidatable(ILender.LenderStorage storage $, address _agent, address _asset)
        external
        view
        returns (uint256 maxLiquidatableAmount)
    {
        (uint256 totalDelegation,, uint256 totalDebt,, uint256 liquidationThreshold, uint256 health) = agent($, _agent);
        if (health >= 1e27) return 0;

        (uint256 assetPrice,) = IOracle($.oracle).getPrice(_asset);
        if (assetPrice == 0) return 0;

        ILender.ReserveData storage reserve = $.reservesData[_asset];
        uint256 decPow = 10 ** reserve.decimals;

        // Calculate maximum liquidatable amount
        if (totalDelegation * liquidationThreshold > $.targetHealth * totalDebt) {
            return 0;
        }

        maxLiquidatableAmount = (($.targetHealth * totalDebt) - (totalDelegation * liquidationThreshold)) * decPow
            / (($.targetHealth - liquidationThreshold) * assetPrice);

        // Cap at the agent's debt for this asset
        uint256 agentDebt = debt($, _agent, _asset);
        if (agentDebt < maxLiquidatableAmount + reserve.minBorrow) maxLiquidatableAmount = agentDebt;
    }

    /// @notice Calculate the agent data
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @return totalDelegation Total delegation of an agent in USD, encoded with 8 decimals
    /// @return totalSlashableCollateral Total slashable collateral of an agent in USD, encoded with 8 decimals
    /// @return totalDebt Total debt of an agent in USD, encoded with 8 decimals
    /// @return ltv Loan to value ratio, encoded in ray (1e27)
    /// @return liquidationThreshold Liquidation ratio of an agent, encoded in ray (1e27)
    /// @return health Health status of an agent, encoded in ray (1e27)
    function agent(ILender.LenderStorage storage $, address _agent)
        public
        view
        returns (
            uint256 totalDelegation,
            uint256 totalSlashableCollateral,
            uint256 totalDebt,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 health
        )
    {
        totalDelegation = IDelegation($.delegation).coverage(_agent);
        totalSlashableCollateral = IDelegation($.delegation).slashableCollateral(_agent);
        liquidationThreshold = IDelegation($.delegation).liquidationThreshold(_agent);

        // Extract debt calculation to a separate function to reduce local variables
        totalDebt = calculateTotalDebt($, _agent);

        ltv = totalDelegation == 0 ? 0 : (totalDebt * 1e27) / totalDelegation;
        health = totalDebt == 0 ? type(uint256).max : (totalDelegation * liquidationThreshold) / totalDebt;
    }

    /// @notice Get the current debt balances for an agent for a specific asset
    /// @param $ Lender storage
    /// @param _agent Agent address to check debt for
    /// @param _asset Asset to check debt for
    /// @return totalDebt Total debt amount in asset decimals
    function debt(ILender.LenderStorage storage $, address _agent, address _asset)
        public
        view
        returns (uint256 totalDebt)
    {
        totalDebt =
            IERC20($.reservesData[_asset].debtToken).balanceOf(_agent) + accruedRestakerInterest($, _agent, _asset);
    }

    /// @notice Calculate the accrued restaker interest for an agent for a specific asset
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @param _asset Asset to calculate accrued interest for
    /// @return accruedInterest Accrued restaker interest in asset decimals
    function accruedRestakerInterest(ILender.LenderStorage storage $, address _agent, address _asset)
        public
        view
        returns (uint256 accruedInterest)
    {
        ILender.ReserveData storage reserve = $.reservesData[_asset];
        uint256 totalDebt = IERC20(reserve.debtToken).balanceOf(_agent);
        uint256 rate = IOracle($.oracle).restakerRate(_agent);
        uint256 elapsedTime = block.timestamp - reserve.lastRealizationTime[_agent];

        accruedInterest = totalDebt * rate * elapsedTime / (1e27 * SECONDS_IN_YEAR);
    }

    /// @notice Helper function to calculate the total debt of an agent across all assets
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @return totalDebt Total debt of an agent in USD, encoded with 8 decimals
    function calculateTotalDebt(ILender.LenderStorage storage $, address _agent)
        private
        view
        returns (uint256 totalDebt)
    {
        for (uint256 i; i < $.reservesCount; ++i) {
            if (!$.agentConfig[_agent].isBorrowing(i)) {
                continue;
            }

            address asset = $.reservesList[i];
            (uint256 assetPrice,) = IOracle($.oracle).getPrice(asset);
            if (assetPrice == 0) continue;

            ILender.ReserveData storage reserve = $.reservesData[asset];

            totalDebt += (IERC20(reserve.debtToken).balanceOf(_agent) + accruedRestakerInterest($, _agent, asset))
                .mulDiv(assetPrice, 10 ** reserve.decimals, Math.Rounding.Ceil);
        }
    }

    /// @dev Get the bonus for a liquidation in percentage ray decimals, max for emergencies and none if health is too low
    /// @param $ Lender storage
    /// @param _agent Agent address
    /// @return maxBonus Bonus percentage in ray decimals
    function bonus(ILender.LenderStorage storage $, address _agent) internal view returns (uint256 maxBonus) {
        (uint256 totalDelegation,, uint256 totalDebt,,,) = agent($, _agent);

        if (totalDelegation > totalDebt) {
            // Emergency liquidations get max bonus
            if (totalDelegation * $.emergencyLiquidationThreshold / totalDebt < 1e27) {
                maxBonus = $.bonusCap;
            } else {
                // Pro-rata bonus for non-emergency liquidations
                if (block.timestamp > ($.liquidationStart[_agent] + $.grace)) {
                    uint256 elapsed = block.timestamp - ($.liquidationStart[_agent] + $.grace);
                    uint256 duration = $.expiry - $.grace;
                    if (elapsed > duration) elapsed = duration;
                    maxBonus = $.bonusCap * elapsed / duration;
                }
            }

            uint256 maxHealthyBonus = (totalDelegation - totalDebt) * 1e27 / totalDebt;
            if (maxBonus > maxHealthyBonus) maxBonus = maxHealthyBonus;
        }
    }
}

// contracts/lendingPool/libraries/ValidationLogic.sol

/// @title Validation Logic
/// @author kexley, Cap Labs
/// @notice Validate actions before state is altered
library ValidationLogic {
    /// @dev Collateral cannot cover new borrow
    error CollateralCannotCoverNewBorrow();

    /// @dev Health factor not below threshold
    error HealthFactorNotBelowThreshold();

    /// @dev Health factor lower than liquidation threshold
    error HealthFactorLowerThanLiquidationThreshold(uint256 health);

    /// @dev Liquidation window already opened
    error LiquidationAlreadyOpened();

    /// @dev Grace period not over
    error GracePeriodNotOver();

    /// @dev Liquidation expired
    error LiquidationExpired();

    /// @dev Reserve paused
    error ReservePaused();

    /// @dev Asset not listed
    error AssetNotListed();

    /// @dev Variable debt supply not zero
    error VariableDebtSupplyNotZero();

    /// @dev Zero address not valid
    error ZeroAddressNotValid();

    /// @dev Reserve already initialized
    error ReserveAlreadyInitialized();

    /// @dev Interest receiver not set
    error InterestReceiverNotSet();

    /// @dev Debt token not set
    error DebtTokenNotSet();

    /// @dev Minimum borrow amount
    error MinBorrowAmount();

    /// @notice Validate the borrow of an agent
    /// @dev Check the pause state of the reserve and the health of the agent before and after the
    /// borrow.
    /// @param $ Lender storage
    /// @param params Validation parameters
    function validateBorrow(ILender.LenderStorage storage $, ILender.BorrowParams memory params) external view {
        if (params.amount < $.reservesData[params.asset].minBorrow) revert MinBorrowAmount();
        if (params.receiver == address(0) || params.asset == address(0)) revert ZeroAddressNotValid();
        if ($.reservesData[params.asset].paused) revert ReservePaused();

        if (!params.maxBorrow) {
            uint256 borrowCapacity = ViewLogic.maxBorrowable($, params.agent, params.asset);
            if (params.amount > borrowCapacity) revert CollateralCannotCoverNewBorrow();
        }
    }

    /// @notice Validate the opening of the liquidation window of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    /// @param start Last liquidation start time
    /// @param expiry Liquidation duration after which it expires
    function validateOpenLiquidation(uint256 health, uint256 start, uint256 expiry) external view {
        if (health >= 1e27) revert HealthFactorNotBelowThreshold();
        if (block.timestamp <= start + expiry) revert LiquidationAlreadyOpened();
    }

    /// @notice Validate the liquidation of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    /// @param emergencyHealth Emergency health below which the grace period is voided
    /// @param start Last liquidation start time
    /// @param grace Grace period duration
    /// @param expiry Liquidation duration after which it expires
    function validateLiquidation(uint256 health, uint256 emergencyHealth, uint256 start, uint256 grace, uint256 expiry)
        external
        view
    {
        if (health >= 1e27) revert HealthFactorNotBelowThreshold();
        if (emergencyHealth >= 1e27) {
            if (block.timestamp <= start + grace) revert GracePeriodNotOver();
            if (block.timestamp >= start + expiry) revert LiquidationExpired();
        }
    }

    /// @notice Validate adding an asset as a reserve
    /// @param $ Lender storage
    /// @param params Parameters for adding an asset
    function validateAddAsset(ILender.LenderStorage storage $, ILender.AddAssetParams memory params) external view {
        if (params.asset == address(0) || params.vault == address(0)) revert ZeroAddressNotValid();
        if (params.interestReceiver == address(0)) revert InterestReceiverNotSet();
        if (params.debtToken == address(0)) revert DebtTokenNotSet();
        if ($.reservesData[params.asset].vault != address(0)) revert ReserveAlreadyInitialized();
    }

    /// @notice Validate dropping an asset as a reserve
    /// @dev All principal borrows must be repaid, interest is ignored
    /// @param $ Lender storage
    /// @param _asset Asset to remove
    function validateRemoveAsset(ILender.LenderStorage storage $, address _asset) external view {
        if (IERC20($.reservesData[_asset].debtToken).totalSupply() != 0) revert VariableDebtSupplyNotZero();
    }

    /// @notice Validate pausing a reserve
    /// @param $ Lender storage
    /// @param _asset Asset to pause
    function validatePauseAsset(ILender.LenderStorage storage $, address _asset) external view {
        if ($.reservesData[_asset].vault == address(0)) revert AssetNotListed();
    }

    /// @notice Validate setting the minimum borrow amount
    /// @param $ Lender storage
    /// @param _asset Asset to set minimum borrow amount
    function validateSetMinBorrow(ILender.LenderStorage storage $, address _asset) external view {
        if ($.reservesData[_asset].vault == address(0)) revert AssetNotListed();
    }

    /// @notice Validate the closing of the liquidation window of an agent
    /// @dev Health of above 1e27 is healthy, below is liquidatable
    /// @param health Health of an agent's position
    function validateCloseLiquidation(uint256 health) external pure {
        if (health < 1e27) revert HealthFactorLowerThanLiquidationThreshold(health);
    }
}

// contracts/lendingPool/libraries/BorrowLogic.sol

/// @title BorrowLogic
/// @author kexley, Cap Labs
/// @notice Logic for borrowing and repaying assets from the Lender
/// @dev Interest rates for borrowing are not based on utilization like other lending markets.
/// Instead the rates are based on a benchmark rate per asset set by an admin or an alternative
/// lending market rate, whichever is higher. Indexes representing the increase of interest over
/// time are pulled from an oracle. A separate interest rate is set by admin per agent which is
/// paid to the restakers that guarantee the agent.
library BorrowLogic {
    using SafeERC20 for IERC20;
    using AgentConfiguration for ILender.AgentConfigurationMap;

    /// @dev Details of a repayment
    /// @param repaid Amount repaid
    /// @param vaultRepaid Amount repaid to the vault
    /// @param restakerRepaid Amount repaid to the restaker
    /// @param interestRepaid Amount repaid to the interest receiver
    struct RepaymentDetails {
        uint256 repaid;
        uint256 vaultRepaid;
        uint256 restakerRepaid;
        uint256 interestRepaid;
    }

    /// @dev An agent has borrowed an asset from the Lender
    event Borrow(address indexed asset, address indexed agent, uint256 amount);

    /// @dev An agent, or someone on behalf of an agent, has repaid
    event Repay(address indexed asset, address indexed agent, RepaymentDetails details);

    /// @dev An agent has totally repaid their debt of an asset including all interests
    event TotalRepayment(address indexed agent, address indexed asset);

    /// @dev Realize interest before it is repaid by agents
    event RealizeInterest(address indexed asset, uint256 realizedInterest, address interestReceiver);

    /// @dev Trying to realize zero interest
    error ZeroRealization();

    /// @notice Borrow an asset from the Lender, minting a debt token which must be repaid
    /// @dev Interest debt token is updated before principal token is minted to bring index up to date.
    /// Restaker debt token is updated after so the new principal debt can be used in calculations
    /// @param $ Lender storage
    /// @param params Parameters to borrow an asset
    /// @return borrowed Actual amount borrowed
    function borrow(ILender.LenderStorage storage $, ILender.BorrowParams memory params)
        external
        returns (uint256 borrowed)
    {
        /// Realize restaker interest before borrowing
        realizeRestakerInterest($, params.agent, params.asset);

        if (params.maxBorrow) {
            params.amount = ViewLogic.maxBorrowable($, params.agent, params.asset);
        }

        ValidationLogic.validateBorrow($, params);

        IDelegation($.delegation).setLastBorrow(params.agent);

        ILender.ReserveData storage reserve = $.reservesData[params.asset];
        if (!$.agentConfig[params.agent].isBorrowing(reserve.id)) {
            $.agentConfig[params.agent].setBorrowing(reserve.id, true);
        }

        borrowed = params.amount;

        IVault(reserve.vault).borrow(params.asset, borrowed, params.receiver);

        IDebtToken(reserve.debtToken).mint(params.agent, borrowed);

        reserve.debt += borrowed;

        emit Borrow(params.asset, params.agent, borrowed);
    }

    /// @notice Repay an asset, burning the debt token and/or paying down interest
    /// @dev Only the amount owed or specified will be taken from the repayer, whichever is lower.
    /// Interest is expected to have been realized so is included in the reserve debt. Once reserve
    /// debt is paid down the remaining amount is sent to the fee auction.
    /// @param $ Lender storage
    /// @param params Parameters to repay a debt
    /// @return repaid Actual amount repaid
    function repay(ILender.LenderStorage storage $, ILender.RepayParams memory params)
        external
        returns (uint256 repaid)
    {
        /// Realize restaker interest before repaying
        realizeRestakerInterest($, params.agent, params.asset);

        ILender.ReserveData storage reserve = $.reservesData[params.asset];

        /// Can only repay up to the amount owed
        uint256 agentDebt = IERC20(reserve.debtToken).balanceOf(params.agent);
        repaid = Math.min(params.amount, agentDebt);

        uint256 remainingDebt = agentDebt - repaid;
        if (remainingDebt > 0 && remainingDebt < reserve.minBorrow) {
            // Limit repayment to maintain minimum debt if not full repayment
            repaid = agentDebt - reserve.minBorrow;
        }

        IERC20(params.asset).safeTransferFrom(params.caller, address(this), repaid);

        uint256 remaining = repaid;
        uint256 interestRepaid;
        uint256 restakerRepaid;

        if (repaid > reserve.unrealizedInterest[params.agent] + reserve.debt) {
            interestRepaid = repaid - (reserve.debt + reserve.unrealizedInterest[params.agent]);
            remaining -= interestRepaid;
        }

        if (remaining > reserve.unrealizedInterest[params.agent]) {
            restakerRepaid = reserve.unrealizedInterest[params.agent];
            remaining -= restakerRepaid;
        } else {
            restakerRepaid = remaining;
            remaining = 0;
        }

        uint256 vaultRepaid = Math.min(remaining, reserve.debt);

        if (restakerRepaid > 0) {
            reserve.unrealizedInterest[params.agent] -= restakerRepaid;
            reserve.totalUnrealizedInterest -= restakerRepaid;
            IERC20(params.asset).safeTransfer($.delegation, restakerRepaid);
            IDelegation($.delegation).distributeRewards(params.agent, params.asset);
            emit RealizeInterest(params.asset, restakerRepaid, $.delegation);
        }

        if (vaultRepaid > 0) {
            reserve.debt -= vaultRepaid;
            IERC20(params.asset).forceApprove(reserve.vault, vaultRepaid);
            IVault(reserve.vault).repay(params.asset, vaultRepaid);
        }

        if (interestRepaid > 0) {
            IERC20(params.asset).safeTransfer(reserve.interestReceiver, interestRepaid);
            emit RealizeInterest(params.asset, interestRepaid, reserve.interestReceiver);
        }

        IDebtToken(reserve.debtToken).burn(params.agent, repaid);

        if (IERC20(reserve.debtToken).balanceOf(params.agent) == 0) {
            $.agentConfig[params.agent].setBorrowing(reserve.id, false);
            emit TotalRepayment(params.agent, params.asset);
        }

        emit Repay(
            params.asset,
            params.agent,
            RepaymentDetails({
                repaid: repaid,
                vaultRepaid: vaultRepaid,
                restakerRepaid: restakerRepaid,
                interestRepaid: interestRepaid
            })
        );
    }

    /// @notice Realize the interest before it is repaid by borrowing from the vault
    /// @param $ Lender storage
    /// @param _asset Asset to realize interest for
    /// @return realizedInterest Actual realized interest
    function realizeInterest(ILender.LenderStorage storage $, address _asset)
        external
        returns (uint256 realizedInterest)
    {
        ILender.ReserveData storage reserve = $.reservesData[_asset];
        realizedInterest = maxRealization($, _asset);
        if (realizedInterest == 0) revert ZeroRealization();

        reserve.debt += realizedInterest;
        IVault(reserve.vault).borrow(_asset, realizedInterest, reserve.interestReceiver);
        emit RealizeInterest(_asset, realizedInterest, reserve.interestReceiver);
    }

    /// @notice Realize the restaker interest before it is repaid by borrowing from the vault
    /// @dev If more interest is owed than available in the vault then some portion is unrealized
    /// and added to the agent's debt to be paid during repayments.
    /// @param $ Lender storage
    /// @param _agent Address of the restaker
    /// @param _asset Asset to realize restaker interest for
    /// @return realizedInterest Actual realized restaker interest
    function realizeRestakerInterest(ILender.LenderStorage storage $, address _agent, address _asset)
        public
        returns (uint256 realizedInterest)
    {
        ILender.ReserveData storage reserve = $.reservesData[_asset];
        uint256 unrealizedInterest;
        (realizedInterest, unrealizedInterest) = maxRestakerRealization($, _agent, _asset);
        reserve.lastRealizationTime[_agent] = block.timestamp;

        if (realizedInterest == 0 && unrealizedInterest == 0) return 0;

        reserve.debt += realizedInterest;
        reserve.unrealizedInterest[_agent] += unrealizedInterest;
        reserve.totalUnrealizedInterest += unrealizedInterest;

        IDebtToken(reserve.debtToken).mint(_agent, realizedInterest + unrealizedInterest);
        if (realizedInterest > 0) {
            IVault(reserve.vault).borrow(_asset, realizedInterest, $.delegation);
            IDelegation($.delegation).distributeRewards(_agent, _asset);
        }

        emit RealizeInterest(_asset, realizedInterest, $.delegation);
    }

    /// @notice Calculate the maximum interest that can be realized
    /// @param $ Lender storage
    /// @param _asset Asset to calculate max realization for
    /// @return realization Maximum interest that can be realized
    function maxRealization(ILender.LenderStorage storage $, address _asset)
        internal
        view
        returns (uint256 realization)
    {
        ILender.ReserveData storage reserve = $.reservesData[_asset];
        uint256 totalDebt = IERC20(reserve.debtToken).totalSupply();
        uint256 reserves = IVault(reserve.vault).availableBalance(_asset);
        uint256 vaultDebt = reserve.debt;
        uint256 totalUnrealizedInterest = reserve.totalUnrealizedInterest;

        if (totalDebt > vaultDebt + totalUnrealizedInterest) {
            realization = totalDebt - vaultDebt - totalUnrealizedInterest;
        }
        if (reserves < realization) {
            realization = reserves;
        }
        if (reserve.paused) realization = 0;
    }

    /// @notice Calculate the maximum interest that can be realized for a restaker
    /// @param $ Lender storage
    /// @param _agent Address of the restaker
    /// @param _asset Asset to calculate max realization for
    /// @return realization Maximum interest that can be realized
    /// @return unrealizedInterest Unrealized interest that can be realized
    function maxRestakerRealization(ILender.LenderStorage storage $, address _agent, address _asset)
        internal
        view
        returns (uint256 realization, uint256 unrealizedInterest)
    {
        ILender.ReserveData storage reserve = $.reservesData[_asset];
        uint256 accruedInterest = ViewLogic.accruedRestakerInterest($, _agent, _asset);
        uint256 reserves = IVault(reserve.vault).availableBalance(_asset);

        realization = accruedInterest;
        if (reserve.paused) {
            unrealizedInterest = realization;
            realization = 0;
        } else if (realization > reserves) {
            unrealizedInterest = realization - reserves;
            realization = reserves;
        }
    }
}
