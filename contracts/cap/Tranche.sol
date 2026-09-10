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
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title Tranche
/// @author kexley, Cap Labs
/// @notice ERC4626 tranche vault. Deposits via Vault ERC6909; earns cUSD premium from underwriting.
contract Tranche layout at erc7201("cap.storage.Tranche")
    is
    ITranche,
    AccessManagedUpgradeable,
    PremiumVesting,
    UUPSUpgradeable
{
    /// @inheritdoc ITranche
    address public market;

    /// @inheritdoc ITranche
    address public vault;

    /// @inheritdoc ITranche
    address public oracle;

    /// @inheritdoc ITranche
    bool public killed;

    /// @dev Shares per remaining asset at which the tranche is retired (1% of par)
    uint256 private constant KILL_RATIO = 100;

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
        __PremiumVesting_init(IERC20(_asset), _name, _symbol, hex"", IBaseMarket(_market).stablecoin());
        market = _market;
        vault = _vault;
        oracle = _oracle;
    }

    /// @inheritdoc ITranche
    function slash(uint256 value, address recipient) external returns (uint256 slashedValue) {
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
        // Kill below 1% of par so a fresh deposit cannot mint against a near-zero asset base.
        // Empty stays at par. Latch before the withdrawal so a transfer hook cannot deposit first.
        if (!killed && totalSupply() > (total - assets) * KILL_RATIO) {
            killed = true;
            emit Killed();
        }

        IVault(vault).withdraw(asset(), assets, recipient);
        emit Slashed(recipient, assets, slashedValue);
    }

    /// @inheritdoc ITranche
    function fund(uint256 premium) external restricted {
        _fund(premium);
    }

    /// @inheritdoc ITranche
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626, ITranche) returns (uint256 assets) {
        assets = IVault(vault).balanceOf(address(this), asset());
    }

    /// @inheritdoc IERC4626
    /// @dev Caller must have the depositor role. The receiver is unrestricted.
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
        if (!killed) maxAssets = type(uint256).max;
    }

    /// @inheritdoc ITranche
    function maxMint(address) public view override(ERC4626Upgradeable, IERC4626, ITranche) returns (uint256 maxShares) {
        // gated the same way as maxDeposit; see there
        if (!killed) maxShares = type(uint256).max;
    }

    /// @inheritdoc IERC4626
    /// @dev Empty vault quotes at par via {DeadShares-seedDeposit}.
    function previewDeposit(uint256 assets)
        public
        view
        override(ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        shares = totalSupply() == 0 ? DeadShares.seedDeposit(assets) : super.previewDeposit(assets);
    }

    /// @inheritdoc IERC4626
    /// @dev Inverse of {previewDeposit} while empty.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256 assets) {
        assets = totalSupply() == 0 ? DeadShares.seedMint(shares) : super.previewMint(shares);
    }

    /// @inheritdoc ITranche
    function unlockedSupply() public view override(ERC7540AsyncRedeem, ITranche) returns (uint256 unlocked) {
        // market accounts in USD; convert locked value back to collateral
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

    /// @dev Mint the seed on the first deposit. Already deducted from the quote.
    /// @param caller The account funding the deposit
    /// @param receiver The account receiving the shares
    /// @param assets The number of assets deposited
    /// @param shares The number of shares to mint to the receiver
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (totalSupply() == 0) _mint(DeadShares.HOLDER, DeadShares.SHARES);
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Transfer assets into the vault on deposit
    /// @param from The account funding the deposit
    /// @param assets The number of assets to pull
    function _transferIn(address from, uint256 assets) internal override {
        IVault(vault).transferFrom(from, address(this), asset(), assets);
    }

    /// @dev Transfer assets out of the vault on withdraw
    /// @param to The account receiving the assets
    /// @param assets The number of assets to send
    function _transferOut(address to, uint256 assets) internal override {
        IVault(vault).transfer(to, asset(), assets);
    }

    /// @dev Zero price is invalid. Staleness is already checked by the oracle.
    /// @return price The asset price in USD (18 decimals)
    function getPrice() internal view returns (uint256 price) {
        price = IOracle(oracle).price(asset());
        if (price == 0) revert InvalidPrice();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC7540AsyncRedeem) returns (bool) {
        return interfaceId == type(ITranche).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
