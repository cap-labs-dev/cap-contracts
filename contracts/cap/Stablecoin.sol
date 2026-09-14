// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { ERC4626Upgradeable, ERC7540AsyncRedeem, IERC4626 } from "../ERC7540/ERC7540AsyncRedeem.sol";
import { IAeraVault } from "../interfaces/IAeraVault.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { PremiumVesting } from "../utils/PremiumVesting.sol";
import { WadRayMath } from "../utils/WadRayMath.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Stablecoin
/// @author kexley, Cap Labs
/// @notice Credit-backed ERC-7540 stablecoin
contract Stablecoin layout at erc7201("cap.storage.Stablecoin")
    is
    IStablecoin,
    AccessManagedUpgradeable,
    PausableUpgradeable,
    PremiumVesting,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    /// @inheritdoc IStablecoin
    uint8 public underlyingDecimals;

    /// @inheritdoc IStablecoin
    address public irm;

    /// @inheritdoc IStablecoin
    uint256 public creditBackedSupply;

    /// @inheritdoc IStablecoin
    uint256 public badDebt;

    /// @inheritdoc IStablecoin
    address public reserveVault;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IStablecoin
    function initialize(
        address _authority,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _irm,
        address _reserveVault
    ) external reinitializer(2) {
        __AccessManaged_init(_authority);
        __Pausable_init();
        __PremiumVesting_init(IERC20Metadata(_asset), _name, _symbol, address(this));
        // both previews scale between the two units, and only the direction that divides can lose
        // anything. Below 18 that is the mint side, which rounds up so the vault keeps the dust;
        // above 18 it would be the deposit side, where rounding up is not available because the
        // assets have already been pulled, and a deposit too small to mint a single share would
        // simply be donated. Refuse the configuration rather than carry a preview that cannot
        // round in the vault's favour
        uint8 assetDecimals = IERC20Metadata(_asset).decimals();
        if (assetDecimals > decimals()) revert UnsupportedDecimals();
        underlyingDecimals = assetDecimals;
        irm = _irm;
        reserveVault = _reserveVault;
    }

    /// @inheritdoc IStablecoin
    function fund(uint256 premium) external {
        uint256 shares = deposit(premium, address(this));
        _fund(shares);
    }

    /// @inheritdoc IStablecoin
    function fundCreditBacked(uint256 premium) external restricted {
        _mintCreditBacked(address(this), premium);
        _fund(premium);
    }

    /// @inheritdoc IStablecoin
    function mintCreditBacked(address _to, uint256 _amount) external restricted {
        _mintCreditBacked(_to, _amount);
    }

    /// @inheritdoc IStablecoin
    function burnCreditBacked(address _from, uint256 _amount) external restricted {
        _burn(_from, _amount);
        creditBackedSupply -= _amount;
        IInterestRateModel(irm).updateLiquidityRate();
        emit BurnCreditBacked(_from, _amount);
    }

    /// @inheritdoc IStablecoin
    function invest(uint256 amount) external restricted {
        IERC20 token = IERC20(asset());
        token.forceApprove(reserveVault, amount);
        IAeraVault.TokenAmount[] memory amounts = new IAeraVault.TokenAmount[](1);
        amounts[0] = IAeraVault.TokenAmount({ token: token, amount: amount });
        IAeraVault(reserveVault).deposit(amounts);
        emit Invested(amount);
    }

    /// @inheritdoc IStablecoin
    function recall(uint256 amount) external restricted {
        IAeraVault.TokenAmount[] memory amounts = new IAeraVault.TokenAmount[](1);
        amounts[0] = IAeraVault.TokenAmount({ token: IERC20(asset()), amount: amount });
        IAeraVault(reserveVault).withdraw(amounts);
        emit Recalled(amount);
    }

    /// @inheritdoc IStablecoin
    function setReserveVault(address newReserveVault) external restricted {
        address previousVault = reserveVault;
        reserveVault = newReserveVault;
        emit SetReserveVault(previousVault, newReserveVault);
    }

    /// @inheritdoc IStablecoin
    function pause() external restricted {
        _pause();
    }

    /// @inheritdoc IStablecoin
    function unpause() external restricted {
        _unpause();
    }

    /// @inheritdoc IStablecoin
    function utilizationRate() public view returns (uint256 rate) {
        rate = _utilizationRate(creditBackedSupply, totalSupply());
    }

    /// @inheritdoc IStablecoin
    function utilizationRateAfterMint(uint256 _amount) public view returns (uint256 rate) {
        rate = _utilizationRate(creditBackedSupply + _amount, totalSupply() + _amount);
    }

    /// @inheritdoc IStablecoin
    function supplies() public view returns (uint256 credit, uint256 supply) {
        credit = creditBackedSupply;
        supply = totalSupply();
    }

    /// @dev Calculates the utilization rate between the credit-backed supply and the total supply.
    /// @param _credit The credit-backed supply
    /// @param _supply The total supply
    /// @return rate The utilization rate in ray decimals
    function _utilizationRate(uint256 _credit, uint256 _supply) internal pure returns (uint256 rate) {
        if (_supply == 0) return 0;
        rate = _credit.rayDiv(_supply);
    }

    /// @inheritdoc IStablecoin
    function recognizeBadDebtInReserve(uint256 _amount) external restricted {
        badDebt += _amount;
        // only reserve-backed shares can absorb a reserve loss. Credit is still owed by
        // borrowers; writing it off here would let a later repay drive {backing} under zero.
        uint256 supply = totalSupply();
        uint256 credit = creditBackedSupply;
        if (credit > supply || badDebt > supply - credit) revert BadDebtExceedsSupply();
        emit BadDebtRecognizedInReserve(_amount);
    }

    /// @inheritdoc IStablecoin
    function recognizeBadDebtInCredit(uint256 _amount) external restricted {
        badDebt += _amount;
        if (badDebt > totalSupply()) revert BadDebtExceedsSupply();
        // will never be repaid, so drop it from credit-backed supply. unlockedSupply is unchanged
        // because badDebt rose by the same amount. Holders take the loss through {backing}.
        creditBackedSupply -= _amount;
        IInterestRateModel(irm).updateLiquidityRate();
        emit BadDebtRecognizedInCredit(_amount);
    }

    /// @inheritdoc IStablecoin
    function coverBadDebt(uint256 _amount) external returns (uint256 covered) {
        uint256 shortfall = badDebt;
        if (shortfall == 0) revert NoBadDebt();
        covered = _amount < shortfall ? _amount : shortfall;

        // supply and shortfall fall together; outstanding supply and the reserve are unchanged
        badDebt = shortfall - covered;
        _burn(msg.sender, covered);

        IInterestRateModel(irm).updateLiquidityRate();
        emit BadDebtCovered(msg.sender, covered);
    }

    /// @inheritdoc IStablecoin
    function unlockedSupply() public view override(ERC7540AsyncRedeem, IStablecoin) returns (uint256 unlocked) {
        // neither credit-backed nor written-off supply may redeem against the reserve
        uint256 locked = creditBackedSupply + badDebt;
        uint256 supply = totalSupply();
        if (supply > locked) unlocked = supply - locked;

        uint256 available = _quoteWithdraw(IERC20(asset()).balanceOf(address(this)));
        if (unlocked > available) unlocked = available;
    }

    /// @dev Premium is paid in this token. Queued redemptions sit in the same balance and
    ///      must not be transferred as yield.
    function _spendablePremium() internal view override returns (uint256 available) {
        uint256 held = balanceOf(address(this));
        uint256 escrow = redemptionQueue();
        available = held > escrow ? held - escrow : 0;
    }

    /// @inheritdoc IStablecoin
    function backing() public view returns (uint256 recognized) {
        recognized = totalSupply() - badDebt;
    }

    /// @inheritdoc IStablecoin
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, IStablecoin) returns (uint256 assets) {
        assets = Math.mulDiv(backing(), 10 ** underlyingDecimals, 10 ** decimals());
    }

    /// @inheritdoc IStablecoin
    /// @dev Always at par, even with bad debt.
    function previewDeposit(uint256 _assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IStablecoin)
        returns (uint256 shares)
    {
        shares = Math.mulDiv(_assets, 10 ** decimals(), 10 ** underlyingDecimals, Math.Rounding.Floor);
    }

    /// @inheritdoc IStablecoin
    /// @dev At par; see {previewDeposit}. Rounded up.
    function previewMint(uint256 _shares)
        public
        view
        override(ERC4626Upgradeable, IERC4626, IStablecoin)
        returns (uint256 assets)
    {
        assets = Math.mulDiv(_shares, 10 ** underlyingDecimals, 10 ** decimals(), Math.Rounding.Ceil);
    }

    /// @inheritdoc IStablecoin
    function decimals() public pure override(ERC4626Upgradeable, IERC20Metadata, IStablecoin) returns (uint8) {
        return 18;
    }

    /// @dev During a shortfall, redemptions price below the backing ratio so exit repairs the peg.
    /// Priced at roughly ({backing} / totalSupply) ^ 2. That is an exit quote, not {totalAssets}.
    /// @param _shares The number of shares to convert to assets
    /// @param _rounding The rounding direction
    /// @return assets The number of assets
    function _convertToAssets(uint256 _shares, Math.Rounding _rounding)
        internal
        view
        override
        returns (uint256 assets)
    {
        uint256 shortfall = badDebt;
        uint256 value;
        if (shortfall == 0) {
            value = _shares;
        } else {
            uint256 supply = totalSupply();
            uint256 recognized = backing();
            if (_shares >= supply) {
                value = recognized;
            } else {
                uint256 remaining = supply - _shares;
                uint256 anchor = supply * recognized;
                // the payout is backing less what is retained, so the retained side is rounded the
                // opposite way to keep the payout itself on the requested side
                uint256 retained = Math.mulDiv(remaining, anchor, anchor + remaining * shortfall, _opposite(_rounding));
                value = recognized > retained ? recognized - retained : 0;
            }
        }
        assets = Math.mulDiv(value, 10 ** underlyingDecimals, 10 ** decimals(), _rounding);
    }

    /// @dev Inverse of {_convertToAssets}.
    /// @param _assets The number of assets to convert to shares
    /// @param _rounding The rounding direction
    /// @return shares The number of shares
    function _convertToShares(uint256 _assets, Math.Rounding _rounding)
        internal
        view
        override
        returns (uint256 shares)
    {
        if (_assets == 0) return 0;
        uint256 value = Math.mulDiv(_assets, 10 ** decimals(), 10 ** underlyingDecimals, _rounding);
        uint256 shortfall = badDebt;
        if (shortfall == 0) return value;

        uint256 supply = totalSupply();
        uint256 recognized = backing();
        // more than the whole reserve can ever pay out, so the entire supply would not cover it
        if (value >= recognized) return supply;

        uint256 retained = recognized - value;
        uint256 anchor = supply * recognized;
        uint256 remaining = Math.mulDiv(retained, anchor, anchor - retained * shortfall, _opposite(_rounding));
        shares = supply > remaining ? supply - remaining : 0;
    }

    /// @dev Flip rounding for subtracted intermediate terms.
    /// @param _rounding The rounding direction to invert
    /// @return flipped The opposite rounding direction
    function _opposite(Math.Rounding _rounding) private pure returns (Math.Rounding flipped) {
        flipped = _rounding == Math.Rounding.Ceil ? Math.Rounding.Floor : Math.Rounding.Ceil;
    }

    /// @dev Freeze supply while paused. Transfers between holders still go through.
    /// @param from The sender, or zero on mint
    /// @param to The recipient, or zero on burn
    /// @param amount The shares moving
    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) _requireNotPaused();
        super._update(from, to, amount);
    }

    /// @dev Override the internal deposit function to update the IRM
    /// @param _caller The address of the caller
    /// @param _receiver The address of the receiver
    /// @param _assets The amount of assets deposited
    /// @param _shares The amount of shares minted
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal override {
        super._deposit(_caller, _receiver, _assets, _shares);
        IInterestRateModel(irm).updateLiquidityRate();
    }

    /// @dev Mint credit-backed stablecoin and update the liquidity rate
    /// @param _to The address to mint the credit-backed stablecoin to
    /// @param _amount The amount of credit-backed stablecoin to mint
    function _mintCreditBacked(address _to, uint256 _amount) internal {
        _mint(_to, _amount);
        creditBackedSupply += _amount;
        IInterestRateModel(irm).updateLiquidityRate();
        emit MintCreditBacked(_to, _amount);
    }

    /// @dev Retire the shortfall this redemption absorbed. Hooked here so queued redemptions count too.
    /// @param _owner The address whose shares were burned
    /// @param _assets The amount of assets withdrawn
    /// @param _shares The amount of shares burned
    function _onWithdraw(address _owner, uint256 _assets, uint256 _shares) internal override {
        if (badDebt > 0) {
            uint256 paidInShares = Math.mulDiv(_assets, 10 ** decimals(), 10 ** underlyingDecimals);
            uint256 reduced = _shares > paidInShares ? _shares - paidInShares : 0;
            if (reduced > badDebt) reduced = badDebt;
            badDebt -= reduced;
            emit BadDebtReduced(_owner, reduced);
        }

        IInterestRateModel(irm).updateLiquidityRate();
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
