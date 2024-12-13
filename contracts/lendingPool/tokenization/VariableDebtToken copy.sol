// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { Errors } from '../libraries/helpers/Errors.sol';
import { IRewarder } from '../../interfaces/IRewarder.sol';
import { IPool } from '../../interfaces/IPool.sol';

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title ERC20 vToken
 * @author kexley
 * @notice Implementation of the borrow token for the Cap protocol
 */
contract vToken is ERC20Upgradeable {
    using WadRayMath for uint256;

    IPool private _pool;
    IERC20 private _underlyingAsset;
    mapping(address => uint256) private _scaledBalance;
    mapping(address => uint256) private _index;
    uint256 private _scaledTotalSupply;

    modifier onlyPool() {
        require(address(_pool) == msg.sender, Errors.NOT_POOL);
        _;
    }

    function initialize(IPool pool_, IERC20 underlyingAsset_) external initializer {
        _pool = pool_;
        _underlyingAsset = underlyingAsset_;

        string memory name = "v" + underlyingAsset_.name();
        string memory symbol = "v" + underlyingAsset_.symbol();

        __ERC20_init(name, symbol);
    }

    function decimals() public view override returns (uint8) {
        return _underlyingAsset.decimals();
    }

    /// @inheritdoc IAToken
    function mint(address to, uint256 amount, uint256 index) external onlyPool returns (bool) {
        uint256 amountScaled = amount.rayDiv(index);
        require(amountScaled != 0, Errors.INVALID_MINT_AMOUNT);

        uint256 scaledBalance = _scaledBalance[to];
        uint256 balanceIncrease = scaledBalance.rayMul(index) - scaledBalance.rayMul(_index[to]);
        _index[to] = index;

        address rewarder = _pool.rewarder();
        if (rewarder != address(0)) IRewarder(_pool.rewarder()).handleAction(
            address(0),
            to,
            amountScaled,
            _totalSupply
        );

        _scaledBalance[to] += amountScaled;
        _scaledTotalSupply += amountScaled;

        uint256 amountToMint = amount + balanceIncrease;
        emit Transfer(address(0), to, amountToMint);

        return (balance == 0);
    }

    /// @inheritdoc IAToken
    function burn(address from, uint256 amount, uint256 index) external onlyPool {
        uint256 amountScaled = amount.rayDiv(index);
        require(amountScaled != 0, Errors.INVALID_BURN_AMOUNT);

        uint256 scaledBalance = _scaledBalance[from];
        uint256 balanceIncrease = scaledBalance.rayMul(index) - scaledBalance.rayMul(_index[from]);
        _index[from] = index;

        address rewarder = _pool.rewarder();
        if (rewarder != address(0)) IRewarder(_pool.rewarder()).handleAction(
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

    /// @notice Balance of a user's debt
    /// @param user User with a borrow position
    /// @param balance Amount of debt
    function balanceOf(address user) external override returns (uint256 balance) {
        balance = _scaledBalance[user].rayMul(_pool.getReserveNormalizedVariableDebt(_underlyingAsset));
    }

    /// @inheritdoc IERC20
    function totalSupply() public view override returns (uint256) {
        return _scaledTotalSupply.rayMul(_pool.getReserveNormalizedVariableDebt(_underlyingAsset));
    }

    /// @inheritdoc IAToken
    function pool() external view returns (address) {
        return address(_pool);
    }

    /// @inheritdoc IAToken
    function underlying() external view returns (address) {
        return address(_underlyingAsset);
    }

    /**
    * @dev Being non transferrable, the debt token does not implement any of the
    * standard ERC20 functions for transfer and allowance.
    */
    function transfer(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function transferFrom(address, address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function allowance(address, address) external view virtual override returns (uint256) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function approve(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function increaseAllowance(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function decreaseAllowance(address, uint256) external virtual override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }
}