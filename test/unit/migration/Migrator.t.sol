// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../contracts/cap/Stablecoin.sol";
import { Wrapper } from "../../../contracts/cap/Wrapper.sol";
import { IPremiumVesting } from "../../../contracts/interfaces/IPremiumVesting.sol";
import { IMigrator } from "../../../contracts/migration/IMigrator.sol";
import { Migrator } from "../../../contracts/migration/Migrator.sol";
import { BaseTest } from "../../shared/BaseTest.sol";
import { MockERC20 } from "../../shared/mocks/MockERC20.sol";
import { MockIRM } from "../../shared/mocks/MockIRM.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC20PermitUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {
    ERC20Upgradeable,
    ERC4626Upgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @dev v1 cUSD as far as the migration sees it: a permit token whose backing sits on the proxy,
/// with the vault and fractional-reserve views the unwind clears
contract CapTokenV1 is ERC20PermitUpgradeable, UUPSUpgradeable {
    mapping(address account => bool allowed) public upgraders;
    address internal asset;
    mapping(address asset => uint256 amount) public totalBorrows;
    mapping(address asset => uint256 amount) public loaned;
    mapping(address asset => uint256 amount) public claimableInterest;

    function initialize(string memory name, string memory symbol, address underlying) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        asset = underlying;
        upgraders[msg.sender] = true;
    }

    function assets() external view returns (address[] memory list) {
        list = new address[](1);
        list[0] = asset;
    }

    function setUnwind(uint256 borrows, uint256 invested, uint256 interest) external {
        totalBorrows[asset] = borrows;
        loaned[asset] = invested;
        claimableInterest[asset] = interest;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function grantUpgrade(address account) external {
        upgraders[account] = true;
    }

    function _authorizeUpgrade(address) internal view override {
        require(upgraders[msg.sender], "not upgrader");
    }
}

/// @dev v1 stcUSD: profit is notified into `storedTotal` and released linearly over `lockDuration`
contract StakedCapV1 is ERC4626Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    mapping(address account => bool allowed) public upgraders;
    uint256 public storedTotal;
    uint256 public lastNotify;
    uint256 public lockDuration;
    uint256 internal lockedAtNotify;

    function initialize(IERC20 asset, string memory name, string memory symbol, uint256 duration) external initializer {
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);
        __ERC4626_init(asset);
        lockDuration = duration;
        upgraders[msg.sender] = true;
    }

    function notify() external {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        if (balance <= storedTotal) return;
        lockedAtNotify = lockedProfit() + balance - storedTotal;
        storedTotal = balance;
        lastNotify = block.timestamp;
    }

    function lockedProfit() public view returns (uint256 locked) {
        uint256 elapsed = block.timestamp - lastNotify;
        if (elapsed < lockDuration) locked = lockedAtNotify * (lockDuration - elapsed) / lockDuration;
    }

    function totalAssets() public view override returns (uint256) {
        return storedTotal - lockedProfit();
    }

    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return ERC4626Upgradeable.decimals();
    }

    function grantUpgrade(address account) external {
        upgraders[account] = true;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        storedTotal += assets;
        super._deposit(caller, receiver, assets, shares);
    }

    function _authorizeUpgrade(address) internal view override {
        require(upgraders[msg.sender], "not upgrader");
    }
}

/// @dev v1 FeeReceiver's `distribute`: push the cUSD to the staked token, then ask it when it last
///      notified, notifying it if the last release is over
contract FeeReceiverV1 {
    IERC20 public capToken;
    address public stakedCapToken;

    constructor(IERC20 cap, address staked) {
        capToken = cap;
        stakedCapToken = staked;
    }

    function setStakedCapToken(address staked) external {
        stakedCapToken = staked;
    }

    function distribute() external {
        uint256 balance = capToken.balanceOf(address(this));
        if (balance > 0) capToken.transfer(stakedCapToken, balance);
        if (StakedCapV1(stakedCapToken).lastNotify() + StakedCapV1(stakedCapToken).lockDuration() < block.timestamp) {
            StakedCapV1(stakedCapToken).notify();
        }
    }
}

