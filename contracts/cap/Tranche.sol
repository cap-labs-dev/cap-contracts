// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IBaseMarket } from "../interfaces/IBaseMarket.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IVault } from "../interfaces/IVault.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Tranche
/// @author kexley, Cap Labs
/// @notice Tranche is an ERC4626 vault that allows users to deposit via Vault ERC6909 tokens and earn cUSD premiums from underwriting.
contract Tranche layout at erc7201("cap.storage.Tranche") is ITranche, AccessManagedUpgradeable, ERC7540AsyncRedeem {
    using EnumerableSet for EnumerableSet.AddressSet;
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

    /// @dev The premium vesting schedule and its per-share distribution accounting
    PremiumVesting.Schedule private _premium;

    /// @dev The whitelist of accounts
    EnumerableSet.AddressSet private _whitelist;

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
    }

    /// @inheritdoc ITranche
    function setWhitelist(address account, bool allowed) external restricted {
        if (allowed) _whitelist.add(account);
        else _whitelist.remove(account);
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
        if (premium > 0) {
            _storedPremiumBalance -= premium;
            IERC20(stablecoin).safeTransfer(recipient, premium);
            emit Claimed(msg.sender, recipient, premium);
        }
    }

    /// @inheritdoc ITranche
    function whitelisted(address account) public view returns (bool allowed) {
        allowed = _whitelist.contains(account);
    }

    /// @inheritdoc ITranche
    function claimable(address user) public view returns (uint256 premium) {
        premium = _premium.claimable(user, balanceOf(user), activeSupply());
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

    /// @inheritdoc ITranche
    function maxDeposit(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626, ITranche)
        returns (uint256 maxAssets)
    {
        if (whitelisted(receiver)) maxAssets = type(uint256).max;
    }

    /// @inheritdoc ITranche
    function maxMint(address receiver)
        public
        view
        override(ERC4626Upgradeable, IERC4626, ITranche)
        returns (uint256 maxShares)
    {
        if (whitelisted(receiver)) maxShares = type(uint256).max;
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
    function getPrice() internal view returns (uint256 price) {
        (price,) = IOracle(oracle).getPrice(asset());
        if (price == 0) revert InvalidPrice();
    }

    /// @dev Accrue vested premium into premium per share. Underwriting exposure is `activeSupply`,
    /// so shares queued for redemption stop earning; see {PremiumVesting-accrue} for what happens
    /// to premium vesting through a window where that reaches zero.
    function _updatePremium() internal {
        _premium.accrue(activeSupply());
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
