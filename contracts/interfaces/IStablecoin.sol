// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @title IStablecoin
/// @author kexley, Cap Labs
/// @notice Interface for Stablecoin vault accounting
interface IStablecoin {
    /// @notice Emitted when credit-backed tokens are minted
    /// @param to The recipient
    /// @param amount The amount minted
    event MintCreditBacked(address indexed to, uint256 amount);

    /// @notice Emitted when credit-backed tokens are burned
    /// @param from The account burned from
    /// @param amount The amount burned
    event BurnCreditBacked(address indexed from, uint256 amount);

    /// @notice Emitted when a reserve loss is recognized
    /// @param amount The amount of bad debt recognized
    event BadDebtRecognizedInReserve(uint256 amount);

    /// @notice Emitted when a credit loss is recognized
    /// @param amount The amount of bad debt recognized
    event BadDebtRecognizedInCredit(uint256 amount);

    /// @notice Emitted when bad debt is reduced
    /// @param owner The account whose redemption reduced bad debt
    /// @param amount The amount of bad debt reduced
    event BadDebtReduced(address indexed owner, uint256 amount);

    /// @notice Emitted when bad debt is covered outright
    /// @param payer The account that burned cUSD to retire the shortfall
    /// @param amount The amount of bad debt covered
    event BadDebtCovered(address indexed payer, uint256 amount);

    /// @notice Emitted when reserve is sent to reserve vault
    /// @param amount The underlying amount sent
    event Invested(uint256 amount);

    /// @notice Emitted when reserve is recalled from reserve vault
    /// @param amount The underlying amount recalled
    event Recalled(uint256 amount);

    /// @notice Emitted when the reserve vault is updated
    /// @param previousVault The previous reserve vault
    /// @param newVault The new reserve vault, or the zero address when investing is disabled
    event SetReserveVault(address indexed previousVault, address indexed newVault);

    /// @notice There is no bad debt left to cover
    error NoBadDebt();

    /// @notice The underlying has more decimals than the share
    error UnsupportedDecimals();

    /// @notice The amount is zero
    error InvalidAmount();

    /// @notice Bad debt cannot exceed the outstanding supply
    error BadDebtExceedsSupply();

    /// @notice Initialize the stablecoin
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
    /// @param amount The amount to mint
    function mintCreditBacked(address to, uint256 amount) external;

    /// @notice Burn credit-backed tokens on repay or liquidation
    /// @param from The account to burn from
    /// @param amount The amount to burn
    function burnCreditBacked(address from, uint256 amount) external;

    /// @notice Deposit underlying and vest the minted cUSD as yield
    /// @dev Permissionless
    /// @param premium The underlying amount to deposit
    function fund(uint256 premium) external;

    /// @notice Mint credit-backed cUSD to this contract and vest it as premium
    /// @param premium The cUSD amount to mint and vest
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

    /// @notice Recognize a loss in the reserve vault, socializing it across holders
    /// @dev Guardian only. Credit-backed supply is unchanged because no borrower debt was lost.
    /// @param amount The amount of bad debt to recognize
    function recognizeBadDebtInReserve(uint256 amount) external;

    /// @notice Recognize unrecoverable borrower debt, socializing the loss across holders
    /// @dev Market only. Also drops credit-backed supply. Recognized backing falls through
    /// {backing} / {totalAssets}; redeemers take a further exit haircut via {convertToAssets}.
    /// @param amount The amount of bad debt to recognize
    function recognizeBadDebtInCredit(uint256 amount) external;

    /// @notice Burn cUSD to retire bad debt and restore the peg
    /// @dev Permissionless
    /// @param amount The amount of bad debt to cover, capped at the outstanding shortfall
    /// @return covered The amount of bad debt actually covered
    function coverBadDebt(uint256 amount) external returns (uint256 covered);

    /// @notice Get the current bad debt
    /// @return debt The outstanding bad debt
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
    /// @return The credit-backed supply
    function creditBackedSupply() external view returns (uint256);

    /// @notice Recognized backing in share units
    /// @dev `totalSupply - badDebt`. {convertToAssets} applies a further shortfall
    /// discount when quoting an exit; this figure is not that quote.
    /// @return recognized The outstanding supply still recognized as backed
    function backing() external view returns (uint256 recognized);

    /// @notice Recognized backing in underlying units
    /// @dev Scaled {backing}. Integrators read this as managed assets, not as the
    /// discounted value of redeeming the outstanding supply.
    /// @return assets Total recognized assets in underlying units
    function totalAssets() external view returns (uint256 assets);

    /// @notice Preview the shares minted for a deposit at the fixed 1:1 exchange rate
    /// @param assets The asset amount to deposit
    /// @return shares The share amount minted
    function previewDeposit(uint256 assets) external view returns (uint256 shares);

    /// @notice Preview the assets required to mint shares at the fixed 1:1 exchange rate
    /// @param shares The share amount to mint
    /// @return assets The asset amount required
    function previewMint(uint256 shares) external view returns (uint256 assets);

    /// @notice Share token decimals
    /// @dev Always 18
    /// @return The share token decimals
    function decimals() external view returns (uint8);

    /// @notice Shares available for redemption, excluding credit-backed and written-off supply
    /// @return unlocked Shares not reserved for outstanding borrows or written off
    function unlockedSupply() external view returns (uint256 unlocked);

    /// @notice Get the utilization rate of credit-backed supply
    /// @return rate The utilization rate in ray decimals
    function utilizationRate() external view returns (uint256 rate);

    /// @notice Utilization after a credit-backed mint of `amount`
    /// @dev Both supplies rise by `amount`.
    /// @param amount The credit-backed supply about to be minted
    /// @return rate The projected utilization rate in ray decimals
    function utilizationRateAfterMint(uint256 amount) external view returns (uint256 rate);

    /// @notice Credit-backed and total supply, read together
    /// @return credit The credit-backed supply
    /// @return supply The total supply
    function supplies() external view returns (uint256 credit, uint256 supply);
}
