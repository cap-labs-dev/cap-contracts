// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { BaseTest } from "../shared/BaseTest.sol";
import { MockERC20 } from "../shared/mocks/MockERC20.sol";
import { MockOracle } from "../shared/mocks/MockOracle.sol";

import { InterestRateModel } from "../../contracts/cap/InterestRateModel.sol";
import { Lender } from "../../contracts/cap/Lender.sol";
import { Stablecoin } from "../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { Vault } from "../../contracts/cap/Vault.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";

import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CapDeployer
/// @notice Deploys and fully wires a Cap protocol instance for integration-style unit tests.
/// @dev Resolves the deploy-order circular dependencies by deploying every proxy first and then
/// initializing. The test contract is the AccessManager admin and the protocol's "minter" role is
/// granted to the Lender so it can mint/burn unbacked cUSD.
abstract contract CapDeployer is BaseTest {
    uint64 internal constant MINTER_ROLE = 1;

    // core
    MockOracle internal oracle;
    MockERC20 internal cusdUnderlying; // underlying for the stablecoin (cUSD reserves)
    MockERC20 internal collateral; // market collateral asset

    Vault internal vault;
    Stablecoin internal stablecoin;
    InterestRateModel internal irm;
    Lender internal lender;
    UpgradeableBeacon internal trancheBeacon;

    // sensible defaults (ray)
    uint256 internal constant DEFAULT_BUFFER = 0.1e27;
    uint256 internal constant DEFAULT_LT = 0.8e27;
    uint256 internal constant DEFAULT_LTV = 0.5e27;

    function _deployCap() internal {
        _setUpAccessManager();
        address authority = address(accessManager);

        oracle = new MockOracle();
        cusdUnderlying = new MockERC20("USD Coin", "USDC", 18);
        collateral = new MockERC20("Wrapped Ether", "WETH", 18);

        // implementations
        Vault vaultImpl = new Vault();
        Stablecoin stablecoinImpl = new Stablecoin();
        InterestRateModel irmImpl = new InterestRateModel();
        Lender lenderImpl = new Lender();
        Tranche trancheImpl = new Tranche();
        trancheBeacon = new UpgradeableBeacon(address(trancheImpl), address(this));

        // Vault has no cross dependencies
        vault = Vault(_deployProxy(address(vaultImpl), abi.encodeCall(Vault.initialize, (authority))));

        // The Hub (Lender), IRM and Stablecoin reference each other, so this OZ proxy forbids deploying
        // uninitialized. Pre-compute the three proxy addresses (CREATE is deterministic from sender+nonce)
        // and initialize each one immediately with the known peers.
        uint256 n = vm.getNonce(address(this));
        address lenderAddr = vm.computeCreateAddress(address(this), n);
        address irmAddr = vm.computeCreateAddress(address(this), n + 1);
        address stablecoinAddr = vm.computeCreateAddress(address(this), n + 2);

        lender = Lender(
            _deployProxy(
                address(lenderImpl),
                abi.encodeCall(
                    Lender.initialize,
                    (authority, stablecoinAddr, address(trancheBeacon), address(oracle), address(vault), irmAddr)
                )
            )
        );
        irm = InterestRateModel(
            _deployProxy(
                address(irmImpl), abi.encodeCall(InterestRateModel.initialize, (stablecoinAddr, lenderAddr, authority))
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

        require(address(lender) == lenderAddr, "lender addr");
        require(address(irm) == irmAddr, "irm addr");
        require(address(stablecoin) == stablecoinAddr, "stablecoin addr");

        // risk params
        lender.setDefaultBuffer(DEFAULT_BUFFER);
        lender.setDefaultLt(DEFAULT_LT);
        lender.setMultiplierLimits(0, 10e27);
        lender.setTargetHealth(1.1e27);
        lender.setBonusConfig(0.9e27, 0.02e27, 0.1e27);

        // allow the Hub to mint/burn unbacked cUSD
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = Stablecoin.mintUnbacked.selector;
        sels[1] = Stablecoin.burnUnbacked.selector;
        accessManager.setTargetFunctionRole(address(stablecoin), sels, MINTER_ROLE);
        accessManager.grantRole(MINTER_ROLE, address(lender), 0);

        // price the collateral at $1 (ray)
        oracle.setPrice(address(collateral), 1e27);
    }

    /// @dev Create a market and return its id plus tranche addresses.
    function _createMarket(string memory name, address[] memory borrowers)
        internal
        returns (bytes32 marketId, address senior, address junior)
    {
        (marketId, senior, junior) = lender.createMarket(name, name, address(collateral), DEFAULT_LTV, borrowers);
    }

    /// @dev Fund a tranche with `amount` of collateral supplied by `supplier`.
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

    function _setMarketSlopes(bytes32 marketId) internal {
        irm.setMarketSlopes(
            marketId, IInterestRateModel.Slopes({ base: 0.2e27, slope0: 0.1e27, slope1: 0.3e27, kink: 0.5e27 })
        );
    }

    /// @dev Mint unbacked cUSD to an address (e.g. to fund a liquidator after interest compounds).
    function _mintStable(address to, uint256 amount) internal {
        accessManager.grantRole(MINTER_ROLE, address(this), 0);
        stablecoin.mintUnbacked(to, amount);
    }

    /// @dev Give `who` an ERC6909 vault balance of collateral (the form tranches/underwriters consume).
    function _fundVault(address who, uint256 amount) internal {
        collateral.mint(who, amount);
        vm.startPrank(who);
        collateral.approve(address(vault), amount);
        vault.deposit(address(collateral), amount, who);
        vm.stopPrank();
    }

    /// @dev Deploy a curator-level Underwriter over the collateral asset, paying rewards in cUSD.
    function _deployUnderwriter() internal returns (Underwriter underwriter) {
        Underwriter impl = new Underwriter();
        underwriter = Underwriter(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Underwriter.initialize,
                    (
                        address(accessManager),
                        "Cap Underwriter",
                        "cUW",
                        address(collateral),
                        address(vault),
                        address(lender),
                        address(stablecoin)
                    )
                )
            )
        );
    }

    /// @dev Supply `amount` of collateral from `supplier` into the underwriter.
    function _fundUnderwriter(address underwriter, address supplier, uint256 amount) internal {
        _fundVault(supplier, amount);
        Underwriter(underwriter).whitelist(supplier, true);
        vm.startPrank(supplier);
        vault.setOperator(underwriter, true);
        Underwriter(underwriter).deposit(amount, supplier);
        vm.stopPrank();
    }
}
