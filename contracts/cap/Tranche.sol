// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IBaseMarket } from "../interfaces/IBaseMarket.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IVault } from "../interfaces/IVault.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title Tranche
/// @author kexley, Cap Labs
/// @notice Tranche is an ERC4626 vault that allows users to deposit via Vault ERC6909 tokens and earn cUSD premiums from underwriting.
contract Tranche layout at erc7201("cap.storage.Tranche") is ITranche, AccessManagedUpgradeable, ERC7540AsyncRedeem {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    /// @inheritdoc ITranche
    address public market;

    /// @inheritdoc ITranche
    address public vault;

    /// @inheritdoc ITranche
    address public stablecoin;

    /// @inheritdoc ITranche
    address public oracle;

    /// @inheritdoc ITranche
    uint256 public vestingPeriod;

    /// @inheritdoc ITranche
    uint256 public periodEnd;

    /// @inheritdoc ITranche
    uint256 public premiumPerShare;

    /// @inheritdoc ITranche
    uint256 public lastPremiumUpdate;

    /// @inheritdoc ITranche
    mapping(address => uint256) public pendingPremium;

    /// @dev Premium already credited to an account at its last balance checkpoint
    mapping(address => uint256) private _premiumDebt;

    /// @dev The whitelist of accounts
    EnumerableSet.AddressSet private _whitelist;

    /// @inheritdoc ITranche
    uint256 public vested;

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
        vestingPeriod = 6 hours;
    }

    /// @inheritdoc ITranche
    function slash(uint256 assets, address recipient) external restricted returns (uint256 slashedValue) {
        uint256 slashedAssets = Math.min(assets, totalAssets());
        slashedValue = slashedAssets.rayMul(getPrice());
        IVault(vault).withdraw(asset(), slashedAssets, recipient);
        emit Slashed(recipient, slashedAssets, slashedValue);
    }

    /// @inheritdoc ITranche
    function setWhitelist(address account, bool allowed) external restricted {
        if (allowed) _whitelist.add(account);
        else _whitelist.remove(account);
    }

    /// @inheritdoc ITranche
    function setVestingPeriod(uint256 _vestingPeriod) external restricted {
        vested = _lockedProfit();
        periodEnd = block.timestamp + _vestingPeriod;
        vestingPeriod = _vestingPeriod;
        emit SetVestingPeriod(_vestingPeriod);
    }

    /// @inheritdoc ITranche
    function notifyPremium() external updatePremium restricted {
        uint256 premiumBalance = IERC20(stablecoin).balanceOf(address(this));
        if (premiumBalance > _storedPremiumBalance) {
            vested = _lockedProfit() + (premiumBalance - _storedPremiumBalance);
            _storedPremiumBalance = premiumBalance;
            periodEnd = block.timestamp + vestingPeriod;
            lastPremiumUpdate = block.timestamp;
        }
    }

    /// @inheritdoc ITranche
    function claim(address recipient) external updatePremium returns (uint256 premium) {
        premium = claimable(msg.sender);
        if (premium > 0) {
            pendingPremium[msg.sender] = 0;
            _premiumDebt[msg.sender] = premiumPerShare.rayMul(balanceOf(msg.sender));
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
        premium = pendingPremium[user] + _premiumPerShare().rayMul(balanceOf(user)) - _premiumDebt[user];
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
        uint256 lockedShares = previewWithdraw(IBaseMarket(market).lockedAssets(address(this)));
        uint256 totalSupply = totalSupply();
        if (totalSupply > lockedShares) unlocked = totalSupply - lockedShares;
    }

    /// @inheritdoc ITranche
    function totalCapital() public view returns (uint256 capital) {
        capital = totalAssets().rayDiv(getPrice());
    }

    /// @inheritdoc ITranche
    function activeCapital() public view returns (uint256 capital) {
        capital = activeAssets().rayDiv(getPrice());
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

    /// @dev Get the price of the asset for a market
    function getPrice() internal view returns (uint256 price) {
        (price,) = IOracle(oracle).getPrice(asset());
    }

    /// @dev Accrue vested premium into premium per share
    function _updatePremium() internal {
        if (lastPremiumUpdate == block.timestamp || lastPremiumUpdate == periodEnd) return;
        uint256 supply = activeSupply();
        if (supply == 0) return;
        uint256 unlocked = _unlockedProfit();
        if (unlocked > 0) premiumPerShare += unlocked.rayDiv(supply);
        lastPremiumUpdate = Math.min(block.timestamp, periodEnd);
    }

    /// @dev Get the premium per share including unaccrued vesting
    function _premiumPerShare() internal view returns (uint256 premiumPerShare_) {
        premiumPerShare_ = premiumPerShare;
        if (lastPremiumUpdate != block.timestamp) {
            uint256 supply = activeSupply();
            if (supply > 0) premiumPerShare_ += _unlockedProfit().rayDiv(supply);
        }
    }

    /// @dev Get the premium unlocked since the last update
    function _unlockedProfit() internal view returns (uint256 unlockedProfit) {
        uint256 elapsed = Math.min(periodEnd, block.timestamp) - lastPremiumUpdate;
        unlockedProfit = vested * elapsed / vestingPeriod;
    }

    /// @dev Get the premium still locked in the current vesting epoch
    function _lockedProfit() internal view returns (uint256 lockedProfit) {
        if (block.timestamp > periodEnd) return 0;
        lockedProfit = vested * (periodEnd - block.timestamp) / vestingPeriod;
    }

    /// @dev Settle premium accounting when shares move
    function _update(address from, address to, uint256 amount) internal override updatePremium {
        if (from != address(0) && from != address(this)) {
            uint256 accPremiumPerShare = premiumPerShare;
            uint256 balance = balanceOf(from);
            pendingPremium[from] += accPremiumPerShare.rayMul(balance) - _premiumDebt[from];
            _premiumDebt[from] = accPremiumPerShare.rayMul(balance - amount);
        }
        if (to != address(0) && to != address(this)) {
            uint256 accPremiumPerShare = premiumPerShare;
            uint256 balance = balanceOf(to);
            pendingPremium[to] += accPremiumPerShare.rayMul(balance) - _premiumDebt[to];
            _premiumDebt[to] = accPremiumPerShare.rayMul(balance + amount);
        }
        super._update(from, to, amount);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC7540AsyncRedeem) returns (bool) {
        return interfaceId == type(ITranche).interfaceId || super.supportsInterface(interfaceId);
    }
}
