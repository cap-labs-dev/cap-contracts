// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import { BaseStrategy, ERC20 } from "@tokenized-strategy/BaseStrategy.sol";

/// @title TokenHolder
/// @author kexley, Cap Labs
/// @notice A strategy that holds tokens and only allows the vault to deposit and withdraw.
contract TokenHolder is BaseStrategy {
    /// @notice The vault that can deposit and withdraw
    address public immutable vault;

    /// @dev Constructor
    /// @param _asset The asset to hold
    /// @param _name The name of the strategy
    /// @param _vault The vault that can deposit and withdraw
    constructor(address _asset, string memory _name, address _vault) BaseStrategy(_asset, _name) {
        vault = _vault;
    }

    /*//////////////////////////////////////////////////////////////
                NEEDED TO BE OVERRIDDEN BY STRATEGIST
    //////////////////////////////////////////////////////////////*/

    /// @notice Should deploy up to '_amount' of 'asset' in the yield source.
    /// @param _amount The amount of 'asset' that the strategy should attempt
    /// to deposit in the yield source.
    ///
    /// This function is called at the end of a {deposit} or {mint}
    /// call. Meaning that unless a whitelist is implemented it will
    /// be entirely permissionless and thus can be sandwiched or otherwise
    /// manipulated.
    ///
    /// @param _amount The amount of 'asset' that the strategy should attempt
    /// to deposit in the yield source.
    function _deployFunds(uint256 _amount) internal override {
        // Left empty as funds do not leave the contract.
    }

    /// @notice Will attempt to free the '_amount' of 'asset'.
    ///
    /// @dev The amount of 'asset' that is already loose has already
    /// been accounted for.
    ///
    /// This function is called during {withdraw} and {redeem} calls.
    /// Meaning that unless a whitelist is implemented it will be
    /// entirely permissionless and thus can be sandwiched or otherwise
    /// manipulated.
    ///
    /// Should not rely on asset.balanceOf(address(this)) calls other than
    /// for diff accounting purposes.
    ///
    /// Any difference between `_amount` and what is actually freed will be
    /// counted as a loss and passed on to the withdrawer. This means
    /// care should be taken in times of illiquidity. It may be better to revert
    /// if withdraws are simply illiquid so not to realize incorrect losses.
    ///
    /// Any difference between `_amount` and what is actually freed will be
    /// counted as a loss and passed on to the withdrawer. This means
    /// care should be taken in times of illiquidity. It may be better to revert
    /// if withdraws are simply illiquid so not to realize incorrect losses.
    ///
    /// @param _amount The amount of 'asset' to be freed.
    function _freeFunds(uint256 _amount) internal override {
        // Left empty as funds do not leave the contract.
    }

    /// @dev Internal function to harvest all rewards, redeploy any idle
    /// funds and return an accurate accounting of all funds currently
    /// held by the Strategy.
    ///
    /// @dev This should do any needed harvesting, rewards selling, accrual,
    /// redepositing etc. to get the most accurate view of current assets.
    ///
    /// NOTE: All applicable assets including loose assets should be
    /// accounted for in this function.
    ///
    /// Care should be taken when relying on oracles or swap values rather
    /// than actual amounts as all Strategy profit/loss accounting will
    /// be done based on this returned value.
    ///
    /// This can still be called post a shutdown, a strategist can check
    /// `TokenizedStrategy.isShutdown()` to decide if funds should be
    /// redeployed or simply realize any profits/losses.
    ///
    /// @return _totalAssets A trusted and accurate account for the total
    /// amount of 'asset' the strategy currently holds including idle funds.
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        _totalAssets = balanceOfAsset();
    }

    function balanceOfAsset() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Gets the max amount of `asset` that an address can deposit.
    /// @dev Defaults to an unlimited amount for any address. But can
    /// be overridden by strategists.
    ///
    /// This function will be called before any deposit or mints to enforce
    /// any limits desired by the strategist. This can be used for either a
    /// traditional deposit limit or for implementing a whitelist etc.
    ///
    ///   EX:
    ///      if(isAllowed[_owner]) return super.availableDepositLimit(_owner);
    ///
    /// This does not need to take into account any conversion rates
    /// from shares to assets. But should know that any non max uint256
    /// amounts may be converted to shares. So it is recommended to keep
    /// custom amounts low enough as not to cause overflow when multiplied
    /// by `totalSupply`.
    ///
    /// @param _owner The address that is depositing into the strategy.
    /// @return The available amount the `_owner` can deposit in terms of `asset`
    function availableDepositLimit(address _owner) public view override returns (uint256) {
        // Only allow the cap vault to deposit.
        if (_owner != vault) {
            return 0;
        } else {
            return type(uint256).max;
        }
    }

    /// @notice Gets the max amount of `asset` that can be withdrawn.
    /// @dev Defaults to an unlimited amount for any address. But can
    /// be overridden by strategists.
    ///
    /// This function will be called before any withdraw or redeem to enforce
    /// any limits desired by the strategist. This can be used for illiquid
    /// or sandwichable strategies. It should never be lower than `totalIdle`.
    ///
    ///   EX:
    ///       return TokenIzedStrategy.totalIdle();
    ///
    /// This does not need to take into account the `_owner`'s share balance
    /// or conversion rates from shares to assets.
    ///
    /// @param _owner The address that is withdrawing from the strategy.
    /// @return The available amount that can be withdrawn in terms of `asset`
    function availableWithdrawLimit(address _owner) public view override returns (uint256) {
        // Only allow the cap vault to withdraw.
        if (_owner != vault) {
            return 0;
        } else {
            return type(uint256).max;
        }
    }
}
