// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title DeadShares
/// @author kexley
/// @notice A permanent floor under the share supply of {Tranche} and {Underwriter}, paid for by
/// the first deposit.
/// @dev Anyone can add to the balance `totalAssets` reads without minting against it. On an empty
/// vault that is the inflation attack: buy the whole supply for a wei, donate enough to round the
/// next depositor's shares to zero, then redeem both stakes. Owning the supply makes the donation
/// free.
///
/// A floor breaks it because the attacker can only ever hold a fraction of {SHARES}, so the
/// donation costs a multiple of the target's deposit and mostly does not come back. Preferred to a
/// decimals offset, which would push `decimals` above the asset's.
///
/// It has to be priced in rather than minted alongside the first deposit, because OpenZeppelin
/// fixes the share count from `previewDeposit` before minting. {seedDeposit} and {seedMint} quote
/// the empty vault at par, ignoring `totalAssets`, so an early donation is a windfall for the
/// first depositor rather than a trap.
library DeadShares {
    /// @notice Shares carved out of the first deposit and left unredeemable for good
    uint256 internal constant SHARES = 1e3;

    /// @notice Where the seed is sent, picked because nothing can ever spend from it
    /// @dev Not `address(0)`, which OpenZeppelin's `_mint` rejects, and not the vault itself, whose
    /// own balance already carries the redemption queue and would conflate the two.
    address internal constant HOLDER = 0x000000000000000000000000000000000000dEaD;

    /// @notice A first deposit too small to cover the seed
    error DepositBelowSeed(uint256 assets, uint256 seed);

    /// @dev Shares a deposit into an empty vault buys, quoted at par so that assets already sitting
    /// in the vault cannot set the rate. The seed comes out of this deposit rather than diluting
    /// it afterwards, so what the depositor is quoted is what they end up holding.
    /// @param assets The assets being deposited
    /// @return shares The shares for the depositor, with the seed already deducted
    function seedDeposit(uint256 assets) internal pure returns (uint256 shares) {
        if (assets <= SHARES) revert DepositBelowSeed(assets, SHARES);
        shares = assets - SHARES;
    }

    /// @dev Assets a mint from an empty vault costs, the inverse of {seedDeposit}: the caller pays
    /// for their own shares and for the seed alongside them.
    /// @param shares The shares being minted for the depositor
    /// @return assets The assets owed, covering the seed as well
    function seedMint(uint256 shares) internal pure returns (uint256 assets) {
        assets = shares + SHARES;
    }
}
