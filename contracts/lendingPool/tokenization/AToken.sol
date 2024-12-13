// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import { Errors } from '../libraries/helpers/Errors.sol';
import { IRewarder } from '../../interfaces/IRewarder.sol';
import { IPool } from '../../interfaces/IPool.sol';

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/**
 * @title ERC20 cToken
 * @author kexley
 * @notice Implementation of the supply token for the Cap protocol
 */
contract cToken is ERC20PermitUpgradeable {
    IPool private _pool;
    IERC20 private _underlyingAsset;

    modifier onlyPool() {
        require(address(_pool) == msg.sender, Errors.NOT_POOL);
        _;
    }

    function initialize(IPool pool_, IERC20 underlyingAsset_) external initializer {
        _pool = pool_;
        _underlyingAsset = underlyingAsset_;

        string memory name = "c" + underlyingAsset_.name();
        string memory symbol = "c" + underlyingAsset_.symbol();

        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
    }

    function decimals() public view override returns (uint8) {
        return _underlyingAsset.decimals();
    }

    /// @inheritdoc IAToken
    function mint(address to, uint256 amount) external onlyPool returns (bool) {
        uint256 balance = balanceOf(to);

        _mint(to, amount);

        return (balance == 0);
    }

    /// @inheritdoc IAToken
    function burn(address from, address to, uint256 amount) external onlyPool {
        _burn(from, amount);
        _underlyingAsset.safeTransfer(to, amount);
    }

    /// @inheritdoc IERC20
    function totalSupply() public view override returns (uint256) {
        return super.totalSupply() + _pool.getAccruedToTreasury(_underlyingAsset);
    }

    /// @inheritdoc IAToken
    function pool() external view returns (address) {
        return address(_pool);
    }

    /// @inheritdoc IAToken
    function underlying() external view returns (address) {
        return address(_underlyingAsset);
    }

    /// @inheritdoc IAToken
    function transferUnderlyingTo(address target, uint256 amount) external onlyPool {
        _underlyingAsset.safeTransfer(target, amount);
    }

    /// @inheritdoc IAToken
    function handleRepayment(
        address user,
        address onBehalfOf,
        uint256 amount
    ) external onlyPool {
        // Intentionally left blank
    }

    /// @inheritdoc IAToken
    function rescueTokens(address token, address to, uint256 amount) external override onlyPool {
        require(token != _underlyingAsset, Errors.UNDERLYING_CANNOT_BE_RESCUED);
        IERC20(token).safeTransfer(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        address rewarder = _pool.rewarder();
        if (rewarder != address(0)) IRewarder(_pool.rewarder()).handleAction(from, to, value, totalSupply());

        super._update(from, to, value);
    }
}