// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "./BaseTest.sol";
import { CapRoles } from "./CapRoles.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockOracle } from "./mocks/MockOracle.sol";

import { BeaconFactory } from "../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Market } from "../../contracts/cap/Market.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { Vault } from "../../contracts/cap/Vault.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CapDeployer
/// @notice Deploys and wires a full Cap protocol stack for unit and integration tests.
/// @dev Override `capConfig` fields before `_deployCap()` to tune defaults per test suite.
abstract contract CapDeployer is BaseTest {
    uint64 internal constant MANAGER_ROLE = CapRoles.MANAGER;
    uint64 internal constant BORROWER_ROLE = CapRoles.BORROWER;
    uint64 internal constant KEEPER_ROLE = CapRoles.KEEPER;
    uint64 internal constant MINTER_ROLE = CapRoles.MINTER;

    // ── protocol instances ────────────────────────────────────────────────────
    MockOracle internal oracle;
    MockERC20 internal cusdUnderlying;
    MockERC20 internal collateral;

    Vault internal vault;
    Stablecoin internal stablecoin;
    InterestRateModel internal irm;
    Registry internal registry;

    BeaconFactory internal marketFactory;
    BeaconFactory internal trancheFactory;
    BeaconFactory internal underwriterFactory;

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
        uint256 defaultKinkMinBonus;
        uint256 defaultKinkMaxBonus;
        uint256 defaultKinkBonus;
        uint256 defaultJuniorSplit;
        uint256 defaultBorrowCap;
        IInterestRateModel.Slopes variableSlopes;
        IInterestRateModel.Slopes underwriterSlopes;
        bool applyVariableSlopes;
        bool applyUnderwriterSlopes;
    }

    /// @dev Result bundle returned by market creation helpers.
    struct MarketBundle {
        Market market;
        Tranche senior;
        Tranche junior;
        address marketAddr;
        address seniorAddr;
        address juniorAddr;
    }

    function _defaultCapConfig() internal pure returns (CapConfig memory cfg) {
        cfg.collateralPrice = 1e27;
        cfg.stablecoinYield = address(0);
        cfg.defaultLtv = 0.5e27;
        cfg.defaultBuffer = 0.1e27;
        cfg.defaultLt = 0.8e27;
        cfg.defaultMultiplier = 1e27;
        cfg.defaultTargetHealth = 1.1e27;
        cfg.defaultKinkMinBonus = 0.9e27;
        cfg.defaultKinkMaxBonus = 0.02e27;
        cfg.defaultKinkBonus = 0.1e27;
        cfg.defaultJuniorSplit = 0.5e27;
        cfg.defaultBorrowCap = 1_000e18;
        cfg.variableSlopes = IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 });
        cfg.underwriterSlopes =
            IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 });
        cfg.applyVariableSlopes = false;
        cfg.applyUnderwriterSlopes = false;
    }

    // ── deployment ────────────────────────────────────────────────────────────

    function _deployCap() internal {
        capConfig = _defaultCapConfig();
        _deployCapWithConfig(capConfig);
    }

    function _deployCapWithConfig(CapConfig memory cfg) internal {
        capConfig = cfg;
        _setUpAccessManager();
        _deployCoreContracts();
        _deployRegistry();
        _configureAccess();
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
            _deployProxy(address(irmImpl), abi.encodeCall(InterestRateModel.initialize, (authority, stablecoinAddr)))
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

        Market marketImpl = new Market();
        Tranche trancheImpl = new Tranche();
        Underwriter underwriterImpl = new Underwriter();

        marketFactory = new BeaconFactory(address(new UpgradeableBeacon(address(marketImpl), address(this))));
        trancheFactory = new BeaconFactory(address(new UpgradeableBeacon(address(trancheImpl), address(this))));
        underwriterFactory = new BeaconFactory(address(new UpgradeableBeacon(address(underwriterImpl), address(this))));
    }

    function _deployRegistry() internal {
        registry = Registry(
            _deployProxy(
                address(new Registry()),
                abi.encodeCall(
                    Registry.initialize,
                    (
                        address(accessManager),
                        address(stablecoin),
                        capConfig.stablecoinYield,
                        address(vault),
                        address(oracle),
                        address(irm),
                        address(marketFactory),
                        address(trancheFactory),
                        address(underwriterFactory)
                    )
                )
            )
        );
    }

    function _configureAccess() internal {
        bytes4[] memory registrySelectors = new bytes4[](2);
        registrySelectors[0] = Registry.createMarket.selector;
        registrySelectors[1] = Registry.createUnderwriter.selector;
        accessManager.setTargetFunctionRole(address(registry), registrySelectors, CapRoles.MANAGER);
        accessManager.grantRole(CapRoles.MANAGER, address(registry), 0);
        accessManager.grantRole(CapRoles.MANAGER, address(this), 0);

        bytes4[] memory minterSelectors = new bytes4[](2);
        minterSelectors[0] = Stablecoin.mintUnbacked.selector;
        minterSelectors[1] = Stablecoin.burnUnbacked.selector;
        accessManager.setTargetFunctionRole(address(stablecoin), minterSelectors, CapRoles.MINTER);
        accessManager.grantRole(CapRoles.MINTER, address(this), 0);

        bytes4[] memory irmSelectors = new bytes4[](3);
        irmSelectors[0] = InterestRateModel.setVariableSlopes.selector;
        irmSelectors[1] = InterestRateModel.setFixedSlopes.selector;
        irmSelectors[2] = InterestRateModel.setUnderwriterSlopes.selector;
        accessManager.setTargetFunctionRole(address(irm), irmSelectors, CapRoles.MANAGER);

        accessManager.grantRole(CapRoles.ADMIN, address(registry), 0);
        accessManager.grantRole(CapRoles.GUARDIAN, address(registry), 0);
        accessManager.grantRole(CapRoles.GUARDIAN, address(this), 0);
    }

    // ── market helpers ────────────────────────────────────────────────────────

    /// @dev Create a market with default capConfig risk parameters.
    function _createMarket(string memory name) internal returns (address market, address senior, address junior) {
        return _createMarket(name, CapRoles.MANAGER, CapRoles.BORROWER);
    }

    function _createMarket(string memory name, uint64 managerId, uint64 borrowerId)
        internal
        returns (address market, address senior, address junior)
    {
        (market, senior, junior) = registry.createMarket(address(collateral), name, managerId, borrowerId);
        _applyMarketDefaults(Market(market));
    }

    function _createMarketBundle(string memory name) internal returns (MarketBundle memory bundle) {
        bundle = _createMarketBundle(name, CapRoles.MANAGER, CapRoles.BORROWER);
    }

    function _createMarketBundle(string memory name, uint64 managerId, uint64 borrowerId)
        internal
        returns (MarketBundle memory bundle)
    {
        (bundle.marketAddr, bundle.seniorAddr, bundle.juniorAddr) =
            registry.createMarket(address(collateral), name, managerId, borrowerId);

        bundle.market = Market(bundle.marketAddr);
        bundle.senior = Tranche(bundle.seniorAddr);
        bundle.junior = Tranche(bundle.juniorAddr);

        _applyMarketDefaults(bundle.market);
    }

    /// @dev Create market, apply slopes, junior split, and borrow cap from capConfig.
    function _createReadyMarket(string memory name) internal returns (MarketBundle memory bundle) {
        bundle = _createMarketBundle(name);
        _configureMarketRates(bundle.marketAddr);
        bundle.market.setJuniorSplit(capConfig.defaultJuniorSplit);
        bundle.market.setBorrowCap(capConfig.defaultBorrowCap);
    }

    function _applyMarketDefaults(Market market) internal {
        market.setLtv(capConfig.defaultLtv);
        market.setBuffer(capConfig.defaultBuffer);
        market.setLt(capConfig.defaultLt);
        market.setMultiplier(capConfig.defaultMultiplier);
        market.setTargetHealth(capConfig.defaultTargetHealth);
        market.setBonusConfig(capConfig.defaultKinkMinBonus, capConfig.defaultKinkMaxBonus, capConfig.defaultKinkBonus);
    }

    function _configureMarketRates(address marketAddr) internal {
        if (capConfig.applyVariableSlopes) {
            irm.setVariableSlopes(capConfig.variableSlopes);
        }
        if (capConfig.applyUnderwriterSlopes) {
            irm.setUnderwriterSlopes(marketAddr, capConfig.underwriterSlopes);
        }
    }

    function _setMarketSlopes(address marketAddr) internal {
        irm.setUnderwriterSlopes(
            marketAddr, IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 })
        );
    }

    function _grantBorrower(address borrower) internal {
        accessManager.grantRole(CapRoles.BORROWER, borrower, 0);
    }

    function _grantKeeper(address keeper) internal {
        accessManager.grantRole(CapRoles.KEEPER, keeper, 0);
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
        stablecoin.mintUnbacked(to, amount);
    }

    // ── underwriter helpers ───────────────────────────────────────────────────

    function _deployUnderwriter() internal returns (Underwriter underwriter) {
        address uw = registry.createUnderwriter(address(collateral), "Cap Underwriter", "cUW", CapRoles.MANAGER);
        underwriter = Underwriter(uw);
    }

    function _fundUnderwriter(address underwriter, address supplier, uint256 amount) internal {
        _fundVault(supplier, amount);
        Underwriter(underwriter).whitelist(supplier, true);
        vm.startPrank(supplier);
        vault.setOperator(underwriter, true);
        Underwriter(underwriter).deposit(amount, supplier);
        vm.stopPrank();
    }
}
