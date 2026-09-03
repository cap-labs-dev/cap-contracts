// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseTest } from "./BaseTest.sol";
import { CapRoles } from "./CapRoles.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockOracle } from "./mocks/MockOracle.sol";

import { BeaconFactory } from "../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { Vault } from "../../contracts/cap/Vault.sol";
import { FixedMarket } from "../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IBeaconFactory } from "../../contracts/interfaces/IBeaconFactory.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IRegistry } from "../../contracts/interfaces/IRegistry.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CapDeployer
/// @notice Deploys and wires a full Cap protocol stack for unit and integration tests.
/// @dev Override `capConfig` fields before `_deployCap()` to tune defaults per test suite.
abstract contract CapDeployer is BaseTest {
    // ── protocol instances ────────────────────────────────────────────────────
    MockOracle internal oracle;
    MockERC20 internal cusdUnderlying;
    MockERC20 internal collateral;

    Vault internal vault;
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

    // ── tunable deployment config (mutate before _deployCap) ─────────────────
    CapConfig internal capConfig;

    struct CapConfig {
        uint256 collateralPrice;
        address stablecoinYield;
        uint256 defaultLtv;
        uint256 defaultBuffer;
        uint256 defaultLt;
        uint256 defaultMultiplier;
        uint256 defaultTargetHealth;
        uint256 defaultLiquidationBonus;
        uint256 defaultMinimumMarketMultiplier;
        uint256 defaultMaximumMarketMultiplier;
        uint256 defaultMaximumUnderwriterRate;
        uint256 defaultUnderwriterRate;
        uint256[] defaultTrancheWeights;
        uint256 defaultFixedCreditLimit;
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
        cfg.stablecoinYield = address(0);
        cfg.defaultLtv = 0.5e27;
        cfg.defaultBuffer = 0.1e27;
        cfg.defaultLt = 0.8e27;
        cfg.defaultMultiplier = 1e27;
        cfg.defaultTargetHealth = 1.25e27;
        cfg.defaultLiquidationBonus = 0.02e27;
        cfg.defaultMinimumMarketMultiplier = 1e27;
        cfg.defaultMaximumMarketMultiplier = 2e27;
        cfg.defaultMaximumUnderwriterRate = 1e27;
        cfg.defaultUnderwriterRate = 0.2e27; // 20% APR in ray per year
        cfg.defaultTrancheWeights = new uint256[](2);
        cfg.defaultTrancheWeights[0] = 1e27 - 0.05e27;
        cfg.defaultTrancheWeights[1] = 0.05e27;
        cfg.defaultFixedCreditLimit = 1_000e18;
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
        if (cfg.stablecoinYield == address(0)) {
            cfg.stablecoinYield = makeAddr("stcUSD");
        }
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

        oracle.setPrice(address(collateral), capConfig.collateralPrice);
    }

    function _deployCoreContracts() internal {
        address authority = address(accessManager);

        oracle = new MockOracle();
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
                        capConfig.defaultLiquidationBonus
                    )
                )
            )
        );
        stablecoin = Stablecoin(
            _deployProxy(
                address(stablecoinImpl),
                abi.encodeCall(
                    Stablecoin.initialize, (authority, address(cusdUnderlying), "Cap USD", "cUSD", "", irmAddr)
                )
            )
        );

        require(address(irm) == irmAddr, "irm addr");
        require(address(stablecoin) == stablecoinAddr, "stablecoin addr");

        FloatingMarket marketImpl = new FloatingMarket();
        FixedMarket fixedMarketImpl = new FixedMarket();
        Tranche trancheImpl = new Tranche();
        Underwriter underwriterImpl = new Underwriter();

        beaconFactory = BeaconFactory(
            _deployProxy(
                address(new BeaconFactory()), abi.encodeCall(BeaconFactory.initialize, (address(accessManager)))
            )
        );
        floatingMarketBeacon = address(new UpgradeableBeacon(address(marketImpl), address(this)));
        fixedMarketBeacon = address(new UpgradeableBeacon(address(fixedMarketImpl), address(this)));
        trancheBeacon = address(new UpgradeableBeacon(address(trancheImpl), address(this)));
        underwriterBeacon = address(new UpgradeableBeacon(address(underwriterImpl), address(this)));
    }

    function _deployRegistry() internal {
        registry = Registry(
            _deployProxy(
                address(new Registry()),
                abi.encodeCall(
                    Registry.initialize,
                    (
                        address(accessManager),
                        IRegistry.InitParams({
                            stablecoin: address(stablecoin),
                            stakedStablecoin: capConfig.stablecoinYield,
                            vault: address(vault),
                            oracle: address(oracle),
                            irm: address(irm),
                            factory: address(beaconFactory),
                            floatingMarketBeacon: floatingMarketBeacon,
                            fixedMarketBeacon: fixedMarketBeacon,
                            trancheBeacon: trancheBeacon,
                            underwriterBeacon: underwriterBeacon,
                            lt: capConfig.defaultLt,
                            buffer: capConfig.defaultBuffer,
                            targetHealth: capConfig.defaultTargetHealth
                        })
                    )
                )
            )
        );
    }

    function _configureAccess() internal {
        accessManager.grantRole(CapRoles.ADMIN, address(registry), 0);
        accessManager.grantRole(CapRoles.REGISTRY, address(registry), 0);
        accessManager.grantRole(CapRoles.GOVERNOR, address(this), 0);
        accessManager.grantRole(CapRoles.KEEPER, address(this), 0);
        accessManager.grantRole(CapRoles.GUARDIAN, address(this), 0);
        accessManager.grantRole(CapRoles.ADMIN, address(this), 0);
        accessManager.grantRole(CapRoles.LIQUIDATOR, defaultLiquidator, 0);

        bytes4[] memory factorySelectors = new bytes4[](1);
        factorySelectors[0] = IBeaconFactory.create.selector;
        accessManager.setTargetFunctionRole(address(beaconFactory), factorySelectors, CapRoles.REGISTRY);

        bytes4[] memory governorSelectors = new bytes4[](1);
        governorSelectors[0] = Registry.assignOperator.selector;
        accessManager.setTargetFunctionRole(address(registry), governorSelectors, CapRoles.GOVERNOR);

        bytes4[] memory keeperSelectors = new bytes4[](3);
        keeperSelectors[0] = Registry.createMarket.selector;
        keeperSelectors[1] = Registry.createFixedMarket.selector;
        keeperSelectors[2] = Registry.createUnderwriter.selector;
        accessManager.setTargetFunctionRole(address(registry), keeperSelectors, CapRoles.KEEPER);

        bytes4[] memory minterSelectors = new bytes4[](3);
        minterSelectors[0] = Stablecoin.mintCreditBacked.selector;
        minterSelectors[1] = Stablecoin.burnCreditBacked.selector;
        minterSelectors[2] = Stablecoin.recognizeBadDebt.selector;
        accessManager.setTargetFunctionRole(address(stablecoin), minterSelectors, CapRoles.MINTER);
        accessManager.grantRole(CapRoles.MINTER, address(this), 0);

        bytes4[] memory stablecoinGovernorSelectors = new bytes4[](1);
        stablecoinGovernorSelectors[0] = Stablecoin.coverBadDebt.selector;
        accessManager.setTargetFunctionRole(address(stablecoin), stablecoinGovernorSelectors, CapRoles.GOVERNOR);

        bytes4[] memory irmGovernorSelectors = new bytes4[](3);
        irmGovernorSelectors[0] = InterestRateModel.setLiquiditySlopes.selector;
        irmGovernorSelectors[1] = InterestRateModel.setTermMultiplierSlope.selector;
        irmGovernorSelectors[2] = InterestRateModel.setLiquidationBonus.selector;
        accessManager.setTargetFunctionRole(address(irm), irmGovernorSelectors, CapRoles.GOVERNOR);
    }

    // ── operator helpers ──────────────────────────────────────────────────────

    function _assignOperator(address account) internal returns (uint64 roleId) {
        roleId = registry.assignOperator(account);
    }

    // ── market helpers ────────────────────────────────────────────────────────

    function _createMarket(string memory name, address marketOwner, address borrower, uint256[] memory weights)
        internal
        returns (address market, address[] memory tranches)
    {
        if (registry.operatorRole(marketOwner) == 0) _assignOperator(marketOwner);
        if (registry.operatorRole(borrower) == 0) _assignOperator(borrower);

        (market, tranches) = registry.createMarket(address(collateral), name, marketOwner, borrower, weights);
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
        if (registry.operatorRole(marketOwner) == 0) _assignOperator(marketOwner);
        if (registry.operatorRole(borrower) == 0) _assignOperator(borrower);

        (market, tranches) = registry.createFixedMarket(
            address(collateral),
            name,
            marketOwner,
            borrower,
            capConfig.defaultMaximumTermLimit,
            capConfig.defaultMinimumTermLimit,
            capConfig.defaultGrace,
            weights
        );
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

    /// @dev Create market, apply slopes, and fixed credit limit from capConfig.
    function _createReadyMarket(string memory name) internal returns (MarketBundle memory bundle) {
        bundle = _createMarketBundle(name);
        _configureMarketRates(bundle.market);
        bundle.market.setFixedCreditLimit(capConfig.defaultFixedCreditLimit);
    }

    function _applyMarketDefaults(FloatingMarket market) internal {
        market.setLtv(capConfig.defaultLtv);
        market.setBuffer(capConfig.defaultBuffer);
        market.setLt(capConfig.defaultLt);
        market.setMarketMultiplier(capConfig.defaultMultiplier);
        market.setTargetHealth(capConfig.defaultTargetHealth);
        market.setFixedCreditLimit(capConfig.defaultFixedCreditLimit);
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

    // ── funding helpers ───────────────────────────────────────────────────────

    function _fundTranche(address tranche, address supplier, uint256 amount) internal {
        collateral.mint(supplier, amount);
        vm.startPrank(supplier);
        collateral.approve(address(vault), amount);
        vault.deposit(address(collateral), amount, supplier);
        vault.setOperator(tranche, true);
        vm.stopPrank();

        Tranche(tranche).setWhitelist(supplier, true);

        vm.prank(supplier);
        Tranche(tranche).deposit(amount, supplier);
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

    // ── underwriter helpers ───────────────────────────────────────────────────

    function _deployUnderwriter() internal returns (Underwriter underwriter) {
        if (registry.operatorRole(address(this)) == 0) _assignOperator(address(this));
        address uw = registry.createUnderwriter(address(collateral), "Cap Underwriter", "cUW", address(this));
        underwriter = Underwriter(uw);
    }

    /// @dev Admit a depositor to an underwriter. The role wired to {IERC4626-deposit} *is* the
    /// whitelist, and the curator's operator role administers it, so the grant has to come from the
    /// curator -- which in these tests is the deployer itself.
    function _depositorRole(address underwriter) internal view returns (uint64 roleId) {
        roleId = accessManager.getTargetFunctionRole(underwriter, IERC4626.deposit.selector);
    }

    function _admitDepositor(address underwriter, address account) internal {
        accessManager.grantRole(_depositorRole(underwriter), account, 0);
    }

    function _fundUnderwriter(address underwriter, address supplier, uint256 amount) internal {
        _fundVault(supplier, amount);
        _admitDepositor(underwriter, supplier);
        vm.startPrank(supplier);
        vault.setOperator(underwriter, true);
        Underwriter(underwriter).deposit(amount, supplier);
        vm.stopPrank();
    }
}
