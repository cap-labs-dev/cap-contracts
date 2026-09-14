// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IAccessManager } from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import { IBaseMarket } from "../interfaces/IBaseMarket.sol";
import { IBeaconFactory } from "../interfaces/IBeaconFactory.sol";
import { IFixedMarket } from "../interfaces/IFixedMarket.sol";
import { IFloatingMarket } from "../interfaces/IFloatingMarket.sol";
import { IInterestRateModel } from "../interfaces/IInterestRateModel.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";
import { IStablecoin } from "../interfaces/IStablecoin.sol";
import { ITranche } from "../interfaces/ITranche.sol";
import { IUnderwriter } from "../interfaces/IUnderwriter.sol";
import { CapRoles } from "../utils/CapRoles.sol";
import { FixedMarket } from "./market/FixedMarket.sol";
import { FloatingMarket } from "./market/FloatingMarket.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { UpgradeableBeacon } from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @title Registry
/// @author kexley, Cap Labs
/// @notice Deploys markets and underwriters and wires AccessManager roles
/// @dev This contract must hold ADMIN: `setTargetFunctionRole` cannot be delegated.
contract Registry layout at erc7201("cap.storage.Registry") is IRegistry, AccessManagedUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @inheritdoc IRegistry
    address public vault;

    /// @inheritdoc IRegistry
    address public stablecoin;

    /// @inheritdoc IRegistry
    address public oracle;

    /// @inheritdoc IRegistry
    address public irm;

    /// @inheritdoc IRegistry
    address public factory;

    /// @inheritdoc IRegistry
    address public floatingMarketBeacon;

    /// @inheritdoc IRegistry
    address public fixedMarketBeacon;

    /// @inheritdoc IRegistry
    address public trancheBeacon;

    /// @inheritdoc IRegistry
    address public underwriterBeacon;

    /// @inheritdoc IRegistry
    uint256 public lt;

    /// @inheritdoc IRegistry
    uint256 public buffer;

    /// @inheritdoc IRegistry
    uint256 public targetHealth;

    /// @inheritdoc IRegistry
    mapping(address market => bool deployed) public isMarket;

    /// @inheritdoc IRegistry
    mapping(uint64 roleId => bool assigned) public isOperatorRole;

    /// @dev Next operator role id to assign
    uint64 private _nextOperatorRoleId;

    /// @dev Deployments per market, used to name tranche suffixes. Only ever increases.
    mapping(address market => uint256 count) private _trancheCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRegistry
    function initialize(address _authority, IRegistry.InitParams calldata init) external initializer {
        __AccessManaged_init(_authority);
        if (
            init.vault == address(0) || init.stablecoin == address(0) || init.oracle == address(0)
                || init.irm == address(0) || init.factory == address(0) || init.floatingMarketBeacon == address(0)
                || init.fixedMarketBeacon == address(0) || init.trancheBeacon == address(0)
                || init.underwriterBeacon == address(0)
        ) revert ZeroAddress();
        vault = init.vault;
        stablecoin = init.stablecoin;
        oracle = init.oracle;
        irm = init.irm;
        factory = init.factory;
        floatingMarketBeacon = init.floatingMarketBeacon;
        fixedMarketBeacon = init.fixedMarketBeacon;
        trancheBeacon = init.trancheBeacon;
        underwriterBeacon = init.underwriterBeacon;
        if (init.lt > 1e27 || init.lt <= init.buffer) revert IBaseMarket.InvalidLt();
        if (init.targetHealth < 1.25e27) revert IBaseMarket.InvalidTargetHealth();
        lt = init.lt;
        buffer = init.buffer;
        targetHealth = init.targetHealth;
        _nextOperatorRoleId = CapRoles.FIRST_OPERATOR_ROLE;
        _configureInfraRoles();
    }

    /// @inheritdoc IRegistry
    function createChildRoles(uint64 parentRoleId, address[][] calldata members)
        external
        restricted
        returns (uint64[] memory roleIds)
    {
        if (parentRoleId == type(uint64).max) revert PublicRole();
        IAccessManager manager = IAccessManager(authority());
        roleIds = new uint64[](members.length);
        for (uint256 i; i < members.length; ++i) {
            roleIds[i] = _nextOperatorRoleId++;
            for (uint256 j; j < members[i].length; ++j) {
                if (members[i][j] == address(0)) revert ZeroAddress();
                manager.grantRole(roleIds[i], members[i][j], 0);
            }
            manager.setRoleAdmin(roleIds[i], parentRoleId);
            isOperatorRole[roleIds[i]] = true;
        }
        emit CreateChildRoles(parentRoleId, members, roleIds);
    }

    /// @inheritdoc IRegistry
    function createFloatingMarket(
        address[] calldata _assets,
        uint256[] calldata _weights,
        string memory _name,
        uint64 _marketOwnerRole
    ) external restricted returns (address market, address[] memory deployedTranches) {
        (market, deployedTranches) = _createMarket(
            floatingMarketBeacon,
            abi.encodeCall(FloatingMarket.initialize, (authority(), address(this), _name)),
            _assets,
            _weights,
            _name,
            _marketOwnerRole
        );
    }

    /// @inheritdoc IRegistry
    function createFixedMarket(
        address[] calldata _assets,
        uint256[] calldata _weights,
        string memory _name,
        uint64 _marketOwnerRole,
        uint256 _maximumTermLimit,
        uint256 _minimumTermLimit,
        uint256 _grace
    ) external restricted returns (address market, address[] memory deployedTranches) {
        (market, deployedTranches) = _createMarket(
            fixedMarketBeacon,
            abi.encodeCall(
                FixedMarket.initialize,
                (authority(), address(this), _name, _maximumTermLimit, _minimumTermLimit, _grace)
            ),
            _assets,
            _weights,
            _name,
            _marketOwnerRole
        );
    }

    /// @inheritdoc IRegistry
    function createTranche(address _market, address _asset, uint256[] calldata _weights)
        external
        returns (address tranche)
    {
        if (!isMarket[_market]) revert UnknownMarket();
        uint64 ownerRole = marketOwnerRole(_market);
        (bool isOwner,) = IAccessManager(authority()).hasRole(ownerRole, msg.sender);
        if (!isOwner) revert NotMarketOwner();

        IBaseMarket.Tranche[] memory existing = IBaseMarket(_market).tranches();
        if (_weights.length != existing.length + 1) revert InvalidTrancheCount();

        tranche = _deployTranche(_asset, IBaseMarket(_market).name(), _market, ownerRole, _trancheCount[_market]++);

        IBaseMarket.Tranche[] memory updated = new IBaseMarket.Tranche[](_weights.length);
        for (uint256 i; i < existing.length; ++i) {
            updated[i] = IBaseMarket.Tranche({ tranche: existing[i].tranche, weight: _weights[i] });
        }
        updated[existing.length] = IBaseMarket.Tranche({ tranche: tranche, weight: _weights[existing.length] });

        // reverts unless the weights still total one ray and the market stays healthy
        IBaseMarket(_market).setTranches(updated);
    }

    /// @inheritdoc IRegistry
    function setDepositorRole(uint64 roleId) external restricted {
        IAccessManager manager = IAccessManager(authority());
        bytes4[] memory depositorSelectors = new bytes4[](2);
        depositorSelectors[0] = IERC4626.deposit.selector;
        depositorSelectors[1] = IERC4626.mint.selector;

        manager.setTargetFunctionRole(msg.sender, depositorSelectors, roleId);
        emit SetDepositorRole(msg.sender, roleId);
    }

    /// @inheritdoc IRegistry
    function setBorrowerRole(uint64 roleId) external restricted {
        if (roleId == type(uint64).max) revert PublicRole();
        if (!isOperatorRole[roleId]) revert NotOperatorRole();

        IAccessManager manager = IAccessManager(authority());
        bytes4[] memory borrowerSelectors = new bytes4[](4);
        borrowerSelectors[0] = IFloatingMarket.borrow.selector;
        borrowerSelectors[1] = IFixedMarket.borrow.selector;
        borrowerSelectors[2] = IFixedMarket.borrowMore.selector;
        borrowerSelectors[3] = IFixedMarket.extend.selector;

        manager.setTargetFunctionRole(msg.sender, borrowerSelectors, roleId);
        emit SetBorrowerRole(msg.sender, roleId);
    }

    /// @inheritdoc IRegistry
    function setAllocatorRole(uint64 roleId) external restricted {
        if (roleId == type(uint64).max) revert PublicRole();
        if (!isOperatorRole[roleId]) revert NotOperatorRole();
        IAccessManager manager = IAccessManager(authority());
        bytes4[] memory allocatorSelectors = new bytes4[](5);
        allocatorSelectors[0] = IUnderwriter.allocate.selector;
        allocatorSelectors[1] = IUnderwriter.deallocate.selector;
        allocatorSelectors[2] = IUnderwriter.deallocateAsync.selector;
        allocatorSelectors[3] = IUnderwriter.finalizeDeallocateAsync.selector;
        allocatorSelectors[4] = IUnderwriter.setDefaultTranche.selector;

        manager.setTargetFunctionRole(msg.sender, allocatorSelectors, roleId);
        emit SetAllocatorRole(msg.sender, roleId);
    }

    /// @inheritdoc IRegistry
    function createUnderwriter(address _asset, string memory _name, string memory _symbol, uint64 _curatorRole)
        external
        restricted
        returns (address underwriter)
    {
        if (!isOperatorRole[_curatorRole]) {
            revert OperatorNotAssigned();
        }

        underwriter = _deploy(
            underwriterBeacon,
            abi.encodeCall(
                IUnderwriter.initialize, (authority(), address(this), _name, _symbol, _asset, vault, stablecoin)
            )
        );

        _configureUnderwriterRoles(underwriter, _curatorRole);

        emit CreateUnderwriter(underwriter, _asset, _name, _symbol, _curatorRole);
    }

    /// @inheritdoc IRegistry
    function marketOwnerRole(address _market) public view returns (uint64 roleId) {
        // Live from the AccessManager, so rehoming owner selectors moves this too.
        if (!isMarket[_market]) return 0;
        roleId = IAccessManager(authority()).getTargetFunctionRole(_market, IBaseMarket.setLtv.selector);
    }

    /// @dev Deploy a market with tranches and wire AccessManager roles
    /// @param beacon The market implementation beacon
    /// @param marketInitData The encoded market initializer call
    /// @param _assets The asset of each tranche, index 0 is most senior
    /// @param _weights Tranche weights in ray decimals, index 0 is most senior
    /// @param _name The market name
    /// @param _marketOwnerRole The market owner operator role id
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function _createMarket(
        address beacon,
        bytes memory marketInitData,
        address[] calldata _assets,
        uint256[] calldata _weights,
        string memory _name,
        uint64 _marketOwnerRole
    ) internal returns (address market, address[] memory deployedTranches) {
        if (_assets.length == 0) revert InvalidTrancheCount();
        if (_assets.length != _weights.length) revert TrancheAssetsMismatch();
        if (!isOperatorRole[_marketOwnerRole]) revert OperatorNotAssigned();

        market = _deploy(beacon, marketInitData);
        isMarket[market] = true;
        _trancheCount[market] = _assets.length;

        deployedTranches = new address[](_assets.length);
        IBaseMarket.Tranche[] memory marketTranches = new IBaseMarket.Tranche[](_assets.length);

        for (uint256 i; i < _assets.length; ++i) {
            address tranche = _deployTranche(_assets[i], _name, market, _marketOwnerRole, i);
            deployedTranches[i] = tranche;
            marketTranches[i] = IBaseMarket.Tranche({ tranche: tranche, weight: _weights[i] });
        }

        _configureMarketRoles(market, _marketOwnerRole);
        IBaseMarket(market).setTranches(marketTranches);

        emit CreateMarket(market, _assets, _name, _marketOwnerRole, deployedTranches);
    }

    /// @dev Deploy and register a tranche for a market
    /// @param _asset The tranche asset
    /// @param _name The market name, used to build the tranche name
    /// @param market The market the tranche underwrites
    /// @param ownerRole The market owner role that will administer depositors
    /// @param index The tranche's seniority index
    /// @return tranche The deployed tranche
    function _deployTranche(address _asset, string memory _name, address market, uint64 ownerRole, uint256 index)
        internal
        returns (address tranche)
    {
        if (IOracle(oracle).price(_asset) == 0) revert IOracle.PriceError(_asset);

        string memory trancheName = string.concat(_name, " Tranche ", Strings.toString(index));
        string memory trancheSymbol = string.concat("TR", Strings.toString(index));
        tranche = _deploy(
            trancheBeacon,
            abi.encodeCall(
                ITranche.initialize,
                (authority(), address(this), _asset, trancheName, trancheSymbol, market, vault, oracle)
            )
        );

        uint64 depositorRoleId = _nextOperatorRoleId++;
        _configureTrancheRoles(tranche, ownerRole, depositorRoleId);

        emit CreateTranche(market, tranche, _asset, ownerRole, depositorRoleId);
    }

    /// @dev Deploy a beacon proxy through the shared factory
    /// @param beacon The implementation beacon
    /// @param initData The encoded initializer call
    /// @return instance The deployed proxy
    function _deploy(address beacon, bytes memory initData) internal returns (address instance) {
        instance = IBeaconFactory(factory).create(beacon, initData);
    }

    /// @dev Wire shared-infrastructure selectors. This contract must hold ADMIN.
    function _configureInfraRoles() internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory factorySelectors = new bytes4[](1);
        factorySelectors[0] = IBeaconFactory.create.selector;
        manager.setTargetFunctionRole(factory, factorySelectors, CapRoles.REGISTRY);

        bytes4[] memory registryWhitelistedSelectors = new bytes4[](4);
        registryWhitelistedSelectors[0] = IRegistry.createChildRoles.selector;
        registryWhitelistedSelectors[1] = IRegistry.createFloatingMarket.selector;
        registryWhitelistedSelectors[2] = IRegistry.createFixedMarket.selector;
        registryWhitelistedSelectors[3] = IRegistry.createUnderwriter.selector;
        manager.setTargetFunctionRole(address(this), registryWhitelistedSelectors, CapRoles.WHITELISTED);

        bytes4[] memory registryProtocolSelectors = new bytes4[](3);
        registryProtocolSelectors[0] = IRegistry.setDepositorRole.selector;
        registryProtocolSelectors[1] = IRegistry.setBorrowerRole.selector;
        registryProtocolSelectors[2] = IRegistry.setAllocatorRole.selector;
        manager.setTargetFunctionRole(address(this), registryProtocolSelectors, CapRoles.PROTOCOL);

        // mint, burn, credit write-off, and credit-backed premium — markets only
        bytes4[] memory marketSelectors = new bytes4[](4);
        marketSelectors[0] = IStablecoin.mintCreditBacked.selector;
        marketSelectors[1] = IStablecoin.burnCreditBacked.selector;
        marketSelectors[2] = IStablecoin.recognizeBadDebtInCredit.selector;
        marketSelectors[3] = IStablecoin.fundCreditBacked.selector;
        manager.setTargetFunctionRole(stablecoin, marketSelectors, CapRoles.MARKET);

        // reserve losses are exceptional and must be recognized by the guardian
        bytes4[] memory stablecoinGuardianSelectors = new bytes4[](3);
        stablecoinGuardianSelectors[0] = IStablecoin.recognizeBadDebtInReserve.selector;
        stablecoinGuardianSelectors[1] = IStablecoin.pause.selector;
        stablecoinGuardianSelectors[2] = IStablecoin.unpause.selector;
        manager.setTargetFunctionRole(stablecoin, stablecoinGuardianSelectors, CapRoles.GUARDIAN);

        // parking reserve is keeper work
        bytes4[] memory stablecoinKeeperSelectors = new bytes4[](2);
        stablecoinKeeperSelectors[0] = IStablecoin.invest.selector;
        stablecoinKeeperSelectors[1] = IStablecoin.recall.selector;
        manager.setTargetFunctionRole(stablecoin, stablecoinKeeperSelectors, CapRoles.KEEPER);

        bytes4[] memory stablecoinGovernorSelectors = new bytes4[](1);
        stablecoinGovernorSelectors[0] = IStablecoin.setReserveVault.selector;
        manager.setTargetFunctionRole(stablecoin, stablecoinGovernorSelectors, CapRoles.GOVERNOR);

        bytes4[] memory irmMarketSelectors = new bytes4[](1);
        irmMarketSelectors[0] = IInterestRateModel.updateUnderwriterRate.selector;
        manager.setTargetFunctionRole(irm, irmMarketSelectors, CapRoles.MARKET);

        bytes4[] memory irmGovernorSelectors = new bytes4[](4);
        irmGovernorSelectors[0] = IInterestRateModel.setLiquiditySlopes.selector;
        irmGovernorSelectors[1] = IInterestRateModel.setTermMultiplierSlope.selector;
        irmGovernorSelectors[2] = IInterestRateModel.setLiquidationBonus.selector;
        irmGovernorSelectors[3] = IInterestRateModel.setAveragingPeriod.selector;
        manager.setTargetFunctionRole(irm, irmGovernorSelectors, CapRoles.GOVERNOR);

        // feeds are economic policy, same as the rate curve
        bytes4[] memory oracleGovernorSelectors = new bytes4[](1);
        oracleGovernorSelectors[0] = IOracle.setSource.selector;
        manager.setTargetFunctionRole(oracle, oracleGovernorSelectors, CapRoles.GOVERNOR);

        // beacons are Ownable; the manager is the owner, so ADMIN upgrades via execute
        bytes4[] memory beaconSelectors = new bytes4[](1);
        beaconSelectors[0] = UpgradeableBeacon.upgradeTo.selector;
        manager.setTargetFunctionRole(floatingMarketBeacon, beaconSelectors, CapRoles.ADMIN);
        manager.setTargetFunctionRole(fixedMarketBeacon, beaconSelectors, CapRoles.ADMIN);
        manager.setTargetFunctionRole(trancheBeacon, beaconSelectors, CapRoles.ADMIN);
        manager.setTargetFunctionRole(underwriterBeacon, beaconSelectors, CapRoles.ADMIN);
    }

    /// @dev Wire market function selectors to protocol and operator roles
    /// @param market The market to configure
    /// @param ownerRole The operator role that owns the market
    function _configureMarketRoles(address market, uint64 ownerRole) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory ownerSelectors = new bytes4[](7);
        ownerSelectors[0] = IBaseMarket.setTrancheWeights.selector;
        ownerSelectors[1] = IBaseMarket.setLtv.selector;
        ownerSelectors[2] = IBaseMarket.setMarketMultiplier.selector;
        ownerSelectors[3] = IFixedMarket.extend.selector;
        ownerSelectors[4] = IBaseMarket.setUnderwriterRate.selector;
        ownerSelectors[5] = IBaseMarket.setBorrowerRole.selector;
        ownerSelectors[6] = IBaseMarket.setDepositorRole.selector;
        manager.setTargetFunctionRole(market, ownerSelectors, ownerRole);

        bytes4[] memory registrySelectors = new bytes4[](1);
        registrySelectors[0] = IBaseMarket.setTranches.selector;
        manager.setTargetFunctionRole(market, registrySelectors, CapRoles.REGISTRY);

        bytes4[] memory governorSelectors = new bytes4[](2);
        governorSelectors[0] = IBaseMarket.setTargetHealth.selector;
        governorSelectors[1] = IFixedMarket.setTermLimits.selector;
        manager.setTargetFunctionRole(market, governorSelectors, CapRoles.GOVERNOR);

        bytes4[] memory guardianSelectors = new bytes4[](4);
        guardianSelectors[0] = IBaseMarket.setBuffer.selector;
        guardianSelectors[1] = IBaseMarket.setLt.selector;
        // write-off recognises a loss
        guardianSelectors[2] = IFloatingMarket.writeOff.selector;
        guardianSelectors[3] = IFixedMarket.writeOff.selector;
        manager.setTargetFunctionRole(market, guardianSelectors, CapRoles.GUARDIAN);

        bytes4[] memory keeperSelectors = new bytes4[](1);
        keeperSelectors[0] = IFixedMarket.extendAdmin.selector;
        manager.setTargetFunctionRole(market, keeperSelectors, CapRoles.KEEPER);

        bytes4[] memory liquidatorSelectors = new bytes4[](2);
        liquidatorSelectors[0] = IFloatingMarket.liquidate.selector;
        liquidatorSelectors[1] = IFixedMarket.liquidate.selector;
        manager.setTargetFunctionRole(market, liquidatorSelectors, CapRoles.LIQUIDATOR);

        manager.grantRole(CapRoles.MARKET, market, 0);
        manager.grantRole(CapRoles.PROTOCOL, market, 0);
    }

    /// @dev Wire tranche function selectors to the market owner, market and depositor roles
    /// @param tranche The tranche to configure
    /// @param ownerRole The market owner role that administers depositors
    /// @param depositorRoleId The role whose members may deposit
    function _configureTrancheRoles(address tranche, uint64 ownerRole, uint64 depositorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory ownerSelectors = new bytes4[](1);
        ownerSelectors[0] = ITranche.setDepositorRole.selector;
        manager.setTargetFunctionRole(tranche, ownerSelectors, ownerRole);

        bytes4[] memory governorSelectors = new bytes4[](1);
        governorSelectors[0] = ITranche.setFixedCreditLimit.selector;
        manager.setTargetFunctionRole(tranche, governorSelectors, CapRoles.GOVERNOR);

        // premium is pushed by the market that charged it. slash is gated on `msg.sender == market`
        bytes4[] memory marketSelectors = new bytes4[](1);
        marketSelectors[0] = ITranche.fund.selector;
        manager.setTargetFunctionRole(tranche, marketSelectors, CapRoles.MARKET);

        // depositor role is the whitelist for entry into the tranche
        bytes4[] memory depositorSelectors = new bytes4[](2);
        depositorSelectors[0] = IERC4626.deposit.selector;
        depositorSelectors[1] = IERC4626.mint.selector;
        manager.setTargetFunctionRole(tranche, depositorSelectors, depositorRoleId);

        // depositor role is administered by the market owner
        manager.setRoleAdmin(depositorRoleId, ownerRole);
        manager.grantRole(CapRoles.PROTOCOL, tranche, 0);
    }

    /// @dev Wire underwriter function selectors to the curator and keeper roles
    /// @param underwriter The underwriter to configure
    /// @param curatorRoleId The curator operator role
    function _configureUnderwriterRoles(address underwriter, uint64 curatorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory curatorSelectors = new bytes4[](4);
        curatorSelectors[0] = IUnderwriter.addTranche.selector;
        curatorSelectors[1] = IUnderwriter.removeTranche.selector;
        curatorSelectors[2] = IUnderwriter.setDepositorRole.selector;
        curatorSelectors[3] = IUnderwriter.setAllocatorRole.selector;
        manager.setTargetFunctionRole(underwriter, curatorSelectors, curatorRoleId);

        bytes4[] memory keeperSelectors = new bytes4[](1);
        keeperSelectors[0] = IUnderwriter.report.selector;
        manager.setTargetFunctionRole(underwriter, keeperSelectors, CapRoles.KEEPER);

        manager.grantRole(CapRoles.PROTOCOL, underwriter, 0);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
