// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseTest } from "./BaseTest.sol";
import { CapRoles } from "./CapRoles.sol";
import { MockAggregator } from "./mocks/MockChainlinkFeeds.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

import { BeaconFactory } from "../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { Vault } from "../../contracts/cap/Vault.sol";
import { Wrapper } from "../../contracts/cap/Wrapper.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { ChainlinkAdapter } from "../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../contracts/cap/oracle/Oracle.sol";
import { IBaseMarket } from "../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IOracle } from "../../contracts/interfaces/IOracle.sol";
import { IRegistry } from "../../contracts/interfaces/IRegistry.sol";
import { ITranche } from "../../contracts/interfaces/ITranche.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CapDeployer
/// @notice Deploys and wires a full Cap protocol stack for unit and integration tests.
/// @dev Override `capConfig` fields before `_deployCap()` to tune defaults per test suite.
abstract contract CapDeployer is BaseTest {
    /// @dev Mirrors {DeadShares-SHARES}, which {Tranche} and {Underwriter} carve out of their first
    /// deposit. They are never redeemed, so a first depositor's round trip is permanently short by
    /// this much per vault it passes through, and tests asserting an exact round trip net it out.
    uint256 internal constant DEAD_SHARES = 1e3;

    /// @dev Decimals the harness gives every mock feed, which is what a real Chainlink USD feed
    /// reports. Deliberately not {IOracle-DECIMALS}: the gap between the two is the adapter's
    /// normalisation, and the suite is only worth running against the real stack if it crosses it.
    uint8 internal constant FEED_DECIMALS = 8;

    /// @dev Staleness window every asset gets unless a test narrows it with {_setStaleness}. Long,
    /// because the suite warps months ahead for vesting and interest accrual without re-posting a
    /// price, and a realistic window would turn all of that into an oracle failure. Cannot be zero
    /// or unlimited: a zero window only accepts an answer stamped in this block.
    uint256 internal constant FEED_STALENESS = 3650 days;

    // ── protocol instances ────────────────────────────────────────────────────
    Oracle internal oracle;
    address internal chainlinkAdapter;
    MockERC20 internal cusdUnderlying;
    MockERC20 internal collateral;

    /// @dev The feed standing behind each asset, so {_setPrice} can move a price by writing to the
    /// aggregator the way a real one moves rather than by overwriting the oracle's answer
    mapping(address asset => MockAggregator feed) internal feeds;

    Vault internal vault;
    Wrapper internal wrapper;
    Stablecoin internal stablecoin;
    InterestRateModel internal irm;
    Registry internal registry;

    BeaconFactory internal beaconFactory;
    address internal floatingMarketBeacon;
    address internal fixedMarketBeacon;
    address internal trancheBeacon;
    address internal underwriterBeacon;

    /// @dev Default market owner, borrower, and liquidator; roles assigned during deploy.
    address internal defaultMarketOwner;
    address internal defaultBorrower;
    address internal defaultLiquidator;
    uint256 private _underwriterDeploymentCount;
    mapping(address account => uint64 roleId) private _operatorRole;

    // ── tunable deployment config (mutate before _deployCap) ─────────────────
    CapConfig internal capConfig;

    struct CapConfig {
        uint256 collateralPrice;
        uint256 defaultLtv;
        uint256 defaultBuffer;
        uint256 defaultLt;
        uint256 defaultMultiplier;
        uint256 defaultTargetHealth;
        uint256 defaultLiquidationBonus;
        uint256 defaultAveragingPeriod;
        uint256 defaultMinimumMarketMultiplier;
        uint256 defaultMaximumMarketMultiplier;
        uint256 defaultMaximumUnderwriterRate;
        uint256 defaultUnderwriterRate;
        uint256[] defaultTrancheWeights;
        uint256 defaultMaxCapital;
        uint256 defaultMaximumTermLimit;
        uint256 defaultMinimumTermLimit;
        uint256 defaultGrace;
        IInterestRateModel.Slopes liquiditySlopes;
        bool applyLiquiditySlopes;
    }

    /// @dev Result bundle returned by market creation helpers.
    struct MarketBundle {
        FloatingMarket market;
        Tranche tranche0;
        Tranche tranche1;
        address marketAddr;
        address tranche0Addr;
        address tranche1Addr;
    }

    function _defaultCapConfig() internal pure returns (CapConfig memory cfg) {
        cfg.collateralPrice = 1e18;
        cfg.defaultLtv = 0.5e27;
        cfg.defaultBuffer = 0.1e27;
        cfg.defaultLt = 0.8e27;
        cfg.defaultMultiplier = 1e27;
        cfg.defaultTargetHealth = 1.25e27;
        cfg.defaultLiquidationBonus = 0.02e27;
        cfg.defaultAveragingPeriod = 1 hours;
        cfg.defaultMinimumMarketMultiplier = 1e27;
        cfg.defaultMaximumMarketMultiplier = 2e27;
        cfg.defaultMaximumUnderwriterRate = 1e27;
        cfg.defaultUnderwriterRate = 0.2e27; // 20% APR in ray per year
        cfg.defaultTrancheWeights = new uint256[](2);
        cfg.defaultTrancheWeights[0] = 1e27 - 0.05e27;
        cfg.defaultTrancheWeights[1] = 0.05e27;
        cfg.defaultMaxCapital = 1_000e18;
        cfg.defaultMaximumTermLimit = 30 days;
        cfg.defaultMinimumTermLimit = 1 days;
        cfg.defaultGrace = 1 days;
        cfg.liquiditySlopes =
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 });
        cfg.applyLiquiditySlopes = false;
    }

    // ── deployment ────────────────────────────────────────────────────────────

    function _deployCap() internal {
        capConfig = _defaultCapConfig();
        _deployCapWithConfig(capConfig);
    }

    function _deployCapWithConfig(CapConfig memory cfg) internal {
        capConfig = cfg;
        defaultMarketOwner = address(this);
        defaultBorrower = makeAddr("borrower");
        defaultLiquidator = makeAddr("liquidator");

        _setUpAccessManager();
        _deployCoreContracts();
        _deployRegistry();
        _configureAccess();
        _assignOperator(defaultMarketOwner);
        _assignOperator(defaultBorrower);

        _setPrice(address(collateral), capConfig.collateralPrice);
    }

    function _deployCoreContracts() internal {
        address authority = address(accessManager);

        // The production oracle rather than a mock of it. A mock is free to answer in whatever
        // scale the tests were written in, so it cannot catch the oracle and its consumers
        // disagreeing about that scale, which is the one thing composing prices puts at risk
        oracle = Oracle(_deployProxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (authority))));
        bytes memory adapterCode = type(ChainlinkAdapter).creationCode;
        address adapter;
        assembly {
            adapter := create(0, add(adapterCode, 0x20), mload(adapterCode))
        }
        chainlinkAdapter = adapter;
        cusdUnderlying = new MockERC20("USD Coin", "USDC", 18);
        collateral = new MockERC20("Wrapped Ether", "WETH", 18);

        vault = Vault(_deployProxy(address(new Vault()), abi.encodeCall(Vault.initialize, (authority))));

        InterestRateModel irmImpl = new InterestRateModel();
        Stablecoin stablecoinImpl = new Stablecoin();

        uint256 n = vm.getNonce(address(this));
        address irmAddr = vm.computeCreateAddress(address(this), n);
        address stablecoinAddr = vm.computeCreateAddress(address(this), n + 1);

        irm = InterestRateModel(
            _deployProxy(
                address(irmImpl),
                abi.encodeCall(
                    InterestRateModel.initialize,
                    (
                        authority,
                        stablecoinAddr,
                        capConfig.defaultMinimumMarketMultiplier,
                        capConfig.defaultMaximumMarketMultiplier,
                        capConfig.defaultMaximumUnderwriterRate,
                        capConfig.defaultLiquidationBonus,
                        capConfig.defaultAveragingPeriod
                    )
                )
            )
        );
        stablecoin = Stablecoin(
            _deployProxy(
                address(stablecoinImpl),
                abi.encodeCall(
                    Stablecoin.initialize,
                    (authority, address(cusdUnderlying), "Cap USD", "cUSD", irmAddr, address(0), 12 hours)
                )
            )
        );

        require(address(irm) == irmAddr, "irm addr");
        require(address(stablecoin) == stablecoinAddr, "stablecoin addr");

        wrapper = Wrapper(
            _deployProxy(address(new Wrapper()), abi.encodeCall(Wrapper.initialize, (authority, address(stablecoin))))
        );

        FloatingMarket marketImpl = new FloatingMarket();
        FixedMarket fixedMarketImpl = new FixedMarket();
        Tranche trancheImpl = new Tranche();
        Underwriter underwriterImpl = new Underwriter();

        beaconFactory = BeaconFactory(
            _deployProxy(
                address(new BeaconFactory()), abi.encodeCall(BeaconFactory.initialize, (address(accessManager)))
            )
        );
        floatingMarketBeacon = address(new UpgradeableBeacon(address(marketImpl), address(accessManager)));
        fixedMarketBeacon = address(new UpgradeableBeacon(address(fixedMarketImpl), address(accessManager)));
        trancheBeacon = address(new UpgradeableBeacon(address(trancheImpl), address(accessManager)));
        underwriterBeacon = address(new UpgradeableBeacon(address(underwriterImpl), address(accessManager)));
    }

    function _deployRegistry() internal {
        Registry impl = new Registry();
        address registryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        accessManager.grantRole(CapRoles.ADMIN, registryAddr, 0);
        accessManager.grantRole(CapRoles.REGISTRY, registryAddr, 0);

        registry = Registry(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Registry.initialize,
                    (
                        address(accessManager),
                        IRegistry.InitParams({
                            stablecoin: address(stablecoin),
                            vault: address(vault),
                            oracle: address(oracle),
                            irm: address(irm),
                            factory: address(beaconFactory),
                            floatingMarketBeacon: floatingMarketBeacon,
                            fixedMarketBeacon: fixedMarketBeacon,
                            trancheBeacon: trancheBeacon,
                            underwriterBeacon: underwriterBeacon,
                            wrapper: address(wrapper),
                            lt: capConfig.defaultLt,
                            buffer: capConfig.defaultBuffer,
                            targetHealth: capConfig.defaultTargetHealth
                        })
                    )
                )
            )
        );
        require(address(registry) == registryAddr, "registry addr");
    }

    function _configureAccess() internal {
        accessManager.grantRole(CapRoles.GOVERNOR, address(this), 0);
        accessManager.grantRole(CapRoles.KEEPER, address(this), 0);
        accessManager.grantRole(CapRoles.GUARDIAN, address(this), 0);
        accessManager.grantRole(CapRoles.ADMIN, address(this), 0);
        accessManager.grantRole(CapRoles.PROTOCOL, address(this), 0);
        accessManager.grantRole(CapRoles.WHITELISTED, address(this), 0);
        accessManager.grantRole(CapRoles.LIQUIDATOR, defaultLiquidator, 0);
        // integration tests mint and write off on the protocol stablecoin without going through a
        // market, so this contract holds the same role the markets do
        accessManager.grantRole(CapRoles.MARKET, address(this), 0);
    }

    // ── operator helpers ──────────────────────────────────────────────────────

    function _assignOperator(address account) internal returns (uint64 roleId) {
        address[][] memory members = new address[][](1);
        members[0] = new address[](1);
        members[0][0] = account;
        roleId = registry.createChildRoles(CapRoles.GOVERNOR, members)[0];
        _operatorRole[account] = roleId;
    }

    function _operatorRoleOf(address account) internal view returns (uint64 roleId) {
        roleId = _operatorRole[account];
    }

    // ── market helpers ────────────────────────────────────────────────────────

    /// @dev The shared collateral repeated once per tranche, for the tests that do not care which
    /// asset a tranche holds
    function _uniformAssets(uint256 count) internal view returns (address[] memory assets) {
        assets = new address[](count);
        for (uint256 i; i < count; ++i) {
            assets[i] = address(collateral);
        }
    }

    function _createMarket(string memory name, address marketOwner, address borrower, uint256[] memory weights)
        internal
        returns (address market, address[] memory tranches)
    {
        (market, tranches) = _createMarket(name, marketOwner, borrower, _uniformAssets(weights.length), weights);
    }

    function _createMarket(
        string memory name,
        address marketOwner,
        address borrower,
        address[] memory assets,
        uint256[] memory weights
    ) internal returns (address market, address[] memory tranches) {
        if (_operatorRoleOf(marketOwner) == 0) _assignOperator(marketOwner);
        if (_operatorRoleOf(borrower) == 0) _assignOperator(borrower);

        (market, tranches) = registry.createFloatingMarket(assets, weights, name, _operatorRoleOf(marketOwner));
        vm.prank(marketOwner);
        IBaseMarket(market).setBorrowerRole(_operatorRoleOf(borrower));
        _applyMarketDefaults(FloatingMarket(market));
    }

    function _createMarket(string memory name) internal returns (address market, address tranche0, address tranche1) {
        address[] memory tranches;
        (market, tranches) = _createMarket(name, defaultMarketOwner, defaultBorrower, capConfig.defaultTrancheWeights);
        tranche0 = tranches[0];
        tranche1 = tranches[1];
    }

    function _createMarket(string memory name, address marketOwner, address borrower)
        internal
        returns (address market, address tranche0, address tranche1)
    {
        address[] memory tranches;
        (market, tranches) = _createMarket(name, marketOwner, borrower, capConfig.defaultTrancheWeights);
        tranche0 = tranches[0];
        tranche1 = tranches[1];
    }

    function _createFixedMarket(string memory name, address marketOwner, address borrower, uint256[] memory weights)
        internal
        returns (address market, address[] memory tranches)
    {
        if (_operatorRoleOf(marketOwner) == 0) _assignOperator(marketOwner);
        if (_operatorRoleOf(borrower) == 0) _assignOperator(borrower);

        (market, tranches) = registry.createFixedMarket(
            _uniformAssets(weights.length),
            weights,
            name,
            _operatorRoleOf(marketOwner),
            capConfig.defaultMaximumTermLimit,
            capConfig.defaultMinimumTermLimit,
            capConfig.defaultGrace
        );
        vm.prank(marketOwner);
        IBaseMarket(market).setBorrowerRole(_operatorRoleOf(borrower));
        _applyMarketDefaults(FloatingMarket(market));
    }

    function _createFixedMarket(string memory name)
        internal
        returns (address market, address tranche0, address tranche1)
    {
        return _createFixedMarket(name, defaultMarketOwner, defaultBorrower);
    }

    function _createFixedMarket(string memory name, address marketOwner, address borrower)
        internal
        returns (address market, address tranche0, address tranche1)
    {
        address[] memory tranches;
        (market, tranches) = _createFixedMarket(name, marketOwner, borrower, capConfig.defaultTrancheWeights);
        tranche0 = tranches[0];
        tranche1 = tranches[1];
    }

    function _createMarketBundle(string memory name) internal returns (MarketBundle memory bundle) {
        bundle = _createMarketBundle(name, defaultMarketOwner, defaultBorrower);
    }

    function _createMarketBundle(string memory name, address marketOwner, address borrower)
        internal
        returns (MarketBundle memory bundle)
    {
        (bundle.marketAddr, bundle.tranche0Addr, bundle.tranche1Addr) = _createMarket(name, marketOwner, borrower);

        bundle.market = FloatingMarket(bundle.marketAddr);
        bundle.tranche0 = Tranche(bundle.tranche0Addr);
        bundle.tranche1 = Tranche(bundle.tranche1Addr);
    }

    /// @dev Create a market, apply slopes, and give each tranche the default max capital.
    function _createReadyMarket(string memory name) internal returns (MarketBundle memory bundle) {
        bundle = _createMarketBundle(name);
        _configureMarketRates(bundle.market);
        _setMaxCapital(bundle.market, capConfig.defaultMaxCapital);
    }

    function _applyMarketDefaults(FloatingMarket market) internal {
        market.setLtv(capConfig.defaultLtv);
        market.setBuffer(capConfig.defaultBuffer);
        market.setLt(capConfig.defaultLt);
        market.setMarketMultiplier(capConfig.defaultMultiplier);
        market.setTargetHealth(capConfig.defaultTargetHealth);
        _setMaxCapital(market, capConfig.defaultMaxCapital);
    }

    /// @dev Set every attached tranche's {ITranche-maxCapital} to `limit`. An empty neighbour
    /// still contributes nothing; a sibling cannot spend this tranche's unused room.
    function _setMaxCapital(IBaseMarket market, uint256 limit) internal {
        IBaseMarket.Tranche[] memory ts = market.tranches();
        for (uint256 i; i < ts.length; ++i) {
            ITranche(ts[i].tranche).setMaxCapital(limit);
        }
    }

    /// @dev Put `limit` on `tranche` and zero every sibling, so only that tranche can
    /// contribute capital.
    function _setMaxCapitalOn(IBaseMarket market, address tranche, uint256 limit) internal {
        IBaseMarket.Tranche[] memory ts = market.tranches();
        for (uint256 i; i < ts.length; ++i) {
            ITranche(ts[i].tranche).setMaxCapital(ts[i].tranche == tranche ? limit : 0);
        }
    }

    /// @dev Size `tranche`'s {ITranche-maxCapital} so the market's {IBaseMarket-creditLimit}
    /// from it equals `limit` once it has the capital. Empty siblings stay at zero.
    function _setBorrowableOn(IBaseMarket market, address tranche, uint256 limit) internal {
        uint256 bufferedLt = market.lt() - market.buffer();
        uint256 ltvBound = market.ltv() < bufferedLt ? market.ltv() : bufferedLt;
        uint256 cap = ltvBound == 0 ? 0 : (limit * 1e27 + ltvBound - 1) / ltvBound;
        _setMaxCapitalOn(market, tranche, cap);
    }

    function _configureMarketRates(FloatingMarket market) internal {
        if (capConfig.applyLiquiditySlopes) {
            irm.setLiquiditySlopes(capConfig.liquiditySlopes);
        }
        market.setUnderwriterRate(capConfig.defaultUnderwriterRate);
    }

    function _setMarketSlopes(address marketAddr) internal {
        FloatingMarket(marketAddr).setUnderwriterRate(capConfig.defaultUnderwriterRate);
    }

    function _grantKeeper(address keeper) internal {
        accessManager.grantRole(CapRoles.KEEPER, keeper, 0);
    }

    function _grantLiquidator(address liquidator) internal {
        accessManager.grantRole(CapRoles.LIQUIDATOR, liquidator, 0);
    }

    // ── admission helpers ─────────────────────────────────────────────────────

    /// @dev Tranches and underwriters are admitted the same way: the role the AccessManager has
    /// wired to {IERC4626-deposit} on that vault *is* the allowlist, and neither contract keeps a
    /// copy. Its admin is the market owner's or curator's operator role, so the grant has to come
    /// from them -- which in these tests is the deployer itself.
    function _depositorRole(address capVault) internal view returns (uint64 roleId) {
        roleId = accessManager.getTargetFunctionRole(capVault, IERC4626.deposit.selector);
    }

    function _allocatorRole(address underwriter) internal view returns (uint64 roleId) {
        roleId = accessManager.getTargetFunctionRole(underwriter, IUnderwriter.allocate.selector);
    }

    function _admitDepositor(address capVault, address account) internal {
        accessManager.grantRole(_depositorRole(capVault), account, 0);
    }

    function _expelDepositor(address capVault, address account) internal {
        accessManager.revokeRole(_depositorRole(capVault), account);
    }

    /// @dev Whether an account could deposit, asking the AccessManager the same question the
    /// {IERC4626-deposit} modifier does
    function _mayDeposit(address capVault, address account) internal view returns (bool allowed) {
        (allowed,) = accessManager.canCall(account, capVault, IERC4626.deposit.selector);
    }

    // ── oracle helpers ────────────────────────────────────────────────────────

    /// @dev Post a price for an asset, standing a feed up behind it on first use.
    ///
    /// Takes the price in {IOracle-DECIMALS} because that is the scale every consumer reads it in
    /// and so the scale the assertions are written in, but posts it to the aggregator in the
    /// feed's own, leaving the adapter to normalise it back. So the value asserted against is only
    /// the value posted if the adapter and the oracle agree, which is the point of routing the
    /// suite through them. Refuses a price the feed cannot express rather than quietly truncating
    /// it, since a test that lost precision here would read as a pricing bug somewhere else.
    function _setPrice(address asset, uint256 price) internal {
        uint256 scale = 10 ** (oracle.DECIMALS() - FEED_DECIMALS);
        require(price % scale == 0, "price too fine for the feed's decimals");

        MockAggregator feed = feeds[asset];
        if (address(feed) == address(0)) {
            feed = new MockAggregator(FEED_DECIMALS, 0, 0);
            feeds[asset] = feed;
        }

        uint256 scaled = price / scale;
        require(scaled <= uint256(type(int256).max), "price exceeds the feed's signed range");
        // casting to 'int256' is safe because scaled is checked against int256.max
        // forge-lint: disable-next-line(unsafe-typecast)
        feed.setAnswer(int256(scaled));
        feed.setUpdatedAt(block.timestamp);

        if (oracle.sources(asset).length == 0) _setStaleness(asset, FEED_STALENESS);
    }

    /// @dev Narrow an asset's staleness window, keeping the feed it already points at
    function _setStaleness(address asset, uint256 staleness) internal {
        IOracle.Sources[] memory hops = new IOracle.Sources[](1);
        hops[0].primary = IOracle.Source({
            adapter: chainlinkAdapter,
            payload: abi.encodeWithSelector(ChainlinkAdapter.price.selector, address(feeds[asset])),
            staleness: staleness
        });
        oracle.setSource(asset, hops);
    }

    // ── funding helpers ───────────────────────────────────────────────────────

    /// @dev A second collateral the oracle can price, for markets whose tranches do not all hold
    /// the same asset
    function _newCollateral(string memory name, string memory symbol, uint8 decimals, uint256 price)
        internal
        returns (MockERC20 token)
    {
        token = new MockERC20(name, symbol, decimals);
        _setPrice(address(token), price);
    }

    function _fundTranche(address tranche, address supplier, uint256 amount) internal {
        _fundTranche(tranche, address(collateral), supplier, amount);
    }

    function _fundTranche(address tranche, address asset, address supplier, uint256 amount) internal {
        MockERC20(asset).mint(supplier, amount);
        vm.startPrank(supplier);
        MockERC20(asset).approve(address(vault), amount);
        vault.deposit(asset, amount, supplier);
        vault.setOperator(tranche, true);
        vm.stopPrank();

        _admitDepositor(tranche, supplier);

        vm.startPrank(supplier);
        Tranche(tranche).deposit(amount, supplier);
        Tranche(tranche).optIn();
        vm.stopPrank();
    }

    function _fundVault(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(vault), amount);
        vault.deposit(address(collateral), amount, who);
        vm.stopPrank();
    }

    function _mintStable(address to, uint256 amount) internal {
        stablecoin.mintCreditBacked(to, amount);
    }

    /// @dev An ordinary permissionless deposit into the stablecoin. This is idle reserve rather
    /// than credit, so it raises total supply without raising credit-backed supply and therefore
    /// dilutes utilization
    function _depositStable(address who, uint256 amount) internal {
        cusdUnderlying.mint(who, amount);
        vm.startPrank(who);
        cusdUnderlying.approve(address(stablecoin), amount);
        stablecoin.deposit(amount, who);
        vm.stopPrank();
    }

    // ── underwriter helpers ───────────────────────────────────────────────────

    function _deployUnderwriter() internal returns (Underwriter underwriter) {
        if (_operatorRoleOf(address(this)) == 0) _assignOperator(address(this));
        string memory suffix = vm.toString(_underwriterDeploymentCount++);
        uint64 curatorRole = _operatorRoleOf(address(this));
        address[][] memory members = new address[][](2);
        members[0] = new address[](2);
        members[0][0] = makeAddr(string.concat("underwriterAllocator", suffix));
        members[0][1] = address(this);
        members[1] = new address[](1);
        members[1][0] = makeAddr(string.concat("underwriterDepositor", suffix));
        uint64[] memory roleIds = registry.createChildRoles(curatorRole, members);
        uint64 allocatorRole = roleIds[0];
        uint64 depositorRole = roleIds[1];

        address uw = registry.createUnderwriter(address(collateral), "Cap Underwriter", "cUW", curatorRole);
        underwriter = Underwriter(uw);
        underwriter.setAllocatorRole(allocatorRole);
        underwriter.setDepositorRole(depositorRole);
    }

    function _fundUnderwriter(address underwriter, address supplier, uint256 amount) internal {
        _fundVault(supplier, amount);
        _admitDepositor(underwriter, supplier);
        vm.startPrank(supplier);
        vault.setOperator(underwriter, true);
        Underwriter(underwriter).deposit(amount, supplier);
        Underwriter(underwriter).optIn();
        vm.stopPrank();
    }
}
