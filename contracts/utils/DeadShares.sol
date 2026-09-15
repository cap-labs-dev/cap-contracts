// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title DeadShares
/// @author kexley
/// @notice Permanent share-supply floor for {Tranche} and {Underwriter}, paid by the first deposit
/// @dev Blocks the empty-vault inflation attack. Quoted at par.
library DeadShares {
    /// @notice Shares carved out of the first deposit and left unredeemable for good
    uint256 internal constant SHARES = 1e3;

    /// @notice Unspendable holder for the seed
    /// @dev Not `address(0)` (`_mint` rejects it) and not the vault (redemption-queue collision).
    address internal constant HOLDER = 0x000000000000000000000000000000000000dEaD;

    /// @notice The first deposit is too small to cover the seed
    error DepositBelowSeed(uint256 assets, uint256 seed);

    /// @dev Calculate the shares returned for a first deposit of assets, minus the seed
    /// @param assets The assets being deposited
    /// @return shares The shares for the depositor, with the seed already deducted
    function seedDeposit(uint256 assets) internal pure returns (uint256 shares) {
        if (assets <= SHARES) revert DepositBelowSeed(assets, SHARES);
        shares = assets - SHARES;
    }

    /// @dev Inverse of {seedDeposit}
    /// @param shares The shares being minted for the depositor
    /// @return assets The assets owed, covering the seed as well
    function seedMint(uint256 shares) internal pure returns (uint256 assets) {
        assets = shares + SHARES;
    }
}
