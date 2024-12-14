// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { Errors } from '../libraries/helpers/Errors.sol';
import { IRewarder } from '../../interfaces/IRewarder.sol';
import { IPool } from '../../interfaces/IPool.sol';

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @title ERC20 cToken
/// @author kexley, inspired by Aave
/// @notice Implementation of the supply token for the Cap protocol. cTokens are 1:1 redeemable
/// with the underlying asset.
contract cToken is ERC20PermitUpgradeable {
    /// @dev Lending pool that this cToken relates to
    IPool private _pool;

    /// @dev Underlying asset address
    IERC20 private _underlyingAsset;

    /// @dev Decimals matching the underlying asset
    uint8 private _decimals;

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

        string memory name = "c" + _underlyingAsset.name();
        string memory symbol = "c" + _underlyingAsset.symbol();
        _decimals = _underlyingAsset.decimals();

        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
    }

    /// @notice Decimals of the asset
    /// @return decimal Decimals
    function decimals() public view override returns (uint8 decimal) {
        decimal = _decimals;
    }

    /// @notice Mint a cToken to a user
    /// @param to Receiver of the minted cTokens
    /// @param amount Amount of cTokens to mint
    function mint(address to, uint256 amount) external onlyPool {
        _mint(to, amount);
    }

    /// @notice Burn a cToken from a user
    /// @param from User to burn from
    /// @param to Receiver of the released underlying
    /// @param amount Amount of cTokens to burn
    function burn(address from, address to, uint256 amount) external onlyPool {
        _burn(from, amount);
        _underlyingAsset.safeTransfer(to, amount);
    }

    /// @notice Total supply of the cToken including the accrued amount to treasury
    /// @return supply Total supply
    function totalSupply() public view override returns (uint256 supply) {
        supply = super.totalSupply() + _pool.getAccruedToTreasury(_underlyingAsset);
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

    /// @notice Transfer the underlying asset on a borrow
    /// @param receiver Receiver of the asset
    /// @param amount Amount of the asset to transfer
    function transferUnderlyingTo(address receiver, uint256 amount) external onlyPool {
        _underlyingAsset.safeTransfer(receiver, amount);
    }

    /// @notice Rescue tokens other than the underlying from this contract
    /// @param token Token to rescue
    /// @param to Receiver of the tokens
    /// @param amount Amount to transfer
    function rescueTokens(address token, address to, uint256 amount) external override onlyPool {
        require(token != _underlyingAsset, Errors.UNDERLYING_CANNOT_BE_RESCUED);
        IERC20(token).safeTransfer(to, amount);
    }

    /// @dev Notify the rewarder that a transfer has happened and update rewards
    /// @param from Source of the token transfer
    /// @param to Receiver of the token transfer
    /// @param value Amount of tokens transferred
    function _update(address from, address to, uint256 value) internal override {
        address rewarder = IPoolAddressProvider(_pool.ADDRESS_PROVIDER()).getRewarder();
        if (rewarder != address(0)) IRewarder(rewarder).handleAction(
            from,
            to,
            value,
            totalSupply()
        );

        super._update(from, to, value);
    }
}