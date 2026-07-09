// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "../shared/BaseTest.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { MockOracle } from "../shared/mocks/MockOracle.sol";

import { BeaconFactory } from "../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Market } from "../../contracts/cap/Market.sol";
import { Registry } from "../../contracts/cap/Registry.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { Vault } from "../../contracts/cap/Vault.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IMarket } from "../../contracts/interfaces/IMarket.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CapDeployer
/// @notice Deploys and fully wires a Cap protocol instance for integration-style unit tests.
abstract contract CapDeployer is BaseTest {
    uint64 internal constant MINTER_ROLE = 1;
    uint64 internal constant MANAGER_ROLE = 2;
    uint64 internal constant KEEPER_ROLE = 3;
    uint64 internal constant BORROWER_ROLE = 4;

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

    uint256 internal constant DEFAULT_BUFFER = 0.1e27;
    uint256 internal constant DEFAULT_LT = 0.8e27;
    uint256 internal constant DEFAULT_LTV = 0.5e27;

    function _deployCap() internal {
        _setUpAccessManager();
        address authority = address(accessManager);

        oracle = new MockOracle();
        cusdUnderlying = new MockERC20("USD Coin", "USDC", 18);
        collateral = new MockERC20("Wrapped Ether", "WETH", 18);

        Vault vaultImpl = new Vault();
        Stablecoin stablecoinImpl = new Stablecoin();
        InterestRateModel irmImpl = new InterestRateModel();
        Market marketImpl = new Market();
        Tranche trancheImpl = new Tranche();
        Underwriter underwriterImpl = new Underwriter();
        Registry registryImpl = new Registry();

        // Vault has no cross dependencies
        vault = Vault(_deployProxy(address(vaultImpl), abi.encodeCall(Vault.initialize, (authority))));

        uint256 n = vm.getNonce(address(this));
        address irmAddr = vm.computeCreateAddress(address(this), n);
        address stablecoinAddr = vm.computeCreateAddress(address(this), n + 1);

        irm = InterestRateModel(
            _deployProxy(address(irmImpl), abi.encodeCall(InterestRateModel.initialize, (stablecoinAddr, authority)))
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

        UpgradeableBeacon marketBeacon = new UpgradeableBeacon(address(marketImpl), address(this));
        UpgradeableBeacon trancheBeacon = new UpgradeableBeacon(address(trancheImpl), address(this));
        UpgradeableBeacon underwriterBeacon = new UpgradeableBeacon(address(underwriterImpl), address(this));

        marketFactory = new BeaconFactory(address(marketBeacon));
        trancheFactory = new BeaconFactory(address(trancheBeacon));
        underwriterFactory = new BeaconFactory(address(underwriterBeacon));

        registry = Registry(
            _deployProxy(
                address(registryImpl),
                abi.encodeCall(
                    Registry.initialize,
                    (
                        authority,
                        address(stablecoin),
                        address(0),
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

        _configureAccess();

        oracle.setPrice(address(collateral), 1e27);
    }

    function _configureAccess() internal {
        bytes4[] memory registrySelectors = new bytes4[](2);
        registrySelectors[0] = Registry.createMarket.selector;
        registrySelectors[1] = Registry.createUnderwriter.selector;
        accessManager.setTargetFunctionRole(address(registry), registrySelectors, MANAGER_ROLE);
        accessManager.grantRole(MANAGER_ROLE, address(registry), 0);
        accessManager.grantRole(MANAGER_ROLE, address(this), 0);

        bytes4[] memory minterSelectors = new bytes4[](2);
        minterSelectors[0] = Stablecoin.mintUnbacked.selector;
        minterSelectors[1] = Stablecoin.burnUnbacked.selector;
        accessManager.setTargetFunctionRole(address(stablecoin), minterSelectors, MINTER_ROLE);
        accessManager.grantRole(MINTER_ROLE, address(this), 0);

        bytes4[] memory irmSelectors = new bytes4[](3);
        irmSelectors[0] = InterestRateModel.setVariableSlopes.selector;
        irmSelectors[1] = InterestRateModel.setFixedSlopes.selector;
        irmSelectors[2] = InterestRateModel.setUnderwriterSlopes.selector;
        accessManager.setTargetFunctionRole(address(irm), irmSelectors, MANAGER_ROLE);

        accessManager.grantRole(ADMIN_ROLE, address(registry), 0);
    }

    uint64 internal constant ADMIN_ROLE = 0;

    function _createMarket(string memory name, uint64 managerId, uint64 borrowerId)
        internal
        returns (address market, address senior, address junior)
    {
        (market, senior, junior) = registry.createMarket(address(collateral), name, managerId, borrowerId);
        Market(market).setLtv(DEFAULT_LTV);
        Market(market).setBuffer(DEFAULT_BUFFER);
        Market(market).setLt(DEFAULT_LT);
        Market(market).setMultiplier(1e27);
        Market(market).setTargetHealth(1.1e27);
        Market(market).setBonusConfig(0.9e27, 0.02e27, 0.1e27);
    }

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

    function _setMarketSlopes(address market) internal {
        irm.setUnderwriterSlopes(
            market, IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 })
        );
    }

    function _mintStable(address to, uint256 amount) internal {
        stablecoin.mintUnbacked(to, amount);
    }

    function _fundVault(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(vault), amount);
        vault.deposit(address(collateral), amount, who);
        vm.stopPrank();
    }

    function _deployUnderwriter() internal returns (Underwriter underwriter) {
        address uw = registry.createUnderwriter(address(collateral), "Cap Underwriter", "cUW", MANAGER_ROLE);
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
