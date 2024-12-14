// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { Errors } from '../libraries/helpers/Errors.sol';
import { IRewarder } from '../../interfaces/IRewarder.sol';
import { IPool } from '../../interfaces/IPool.sol';

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/// @title ERC20 vToken
/// @author kexley, inspired by Aave
/// @notice Implementation of the borrow token for the Cap protocol. Balances are scaled by the
/// variable debt index of the reserve.
contract vToken is ERC20Upgradeable {
    using WadRayMath for uint256;

    /// @dev Lending pool that this cToken relates to
    IPool private _pool;

    /// @dev Underlying asset address
    IERC20 private _underlyingAsset;

    /// @dev Decimals matching the underlying asset
    uint8 private _decimals;

    /// @dev Scaled balance of users
    mapping(address => uint256) private _scaledBalance;

    /// @dev Stored index for each user
    mapping(address => uint256) private _index;

    /// @dev Borrow allowance of a delegatee
    mapping(address => mapping(address => uint256)) internal _borrowAllowances;

    /// @dev Scaled total supply
    uint256 private _scaledTotalSupply;

    /// @dev Emitted on a change of borrow allowance
    event BorrowAllowanceDelegated(address indexed delegator, address indexed delegatee, uint256 amount);

    /// @dev Modifier to check that the caller is the pool
    modifier onlyPool() {
        require(address(_pool) == msg.sender, Errors.NOT_POOL);
        _;
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @dev Initialize the contract using the underlying asset as the base asset
    /// @param underlyingAsset Address of the underlying asset
    function initialize(address underlyingAsset) external initializer {
        _pool = IPool(msg.sender);
        _underlyingAsset = IERC20(underlyingAsset);

        string memory name = "v" + underlyingAsset_.name();
        string memory symbol = "v" + underlyingAsset_.symbol();
        _decimals = _underlyingAsset.decimals();

        __ERC20_init(name, symbol);
    }

    /// @notice Decimals of the asset
    /// @return decimal Decimals
    function decimals() public view override returns (uint8 decimal) {
        decimal = _decimals;
    }

    /// @notice Mint a debt position to a user
    /// @param caller Caller of the borrow and receiver of borrowed funds. Must be the agent or a 
    /// delegated address.
    /// @param onBehalfOf Address of the agent who will hold this debt position
    /// @param amount Amount of underlying asset to borrow
    /// @param index Current debt index of the reserve
    /// @return isFirstBorrow Is the first time this asset has been borrowed by this agent
    function mint(
        address caller,
        address onBehalfOf,
        uint256 amount,
        uint256 index
    ) external onlyPool returns (bool isFirstBorrow) {
        if (caller != onBehalfOf) {
            uint256 newBorrowAllowance = _borrowAllowances[onBehalfOf][caller] - amount;
            _delegate(onBehalfOf, caller, newBorrowAllowance);
        }

        uint256 amountScaled = amount.rayDiv(index);
        require(amountScaled != 0, Errors.INVALID_MINT_AMOUNT);

        uint256 scaledBalance = _scaledBalance[onBehalfOf];
        uint256 balanceIncrease = scaledBalance.rayMul(index) - scaledBalance.rayMul(_index[onBehalfOf]);
        _index[onBehalfOf] = index;

        address rewarder = IPoolAddressProvider(_pool.ADDRESS_PROVIDER()).getRewarder();
        if (rewarder != address(0)) IRewarder(rewarder).handleAction(
            address(0),
            onBehalfOf,
            amountScaled,
            _totalSupply
        );

        _scaledBalance[onBehalfOf] += amountScaled;
        _scaledTotalSupply += amountScaled;

        uint256 amountToMint = amount + balanceIncrease;
        emit Transfer(address(0), onBehalfOf, amountToMint);

        isFirstBorrow = balance == 0;
    }

    /// @notice Burn a debt position from an agent
    /// @param from Address of the agent who is burning the debt position
    /// @param amount Amount of underlying asset to repay
    /// @param index Current debt index of the reserve
    function burn(address from, uint256 amount, uint256 index) external onlyPool {
        uint256 amountScaled = amount.rayDiv(index);
        require(amountScaled != 0, Errors.INVALID_BURN_AMOUNT);

        uint256 scaledBalance = _scaledBalance[from];
        uint256 balanceIncrease = scaledBalance.rayMul(index) - scaledBalance.rayMul(_index[from]);
        _index[from] = index;

        address rewarder = IPoolAddressProvider(_pool.ADDRESS_PROVIDER()).getRewarder();
        if (rewarder != address(0)) IRewarder(rewarder).handleAction(
            from,
            address(0),
            amountScaled,
            _scaledTotalSupply
        );

        _scaledBalance[from] -= amountScaled;
        _scaledTotalSupply -= amountScaled;

        if (balanceIncrease > amount) {
            uint256 amountToMint = balanceIncrease - amount;
            emit Transfer(address(0), from, amountToMint);
        } else {
            uint256 amountToBurn = amount - balanceIncrease;
            emit Transfer(from, address(0), amountToBurn);
        }
    }

    /// @notice Balance of an agent's debt including interest
    /// @param user Agent with a borrow position
    /// @return balance Amount of debt
    function balanceOf(address user) external override returns (uint256 balance) {
        balance = _scaledBalance[user].rayMul(_pool.getReserveNormalizedVariableDebt(_underlyingAsset));
    }

    /// @notice Total debt including interest
    /// @return debt Total debt of the reserve
    function totalSupply() public view override returns (uint256 debt) {
        debt = _scaledTotalSupply.rayMul(_pool.getReserveNormalizedVariableDebt(_underlyingAsset));
    }

    /// @notice Total scaled debt
    /// @return debt Total scaled debt of the reserve
    function scaledTotalSupply() external view returns (uint256 scaledSupply) {
        scaledSupply = _totalSupply;
    }

    /// @notice Lending pool address
    /// @return lendingPool Address of the lending pool
    function pool() external view returns (address lendingPool) {
        lendingPool = address(_pool);
    }

    /// @notice Underlying asset
    /// @return asset Address of the underlying asset
    function underlying() external view returns (address asset) {
        asset = address(_underlyingAsset);
    }

    /// @notice Delegate borrowing power
    /// @param delegatee Delegatee to give credit to
    /// @param amount Amount of credit to extend to the delegatee
    function delegate(address delegatee, uint256 amount) external {
        _delegate(msg.sender, delegatee, amount);
    }

    /// @notice Borrow allowance of a delegatee from an agent
    /// @param delegator Delegator of credit
    /// @param delegatee Receiver of the credit
    /// @param allowance Amount of credit that has been extended
    function borrowAllowance(
        address delegator,
        address delegatee
    ) external view returns (uint256 allowance) {
        allowance = _borrowAllowances[delegator][delegatee];
    }

    /// @dev Delegate borrowing power
    /// @param delegator Delegator of credit 
    /// @param delegatee Delegatee to give credit to
    /// @param amount Amount of credit to extend to the delegatee
    function _delegate(address delegator, address delegatee, uint256 amount) internal {
        _borrowAllowances[delegator][delegatee] = amount;
        emit BorrowAllowanceDelegated(delegator, delegatee, amount);
    }

    /// @notice Disabled due to being non-transferrable
    function transfer(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to being non-transferrable
    function transferFrom(address, address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to being non-transferrable
    function allowance(address, address) external view virtual override returns (uint256) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to being non-transferrable
    function approve(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to being non-transferrable
    function increaseAllowance(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to being non-transferrable
    function decreaseAllowance(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }
}