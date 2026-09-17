// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IStablecoin
/// @author kexley, Cap Labs
/// @notice Interface for the credit-backed ERC-7540 stablecoin
/// @dev The implementation is ERC-20 with ERC-2612
interface IStablecoin {
    /// @notice Emitted when credit-backed tokens are minted
    /// @param to The recipient
    /// @param amount The amount minted, in cUSD share units (18 decimals)
    event MintCreditBacked(address indexed to, uint256 amount);

    /// @notice Emitted when credit-backed tokens are burned
    /// @param from The account burned from
    /// @param amount The amount burned, in cUSD share units (18 decimals)
    event BurnCreditBacked(address indexed from, uint256 amount);

    /// @notice Emitted when a reserve loss is recognized
    /// @dev Guardian action; no market. Lifetime total is the sum of these logs.
    /// @param amount The bad debt recognized, in cUSD share units (18 decimals)
    event BadDebtRecognizedInReserve(uint256 amount);

    /// @notice Emitted when a credit loss is recognized
    /// @dev `market` is the caller. Lifetime total is the sum of credit and reserve logs.
    /// @param market The market that recognized the loss
    /// @param amount The bad debt recognized, in cUSD share units (18 decimals)
    event BadDebtRecognizedInCredit(address indexed market, uint256 amount);

    /// @notice Emitted when bad debt is reduced
    /// @param owner The account whose redemption reduced bad debt
    /// @param amount The bad debt reduced, in cUSD share units (18 decimals)
    event BadDebtReduced(address indexed owner, uint256 amount);

    /// @notice Emitted when bad debt is covered outright
    /// @param payer The account that burned cUSD to retire the shortfall
    /// @param amount The bad debt covered, in cUSD share units (18 decimals)
    event BadDebtCovered(address indexed payer, uint256 amount);

    /// @notice Emitted when reserve is sent to the reserve vault
    /// @param reserveVault The vault that received the reserve
    /// @param assets The underlying reserve-token units sent
    event Invested(address indexed reserveVault, uint256 assets);

    /// @notice Emitted when reserve is recalled from the reserve vault
    /// @param reserveVault The vault that returned the reserve
    /// @param assets The underlying reserve-token units recalled
    event Recalled(address indexed reserveVault, uint256 assets);

    /// @notice Emitted when the reserve vault is updated
    /// @param previousVault The previous reserve vault
    /// @param newVault The new reserve vault, or the zero address when investing is disabled
    event SetReserveVault(address indexed previousVault, address indexed newVault);

    /// @notice The protocol has no bad debt left to cover
    error NoBadDebt();

    /// @notice The underlying has more decimals than the share
    error UnsupportedDecimals();

    /// @notice The amount is zero
    error InvalidAmount();

    /// @notice The bad debt exceeds the supply that can bear it
    /// @dev Credit write-offs are bounded by total supply. Reserve losses are bounded by
    /// `totalSupply - creditBackedSupply`, so `badDebt + creditBackedSupply` never exceeds supply.
    error BadDebtExceedsSupply();

    /// @notice Initialize the stablecoin
    /// @dev `reinitializer(2)` so a v1 proxy can be upgraded onto this implementation and run
    /// initialize again. Fresh proxies take the same path.
    /// @param authority The access manager address
    /// @param asset The underlying asset address
    /// @param name The token name
    /// @param symbol The token symbol
    /// @param irm The interest rate model address
    /// @param reserveVault The Aera vault that may hold idle reserve
    function initialize(
        address authority,
        address asset,
        string memory name,
        string memory symbol,
        address irm,
        address reserveVault
    ) external;

    /// @notice Mint credit-backed tokens for a borrow or reward
    /// @param to The recipient
    /// @param amount The amount to mint, in cUSD share units (18 decimals)
    function mintCreditBacked(address to, uint256 amount) external;

    /// @notice Burn credit-backed tokens on repay or liquidation
    /// @param from The account to burn from
    /// @param amount The amount to burn, in cUSD share units (18 decimals)
    function burnCreditBacked(address from, uint256 amount) external;

    /// @notice Deposit underlying and vest the minted cUSD as yield
    /// @dev Permissionless
    /// @param premium The underlying amount to deposit
    function fund(uint256 premium) external;

    /// @notice Mint credit-backed cUSD to this contract and vest it as premium
    /// @param premium The cUSD amount to mint and vest, in cUSD share units (18 decimals)
    function fundCreditBacked(uint256 premium) external;

    /// @notice Send underlying reserve to the reserve vault
    /// @param amount The underlying amount to send
    function invest(uint256 amount) external;

    /// @notice Recall underlying reserve from the Aera vault
    /// @dev Keeper can recall reserve funds from the vault
    /// @param amount The underlying amount to recall
    function recall(uint256 amount) external;

