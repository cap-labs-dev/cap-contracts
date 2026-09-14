// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";

import { BeaconFactory } from "../../../../contracts/cap/BeaconFactory.sol";
import { InterestRateModel } from "../../../../contracts/cap/InterestRateModel.sol";
import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../../../contracts/cap/Underwriter.sol";
import { Vault } from "../../../../contracts/cap/Vault.sol";
import { FixedMarket } from "../../../../contracts/cap/market/FixedMarket.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { ChainlinkAdapter } from "../../../../contracts/cap/oracle/ChainlinkAdapter.sol";
import { Oracle } from "../../../../contracts/cap/oracle/Oracle.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title CapDeployer6
/// @notice The stock {CapDeployer} world with a 6-decimal stablecoin underlying (real-USDC shape)
/// and 18-decimal collateral. Everything else (oracle + Chainlink adapter at 8 feed decimals,
/// registry, beacons, roles, market/underwriter helpers) is inherited unchanged.
/// @dev {CapDeployer-_deployCoreContracts} hard-codes `new MockERC20("USD Coin", "USDC", 18)` and
/// is not virtual, so the ~70 lines of core deployment are repeated here with the one change.
/// Tests that want the 18-dec world keep calling `_deployCap()` / `_deployCapWithConfig()`; tests
/// that want the 6-dec world call `_deployCap6()` / `_deployCap6WithConfig()`.
abstract contract CapDeployer6 is CapDeployer {
    uint8 internal constant UNDERLYING_DECIMALS = 6;
    uint256 internal constant ONE_USDC = 10 ** UNDERLYING_DECIMALS;
    /// @dev cUSD shares per underlying base unit (stablecoin is always 18 decimals)
    uint256 internal constant SHARES_PER_UNIT = 10 ** (18 - UNDERLYING_DECIMALS);

    function _deployCap6() internal {
        capConfig = _defaultCapConfig();
        _deployCap6WithConfig(capConfig);
    }

    function _deployCap6WithConfig(CapConfig memory cfg) internal {
        capConfig = cfg;
        defaultMarketOwner = address(this);
        defaultBorrower = makeAddr("borrower");
        defaultLiquidator = makeAddr("liquidator");

        _setUpAccessManager();
        _deployCoreContracts6();
        _deployRegistry();
        _configureAccess();
        _assignOperator(defaultMarketOwner);
        _assignOperator(defaultBorrower);

        _setPrice(address(collateral), capConfig.collateralPrice);
    }

    /// @dev Verbatim {CapDeployer-_deployCoreContracts} except for the underlying's decimals.
    function _deployCoreContracts6() internal {
        address authority = address(accessManager);

        oracle = Oracle(_deployProxy(address(new Oracle()), abi.encodeCall(Oracle.initialize, (authority))));
        bytes memory adapterCode = type(ChainlinkAdapter).creationCode;
        address adapter;
        assembly {
            adapter := create(0, add(adapterCode, 0x20), mload(adapterCode))
        }
        chainlinkAdapter = adapter;
        cusdUnderlying = new MockERC20("USD Coin", "USDC", UNDERLYING_DECIMALS);
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
                    Stablecoin.initialize, (authority, address(cusdUnderlying), "Cap USD", "cUSD", irmAddr, address(0))
                )
            )
        );

        require(address(irm) == irmAddr, "irm addr");
        require(address(stablecoin) == stablecoinAddr, "stablecoin addr");
        require(stablecoin.underlyingDecimals() == UNDERLYING_DECIMALS, "underlying decimals");

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
}
