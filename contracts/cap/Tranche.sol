// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IBaseMarket } from "../interfaces/IBaseMarket.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IVault } from "../interfaces/IVault.sol";
import { DeadShares } from "../utils/DeadShares.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Tranche
/// @author kexley, Cap Labs
/// @notice Tranche is an ERC4626 vault that allows users to deposit via Vault ERC6909 tokens and earn cUSD premiums from underwriting.
contract Tranche layout at erc7201("cap.storage.Tranche") is ITranche, AccessManagedUpgradeable, ERC7540AsyncRedeem {
    using PremiumVesting for PremiumVesting.Schedule;
    using SafeERC20 for IERC20;

    /// @inheritdoc ITranche
    address public market;

    /// @inheritdoc ITranche
    address public vault;

    /// @inheritdoc ITranche
    address public stablecoin;

    /// @inheritdoc ITranche
    address public oracle;

    /// @inheritdoc ITranche
    bool public killed;

    /// @dev Shares per asset at which the tranche is retired. Par is one share per asset, so a
    /// hundred shares failing to claim a single asset is one percent of par.
    uint256 private constant KILL_RATIO = 100;

    /// @dev The premium vesting schedule and its per-share distribution accounting
    PremiumVesting.Schedule private _premium;

    /// @notice Stored premium balance used for accrual accounting
    uint256 private _storedPremiumBalance;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc ITranche
    function initialize(
        address _authority,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _market,
        address _vault,
        address _oracle
    ) external initializer {
        __AccessManaged_init(_authority);
        __ERC7540AsyncRedeem_init(IERC20(_asset), _name, _symbol, hex"");
        market = _market;
        vault = _vault;
        stablecoin = IBaseMarket(_market).stablecoin();
        oracle = _oracle;
        _premium.open(6 hours);
    }

    /// @inheritdoc ITranche
    function slash(uint256 value, address recipient) external restricted returns (uint256 slashedValue) {
        // `restricted` establishes only that the caller holds the market role, which every market
        // the Registry deploys does, so on its own the predicate reads as "is a market" rather
        // than "is my market" while the recipient stays caller-supplied. What actually keeps one
        // market off another's collateral today is {BaseMarket-_setTranches} refusing a tranche it
        // does not own, an invariant enforced two contracts away and shared by every tranche
        // through one beacon. Assert it where it is relied on
        if (msg.sender != market) revert InvalidMarket();
        uint256 price = getPrice();
        uint256 unit = 10 ** decimals();
        uint256 assets = value * unit / price;
        uint256 total = totalAssets();
        if (assets > total) {
            assets = total;
            slashedValue = total * price / unit;
        } else {
            slashedValue = value;
        }
        IVault(vault).withdraw(asset(), assets, recipient);
        emit Slashed(recipient, assets, slashedValue);

        // A slash this deep leaves the share price so far below par that the conversion is
        // degenerate: the survivors hold almost nothing, and a fresh deposit would mint shares
        // against a near-zero asset base, where rounding decides who owns what. Latch the tranche
        // shut instead so it can be retired and replaced rather than repaired in place.
        //
        // An empty tranche sits at par by this test rather than below it, so an idle slash cannot
        // brick a tranche before anyone has deposited. The latch is one-way on purpose: a tranche
        // that has been through this must not silently reopen on a later recovery.
        if (!killed && totalSupply() > totalAssets() * KILL_RATIO) {
            killed = true;
            emit Killed();
        }
    }

    /// @inheritdoc ITranche
    function setVestingPeriod(uint256 _vestingPeriod) external restricted updatePremium {
        if (_vestingPeriod == 0) revert InvalidVestingPeriod();
        _premium.setPeriod(_vestingPeriod);
        emit SetVestingPeriod(_vestingPeriod);
    }

    /// @inheritdoc ITranche
    function notifyPremium() external updatePremium restricted {
        uint256 premiumBalance = IERC20(stablecoin).balanceOf(address(this));
        if (premiumBalance > _storedPremiumBalance) {
            _premium.fund(premiumBalance - _storedPremiumBalance);
            _storedPremiumBalance = premiumBalance;
        }
    }

    /// @inheritdoc ITranche
    function claim(address recipient) external updatePremium returns (uint256 premium) {
        premium = _premium.settle(msg.sender, balanceOf(msg.sender));
        // the per-share arithmetic rounds half up in both directions, so the entitlements can sum
        // a few wei past what was funded. Without a clamp the last holder out hits the underflow
        // and cannot collect at all, which trades a rounding error for a stuck claim. Pay what is
        // there: the gap is dust by construction, and whoever meets it is the one who waited
        uint256 held = _storedPremiumBalance;
        if (premium > held) premium = held;
        if (premium > 0) {
            _storedPremiumBalance = held - premium;
            IERC20(stablecoin).safeTransfer(recipient, premium);
            emit Claimed(msg.sender, recipient, premium);
        }
    }

    /// @inheritdoc ITranche
    function claimable(address user) public view returns (uint256 premium) {
        // shares parked at the burn address are out of `stakedSupply`, so premium is divided as if
        // they were not there. Reporting an entitlement against them anyway would make the
        // entitlements sum past the premium actually held, by a few wei that no caller could ever
        // collect, so the two views are kept consistent instead.
        if (user == DeadShares.HOLDER) return 0;
        premium = _premium.claimable(user, balanceOf(user), stakedSupply());
    }

    /// @inheritdoc ITranche
    function vestingPeriod() external view returns (uint256 period) {
        period = _premium.period;
    }

    /// @inheritdoc ITranche
    function periodEnd() external view returns (uint256 timestamp) {
        timestamp = _premium.end();
    }

    /// @inheritdoc ITranche
    function vested() external view returns (uint256 premium) {
        premium = _premium.vested;
    }

    /// @inheritdoc ITranche
    function premiumPerShare() external view returns (uint256 perShare) {
        perShare = _premium.perShare;
    }

    /// @inheritdoc ITranche
    function lastPremiumUpdate() external view returns (uint256 timestamp) {
        timestamp = _premium.lastUpdate;
    }

    /// @inheritdoc ITranche
    function pendingPremium(address user) external view returns (uint256 premium) {
        premium = _premium.pending[user];
    }

    /// @inheritdoc ITranche
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, ITranche) returns (uint256 assets) {
        assets = IVault(vault).balanceOf(address(this), asset());
    }

    /// @inheritdoc IERC4626
    /// @dev The caller must hold whichever role the AccessManager has assigned to this selector on
    /// this tranche. Membership of that role is the allowlist, and no second copy of it is stored
    /// here, so admitting a depositor means granting them the role. The market owner can do that,
    /// because the Registry made their operator role its admin. Letting an underwriter allocate
    /// here is the same grant, since {IUnderwriter-allocate} deposits as itself.
    ///
    /// Pointing the selector at a different role, including the public role to open the tranche to
    /// everyone, is a {IAccessManager-setTargetFunctionRole} call, which AccessManager reserves to
    /// ADMIN.
    ///
    /// This modifier and the kill are the whole gate; the receiver is unrestricted. Gating the
    /// receiver as well would contradict this one, because a member granted the role under an
    /// execution delay clears it by consuming a scheduled operation while still reading as
    /// unauthorized through {IAccessManager-canCall}'s immediate flag. It would also be a gate on
    /// the wrong subject, and one worth little, since shares are transferable as soon as they are
    /// minted.
    function deposit(uint256 _assets, address _receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        restricted
        returns (uint256 shares)
    {
        shares = super.deposit(_assets, _receiver);
    }

    /// @inheritdoc IERC4626
    /// @dev Gated the same way as {deposit}; see there for how the allowlist works
    function mint(uint256 _shares, address _receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        restricted
        returns (uint256 assets)
    {
        assets = super.mint(_shares, _receiver);
    }

    /// @inheritdoc ITranche
    function maxDeposit(address)
        public
        view
        override(ERC4626Upgradeable, IERC4626, ITranche)
        returns (uint256 maxAssets)
    {
        // admission is a gate on whoever calls {deposit}, not on the receiver, so the kill is the
        // only thing left for this to report. ERC4626 checks it before minting, which is what
        // makes a killed tranche refuse deposits rather than merely discourage them
        if (!killed) maxAssets = type(uint256).max;
    }

    /// @inheritdoc ITranche
    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626, ITranche) returns (uint256 maxShares) {
        // gated the same way as maxDeposit; see there
        if (!killed) maxShares = type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @dev While the tranche is empty this quotes at par out of {DeadShares-seedDeposit} rather
    /// than off the ratio, so assets already sitting here cannot price the first deposit, and the
    /// seed is deducted from what the depositor receives. See {DeadShares} for why.
    function previewDeposit(uint256 assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        shares = totalSupply() == 0 ? DeadShares.seedDeposit(assets) : super.previewDeposit(assets);
    }

    /// @inheritdoc IERC4626
    /// @dev The inverse of {previewDeposit} while empty: the first depositor pays for the seed on
    /// top of the shares they asked for
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        assets = totalSupply() == 0 ? DeadShares.seedMint(shares) : super.previewMint(shares);
    }

    /// @inheritdoc ITranche
    function stakedSupply() public view returns (uint256 supply) {
        uint256 active = activeSupply();
        uint256 dead = balanceOf(DeadShares.HOLDER);
        supply = active > dead ? active - dead : 0;
    }

    /// @inheritdoc ITranche
    function unlockedSupply() public view override(ERC7540AsyncRedeem, ITranche) returns (uint256 unlocked) {
        // the market accounts in USD, so the locked value has to be priced back into collateral
        // before it can be compared against this tranche's holdings
        uint256 lockedAssets = IBaseMarket(market).lockedValue(address(this)) * 10 ** decimals() / getPrice();
        uint256 lockedShares = previewWithdraw(lockedAssets);
        uint256 totalSupply = totalSupply();
        if (totalSupply > lockedShares) unlocked = totalSupply - lockedShares;
    }

    /// @inheritdoc ITranche
    function totalCapital() public view returns (uint256 capital) {
        capital = totalAssets() * getPrice() / 10 ** decimals();
    }

    /// @inheritdoc ITranche
    function activeCapital() public view returns (uint256 capital) {
        capital = activeAssets() * getPrice() / 10 ** decimals();
    }

    /// @dev Mint the seed alongside the first deposit. {previewDeposit} and {previewMint} have
    /// already taken it out of that depositor's quote, so the assets arriving cover both.
    /// @param caller The account funding the deposit
    /// @param receiver The account receiving the shares
    /// @param assets The number of assets deposited
    /// @param shares The number of shares to mint to the receiver
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (totalSupply() == 0) _mint(DeadShares.HOLDER, DeadShares.SHARES);
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Transfer assets into the vault on deposit
    function _transferIn(address from, uint256 assets) internal override {
        IVault(vault).transferFrom(from, address(this), asset(), assets);
    }

    /// @dev Transfer assets out of the vault on withdraw
    function _transferOut(address to, uint256 assets) internal override {
        IVault(vault).transfer(to, asset(), assets);
    }

    /// @dev Accrue premium before the wrapped call
    modifier updatePremium() {
        _updatePremium();
        _;
    }

    /// @dev Get the price of the asset for a market. Every conversion between assets and value
    /// divides by this, so a zero price fails closed here rather than panicking downstream.
    ///
    /// Age is not checked here. {Oracle-price} measures each reading against that asset's own
    /// window and falls to the backup before giving up, so a stale feed arrives as a revert rather
    /// than as a number with an old timestamp on it. That matters enough to say why it is not
    /// re-checked: a frozen feed is worth more to a borrower than a missing one, since this figure
    /// drives {totalCapital}, {IBaseMarket-lockedValue}, {IBaseMarket-healthiness} and the slash
    /// conversion, and a stuck price keeps a market borrowing and out of reach of liquidation on
    /// collateral that has already fallen. Duplicating the check here would mean reading the
    /// source data back out for its window, and would still be the oracle's answer either way.
    function getPrice() internal view returns (uint256 price) {
        (price,) = IOracle(oracle).price(asset());
        if (price == 0) revert InvalidPrice();
    }

    /// @dev Accrue vested premium into premium per share. Underwriting exposure is
    /// `stakedSupply`, so shares queued for redemption stop earning and the dead shares never do;
    /// see {PremiumVesting-accrue} for what happens to premium vesting through a window where that
    /// reaches zero.
    function _updatePremium() internal {
        _premium.accrue(stakedSupply());
    }

    /// @dev Settle premium accounting when shares move
    function _update(address from, address to, uint256 amount) internal override updatePremium {
        if (from != address(0) && from != address(this)) {
            uint256 balance = balanceOf(from);
            _premium.checkpoint(from, balance, balance - amount);
        }
        if (to != address(0) && to != address(this)) {
            uint256 balance = balanceOf(to);
            _premium.checkpoint(to, balance, balance + amount);
        }
        super._update(from, to, amount);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC7540AsyncRedeem) returns (bool) {
        return interfaceId == type(ITranche).interfaceId || super.supportsInterface(interfaceId);
    }
}
