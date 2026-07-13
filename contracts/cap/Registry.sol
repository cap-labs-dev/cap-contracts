// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IBeaconFactory } from "../interfaces/IBeaconFactory.sol";
import { IMarket } from "../interfaces/IMarket.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { RegistryStorageUtils } from "../storage/RegistryStorageUtils.sol";
import { Market } from "./Market.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title Registry
/// @author kexley
/// @notice Deploy and initialize beacon proxies
contract Registry is IRegistry, AccessManagedUpgradeable, RegistryStorageUtils, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint64 internal constant KEEPER_ROLE = 1;
    uint64 internal constant GUARDIAN_ROLE = 2;
    uint64 internal constant MINTER_ROLE = 3;

    /// @inheritdoc IRegistry
    function initialize(
        address _authority,
        address _stablecoin,
        address _stablecoinYield,
        address _vault,
        address _oracle,
        address _irm,
        address _marketFactory,
        address _trancheFactory,
        address _underwriterFactory
    ) external initializer {
        __AccessManaged_init(_authority);
        Storage storage $ = getRegistryStorage();
        $.vault = _vault;
        $.stablecoin = _stablecoin;
        $.stablecoinYield = _stablecoinYield;
        $.oracle = _oracle;
        $.irm = _irm;
        $.marketFactory = _marketFactory;
        $.trancheFactory = _trancheFactory;
        $.underwriterFactory = _underwriterFactory;
    }

    /// @inheritdoc IRegistry
    function createMarket(address _asset, string memory _name, uint64 _managerId, uint64 _borrowerId)
        external
        restricted
        returns (address market, address seniorTranche, address juniorTranche)
    {
        Storage storage $ = getRegistryStorage();

        market = IBeaconFactory($.marketFactory)
            .create(
                abi.encodeCall(
                    Market.initialize,
                    (
                        authority(),
                        _asset,
                        _name,
                        $.multiplier[_asset],
                        $.irm,
                        $.stablecoin,
                        $.stablecoinYield,
                        $.vault,
                        $.oracle
                    )
                )
            );
        $.markets.add(market);

        string memory seniorName = string.concat(_name, " Senior Tranche");
        string memory juniorName = string.concat(_name, " Junior Tranche");
        seniorTranche = IBeaconFactory($.trancheFactory)
            .create(
                abi.encodeCall(
                    ITranche.initialize,
                    (authority(), _asset, seniorName, "srTRANCHE", market, $.vault, $.irm, $.stablecoin)
                )
            );
        $.tranches.add(seniorTranche);
        juniorTranche = IBeaconFactory($.trancheFactory)
            .create(
                abi.encodeCall(
                    ITranche.initialize,
                    (authority(), _asset, juniorName, "jrTRANCHE", market, $.vault, $.irm, $.stablecoin)
                )
            );
        $.tranches.add(juniorTranche);

        _configureMarketRoles(market, _managerId, _borrowerId);
        _configureTrancheRoles(seniorTranche, _managerId);
        _configureTrancheRoles(juniorTranche, _managerId);

        IMarket(market).setSeniorTranche(seniorTranche);
        IMarket(market).setJuniorTranche(juniorTranche);

        emit CreateMarket(market, _asset, _name, _managerId, seniorTranche, juniorTranche);
    }

    /// @inheritdoc IRegistry
    function createUnderwriter(address _asset, string memory _name, string memory _symbol, uint64 _managerId)
        external
        restricted
        returns (address underwriter)
    {
        Storage storage $ = getRegistryStorage();

        underwriter = IBeaconFactory($.underwriterFactory)
            .create(
                abi.encodeCall(
                    IUnderwriter.initialize, (authority(), _name, _symbol, _asset, $.vault, address(this), $.stablecoin)
                )
            );
        $.underwriters.add(underwriter);

        _configureUnderwriterRoles(underwriter, _managerId);

        emit CreateUnderwriter(underwriter, _asset, _name, _symbol, _managerId);
    }

    /// @inheritdoc IRegistry
    function isMarket(address _market) external view returns (bool) {
        return getRegistryStorage().markets.contains(_market);
    }

    /// @inheritdoc IRegistry
    function markets(uint256 start, uint256 end) external view returns (address[] memory) {
        return getRegistryStorage().markets.values(start, end);
    }

    /// @inheritdoc IRegistry
    function marketsLength() external view returns (uint256) {
        return getRegistryStorage().markets.length();
    }

    /// @inheritdoc IRegistry
    function isTranche(address _tranche) external view returns (bool) {
        return getRegistryStorage().tranches.contains(_tranche);
    }

    /// @inheritdoc IRegistry
    function tranches(uint256 start, uint256 end) external view returns (address[] memory) {
        return getRegistryStorage().tranches.values(start, end);
    }

    /// @inheritdoc IRegistry
    function tranchesLength() external view returns (uint256) {
        return getRegistryStorage().tranches.length();
    }

    /// @inheritdoc IRegistry
    function isUnderwriter(address _underwriter) external view returns (bool) {
        return getRegistryStorage().underwriters.contains(_underwriter);
    }

    /// @inheritdoc IRegistry
    function underwriters(uint256 start, uint256 end) external view returns (address[] memory) {
        return getRegistryStorage().underwriters.values(start, end);
    }

    /// @inheritdoc IRegistry
    function underwritersLength() external view returns (uint256) {
        return getRegistryStorage().underwriters.length();
    }

    function _configureMarketRoles(address market, uint64 managerId, uint64 borrowerId) internal {
        Storage storage $ = getRegistryStorage();

        bytes4[] memory selectors = new bytes4[](2);
        selectors[1] = IMarket.setJuniorSplit.selector;
        selectors[3] = IMarket.setLtv.selector;
        IAccessManager(authority()).setTargetFunctionRole(market, selectors, managerId);

        selectors = new bytes4[](1);
        selectors[0] = IMarket.borrow.selector;
        IAccessManager(authority()).setTargetFunctionRole(market, selectors, borrowerId);

        selectors = new bytes4[](12);
        selectors[0] = IMarket.setSeniorTranche.selector;
        selectors[1] = IMarket.setJuniorTranche.selector;
        selectors[3] = IMarket.setMultiplier.selector;
        selectors[4] = IMarket.setBorrowCap.selector;
        selectors[5] = IMarket.setOracle.selector;
        selectors[6] = IMarket.setTargetHealth.selector;
        selectors[7] = IMarket.setBonusConfig.selector;
        selectors[8] = IMarket.setStablecoinYield.selector;
        selectors[9] = IMarket.setBuffer.selector;
        selectors[10] = IMarket.setLt.selector;
        selectors[11] = IMarket.setInterestType.selector;
        IAccessManager(authority()).setTargetFunctionRole(market, selectors, GUARDIAN_ROLE);

        IAccessManager(authority()).grantRole(MINTER_ROLE, market, 0);
    }

    function _configureTrancheRoles(address tranche, uint64 managerId) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ITranche.setWhitelist.selector;
        IAccessManager(authority()).setTargetFunctionRole(tranche, selectors, managerId);
    }

    function _configureUnderwriterRoles(address underwriter, uint64 managerId) internal {
        Storage storage $ = getRegistryStorage();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = IUnderwriter.allocate.selector;
        selectors[1] = IUnderwriter.deallocate.selector;
        selectors[2] = IUnderwriter.finalizeDeallocateAsync.selector;
        selectors[3] = IUnderwriter.setDefaultTranche.selector;
        selectors[4] = IUnderwriter.whitelist.selector;
        selectors[5] = IUnderwriter.setVestingPeriod.selector;
        IAccessManager(authority()).setTargetFunctionRole(underwriter, selectors, managerId);

        selectors = new bytes4[](1);
        selectors[0] = IUnderwriter.report.selector;
        IAccessManager(authority()).setTargetFunctionRole(underwriter, selectors, KEEPER_ROLE);
    }

    function _authorizeUpgrade(address) internal override restricted { }
}