    /// @notice Set the reserve vault used for future investment and recall calls
    /// @dev Governance only. The zero address is valid when no investment vault is configured.
    /// This does not migrate or recover assets held by the previous vault.
    /// @param newReserveVault The new reserve vault
    function setReserveVault(address newReserveVault) external;

    /// @notice Pause minting and burning
    /// @dev Guardian only. Transfers still work. A panic switch while an issue is sorted out.
    /// Reverts {Pausable-EnforcedPause} on a mint or burn while paused.
    function pause() external;

    /// @notice Resume minting and burning
    /// @dev Guardian only.
    function unpause() external;

    /// @notice Recognize a loss in the reserve vault, socializing it across holders
    /// @dev Guardian only. Credit-backed supply is unchanged because no borrower debt was lost.
    /// `amount` is cUSD share units (18 decimals), not underlying reserve-token units.
    /// Reverts unless `badDebt + creditBackedSupply <= totalSupply` after the recognition.
    /// @param amount The bad debt to recognize, in cUSD share units (18 decimals)
    function recognizeBadDebtInReserve(uint256 amount) external;

    /// @notice Recognize unrecoverable borrower debt, socializing the loss across holders
    /// @dev Market only. Also drops credit-backed supply. Recognized backing falls through
    /// {backing} / {totalAssets}; redeemers take a further exit haircut via {convertToAssets}.
    /// `amount` is cUSD share units (18 decimals), not underlying reserve-token units.
    /// @param amount The bad debt to recognize, in cUSD share units (18 decimals)
    function recognizeBadDebtInCredit(uint256 amount) external;

    /// @notice Burn cUSD to retire bad debt and restore the peg
    /// @dev Permissionless. `amount` is cUSD share units (18 decimals).
    /// @param amount The bad debt to cover, in cUSD share units (18 decimals), capped at the shortfall
    /// @return covered The bad debt actually covered, in cUSD share units (18 decimals)
    function coverBadDebt(uint256 amount) external returns (uint256 covered);

    /// @notice Get the current bad debt
    /// @return debt The outstanding bad debt, in cUSD share units (18 decimals)
    function badDebt() external view returns (uint256 debt);

    /// @notice Get the underlying asset decimals
    /// @return The underlying asset decimals
    function underlyingDecimals() external view returns (uint8);

    /// @notice Get the interest rate model address
    /// @return The interest rate model address
    function irm() external view returns (address);

    /// @notice Get the reserve vault that may hold idle reserve
    /// @return vault The reserve vault
    function reserveVault() external view returns (address vault);

    /// @notice Get the credit-backed token supply
    /// @return The credit-backed supply, in cUSD share units (18 decimals)
    function creditBackedSupply() external view returns (uint256);

    /// @notice Get the recognized backing in cUSD share units (18 decimals)
    /// @dev `totalSupply - badDebt`. {convertToAssets} applies a further shortfall
    /// discount when quoting an exit; this figure is not that quote.
    /// @return recognized The outstanding supply still recognized as backed, in cUSD share units (18 decimals)
    function backing() external view returns (uint256 recognized);

    /// @notice Get the recognized backing in underlying units
    /// @dev Scaled {backing}. Integrators read this as managed assets, not as the
    /// discounted value of redeeming the outstanding supply.
    /// @return assets The total recognized assets in underlying units
    function totalAssets() external view returns (uint256 assets);

    /// @notice Preview the shares minted for a deposit at the fixed 1:1 exchange rate
    /// @param assets The asset amount to deposit
    /// @return shares The share amount minted
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview the assets required to mint shares at the fixed 1:1 exchange rate
    /// @param shares The share amount to mint
    /// @return assets The asset amount required
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Get the share token decimals
    /// @dev Always 18
    /// @return The share token decimals
    function decimals() external view returns (uint8);

    /// @notice Get the shares available for redemption, excluding credit-backed and written-off supply
    /// @return unlocked The shares not reserved for outstanding borrows or written off, in cUSD share units (18 decimals)
    function unlockedSupply() external view returns (uint256 unlocked);

    /// @notice Get the utilization rate of credit-backed supply
    /// @return rate The utilization rate in ray decimals
    function utilizationRate() external view returns (uint256 rate);

    /// @notice Get the utilization after a credit-backed mint of `amount`
    /// @dev Both supplies rise by `amount`.
    /// @param amount The credit-backed supply about to be minted, in cUSD share units (18 decimals)
    /// @return rate The projected utilization rate in ray decimals
    function utilizationRateAfterMint(uint256 amount) external view returns (uint256 rate);

    /// @notice Get the credit-backed and total supply, read together
    /// @return credit The credit-backed supply, in cUSD share units (18 decimals)
    /// @return supply The total supply, in cUSD share units (18 decimals)
    function supplies() external view returns (uint256 credit, uint256 supply);
}