/// @notice The migration runs as one transaction against v1 stand-ins and the real v2
///         implementations: it refuses to finish while any runbook step is undone, and once it does
///         finish both tokens carry their state over and the collected fees vest to cUSD holders.
contract MigratorTest is BaseTest {
    bytes32 private constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 private constant LOCK = 1 days;
    uint256 private constant FEES = 10e18;

    MockERC20 internal usdc;
    CapTokenV1 internal cusd;
    StakedCapV1 internal stcusd;
    FeeReceiverV1 internal feeReceiver;
    Migrator internal migrator;

    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_000_000);
        _setUpAccessManager();
        usdc = new MockERC20("USD Coin", "USDC", 6);

        cusd = CapTokenV1(
            _deployProxy(
                address(new CapTokenV1()), abi.encodeCall(CapTokenV1.initialize, ("cap USD", "cUSD", address(usdc)))
            )
        );
        stcusd = StakedCapV1(
            _deployProxy(
                address(new StakedCapV1()),
                abi.encodeCall(StakedCapV1.initialize, (IERC20(address(cusd)), "Staked cap USD", "stcUSD", LOCK))
            )
        );
        feeReceiver = new FeeReceiverV1(IERC20(address(cusd)), address(stcusd));

        // the unwind is complete: every cUSD, the fees included, is backed by USDC on the proxy
        _mintBacked(alice, 1_000e18);
        _mintBacked(address(feeReceiver), FEES);
        vm.startPrank(alice);
        cusd.approve(address(stcusd), type(uint256).max);
        stcusd.deposit(600e18, alice);
        vm.stopPrank();

        migrator = new Migrator(_config());
    }

    function _config() internal returns (IMigrator.Config memory config) {
        config = IMigrator.Config({
            executor: address(this),
            upgrader: address(this),
            stablecoin: address(cusd),
            wrapper: address(stcusd),
            feeReceiver: address(feeReceiver),
            stablecoinImplementation: address(new Stablecoin()),
            wrapperImplementation: address(new Wrapper()),
            authority: address(accessManager),
            underlying: address(usdc),
            irm: address(new MockIRM()),
            reserveVault: address(0),
            vestingPeriod: 12 hours
        });
    }

    function _mintBacked(address to, uint256 amount) internal {
        cusd.mint(to, amount);
        usdc.mint(address(cusd), amount / 1e12);
    }

    /// @dev Runbook steps the operators own: redirect fees here, and let the migrator upgrade
    function _prepare() internal {
        feeReceiver.setStakedCapToken(address(migrator));
        cusd.grantUpgrade(address(migrator));
        stcusd.grantUpgrade(address(migrator));
    }

    function _implementation(address proxy) internal view returns (address impl) {
        impl = address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function test_migrate_upgradesBothTokensAndReturnsTheFees() public {
        _prepare();
        uint256 cusdSupply = cusd.totalSupply();
        uint256 stakedSupply = stcusd.totalSupply();
        uint256 sharePrice = stcusd.convertToAssets(1e18);
        bytes32 cusdDomain = cusd.DOMAIN_SEPARATOR();
        bytes32 stakedDomain = stcusd.DOMAIN_SEPARATOR();

        vm.expectEmit(address(migrator));
        emit IMigrator.FeesReturned(FEES, FEES / 1e12);
        vm.expectEmit(address(migrator));
        emit IMigrator.Migrated();
        migrator.migrate(0);

        assertEq(_implementation(address(cusd)), migrator.stablecoinImplementation());
        assertEq(_implementation(address(stcusd)), migrator.wrapperImplementation());
        Stablecoin scoin = Stablecoin(address(cusd));
        Wrapper wrapper = Wrapper(address(stcusd));
        assertEq(scoin.totalSupply(), cusdSupply, "the fees are redeemed and funded back as shares");
        assertEq(scoin.unlockedSupply(), cusdSupply, "every cUSD exit is open");
        assertEq(wrapper.totalSupply(), stakedSupply);
        assertEq(wrapper.convertToAssets(1e18), sharePrice, "stcUSD share price is continuous");
        assertEq(IERC20Permit(address(cusd)).DOMAIN_SEPARATOR(), cusdDomain);
        assertEq(IERC20Permit(address(stcusd)).DOMAIN_SEPARATOR(), stakedDomain);

        assertEq(scoin.balanceOf(address(migrator)), 0, "nothing left behind");
        assertEq(IPremiumVesting(address(cusd)).remaining(), FEES, "the fees vest to cUSD holders");
        assertTrue(migrator.migrated());

        vm.expectRevert(IMigrator.AlreadyMigrated.selector);
        migrator.migrate(0);
    }

    /// @dev The tokens must not land on v2 without someone able to upgrade them there
    function test_migrate_refusesUntilTheUpgraderCanUpgradeBothTokens() public {
        address upgrader = makeAddr("upgrader");
        IMigrator.Config memory config = _config();
        config.upgrader = upgrader;
        migrator = new Migrator(config);
        _prepare();

        vm.expectRevert(abi.encodeWithSelector(IMigrator.AccessNotConfigured.selector, address(cusd)));
        migrator.migrate(0);

        // an execution delay is still a working upgrade path
        accessManager.grantRole(accessManager.ADMIN_ROLE(), upgrader, 2 days);
        migrator.migrate(0);
    }

    function test_migrate_onlyTheExecutor() public {
        _prepare();
        vm.prank(alice);
        vm.expectRevert(IMigrator.NotExecutor.selector);
        migrator.migrate(0);
    }

    /// @dev v2 caps cUSD exits at the underlying the proxy holds, so an unfinished unwind would
    ///      freeze them. One unbacked wei is enough to refuse.
    /// @dev The v1 functions that recover loans, reserve investments and reserve interest live on
    ///      cUSD and are gone once it is upgraded, so each must be cleared first
    function test_migrate_refusesUntilTheV1UnwindIsComplete() public {
        _prepare();

        cusd.setUnwind(1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IMigrator.LoansOutstanding.selector, address(usdc)));
        migrator.migrate(0);

        cusd.setUnwind(0, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IMigrator.ReserveInvested.selector, address(usdc)));
        migrator.migrate(0);

        cusd.setUnwind(0, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(IMigrator.InterestUnrealized.selector, address(usdc)));
        migrator.migrate(0);

        cusd.setUnwind(0, 0, 0);
        migrator.migrate(0);
    }

    function test_migrate_topsUpTheShortfallWithinTheCap() public {
        _prepare();
        // v1's oracle-priced mints leave the supply ahead of the USDC it holds, here by 391.67
        cusd.mint(alice, 391.67e18);
        uint256 shortfall = 391.67e6;

        vm.expectRevert(abi.encodeWithSelector(IMigrator.TopUpExceedsMax.selector, shortfall, shortfall - 1));
        migrator.migrate(shortfall - 1);

        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(migrator), 1_000e6);
        uint256 held = usdc.balanceOf(address(cusd));
        vm.expectEmit(address(migrator));
        emit IMigrator.ToppedUp(shortfall);
        migrator.migrate(1_000e6);

        assertEq(usdc.balanceOf(address(this)), 1_000e6 - shortfall, "only the shortfall is pulled");
        assertEq(usdc.balanceOf(address(cusd)), held + shortfall);
        assertEq(Stablecoin(address(cusd)).unlockedSupply(), cusd.totalSupply(), "every cUSD exit is open");
    }

    /// @dev A part-unit shortfall rounds up, so the last wei of cUSD is backed too
    function test_migrate_topUpRoundsUp() public {
        _prepare();
        cusd.mint(alice, 1);
        usdc.mint(address(this), 1);
        usdc.approve(address(migrator), 1);

        vm.expectEmit(address(migrator));
        emit IMigrator.ToppedUp(1);
        migrator.migrate(1);
        assertEq(Stablecoin(address(cusd)).unlockedSupply(), cusd.totalSupply());
    }

    /// @dev v2 values stcUSD at its whole cUSD balance, so v1 profit still locked, or not yet
    ///      notified, would enter the share price at once
    function test_migrate_refusesUntilStakedProfitIsReleased() public {
        _prepare();
        vm.prank(alice);
        assertTrue(cusd.transfer(address(stcusd), 50e18));

        vm.expectRevert(IMigrator.StakedPriceWouldJump.selector);
        migrator.migrate(0);

        stcusd.notify();
        vm.warp(block.timestamp + LOCK / 2);
        assertGt(stcusd.lockedProfit(), 0);
        vm.expectRevert(IMigrator.StakedPriceWouldJump.selector);
        migrator.migrate(0);

        vm.warp(block.timestamp + LOCK);
        migrator.migrate(0);
    }

    /// @dev Fees still pointed at stcUSD would land in its price; pointed at a plain wallet,
    ///      `distribute` cannot ask it about notifying and reverts. Either way the migration refuses.
    function test_migrate_refusesUntilFeesAreRedirectedHere() public {
        cusd.grantUpgrade(address(migrator));
        stcusd.grantUpgrade(address(migrator));

        vm.expectRevert(IMigrator.StakedPriceWouldJump.selector);
        migrator.migrate(0);

        feeReceiver.setStakedCapToken(makeAddr("holding wallet"));
        vm.expectRevert();
        migrator.migrate(0);

        feeReceiver.setStakedCapToken(address(migrator));
        migrator.migrate(0);
    }

    /// @dev Fees are returned in whole units of the underlying, so the cUSD supply does not move;
    ///      the sub-unit dust waits for a later call
    function test_migrate_returnsFeesWithoutMovingTheSupply() public {
        _prepare();
        // a fee balance that is not a whole number of USDC units, still backed in full
        _mintBacked(address(feeReceiver), 1e12 - 1);
        usdc.mint(address(cusd), 1);
        uint256 supply = cusd.totalSupply();

        migrator.migrate(0);
        assertEq(cusd.totalSupply(), supply, "burned and minted the same shares");
        assertEq(cusd.balanceOf(address(migrator)), 1e12 - 1, "dust below one USDC unit waits");
        assertEq(IPremiumVesting(address(cusd)).remaining(), FEES);
    }

    /// @dev Fees reaching the receiver after the migration still make it to cUSD holders
    function test_returnFees_fundsLaterFeesOnceMigrated() public {
        _prepare();
        vm.expectRevert(IMigrator.NotMigrated.selector);
        migrator.returnFees();

        migrator.migrate(0);
        uint256 remaining = IPremiumVesting(address(cusd)).remaining();
        // later fees arrive the way they did before: backed cUSD sent to the receiver
        usdc.mint(alice, 5e6);
        vm.startPrank(alice);
        usdc.approve(address(cusd), 5e6);
        Stablecoin(address(cusd)).deposit(5e6, address(feeReceiver));
        vm.stopPrank();

        vm.prank(alice);
        migrator.returnFees();
        assertEq(IPremiumVesting(address(cusd)).remaining(), remaining + 5e18);
    }
}
