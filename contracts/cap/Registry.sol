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
    address public wrapper;

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
                || init.underwriterBeacon == address(0) || init.wrapper == address(0)
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
        wrapper = init.wrapper;
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
        manager.setTargetFunctionRole(msg.sender, _depositorSelectors(), roleId);
        emit SetDepositorRole(msg.sender, roleId);
    }

    /// @inheritdoc IRegistry
    function setBorrowerRole(uint64 roleId) external restricted {
        if (roleId == type(uint64).max) revert PublicRole();
        if (!isOperatorRole[roleId]) revert NotOperatorRole();

        IAccessManager manager = IAccessManager(authority());
        manager.setTargetFunctionRole(msg.sender, _borrowerSelectors(), roleId);
        emit SetBorrowerRole(msg.sender, roleId);
    }

    /// @inheritdoc IRegistry
    function setAllocatorRole(uint64 roleId) external restricted {
        if (roleId == type(uint64).max) revert PublicRole();
        if (!isOperatorRole[roleId]) revert NotOperatorRole();
        IAccessManager manager = IAccessManager(authority());
        manager.setTargetFunctionRole(msg.sender, _allocatorSelectors(), roleId);
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

        uint64 depositorRoleId = _newClosedRole(IAccessManager(authority()), ownerRole);
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
    /// Every UUPS `upgradeToAndCall` is named here so it cannot sit at ADMIN by omission.
    function _configureInfraRoles() internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory upgrades = _upgradeSelectors();
        manager.setTargetFunctionRole(address(this), upgrades, CapRoles.ADMIN);
        manager.setTargetFunctionRole(stablecoin, upgrades, CapRoles.ADMIN);
        manager.setTargetFunctionRole(vault, upgrades, CapRoles.ADMIN);
        manager.setTargetFunctionRole(oracle, upgrades, CapRoles.ADMIN);
        manager.setTargetFunctionRole(irm, upgrades, CapRoles.ADMIN);
        manager.setTargetFunctionRole(factory, upgrades, CapRoles.ADMIN);
        manager.setTargetFunctionRole(wrapper, upgrades, CapRoles.ADMIN);

        manager.setTargetFunctionRole(factory, _factorySelectors(), CapRoles.REGISTRY);
        manager.setTargetFunctionRole(address(this), _registryWhitelistedSelectors(), CapRoles.WHITELISTED);
        manager.setTargetFunctionRole(address(this), _registryProtocolSelectors(), CapRoles.PROTOCOL);

        manager.setTargetFunctionRole(stablecoin, _stablecoinMarketSelectors(), CapRoles.MARKET);
        manager.setTargetFunctionRole(stablecoin, _stablecoinGuardianSelectors(), CapRoles.GUARDIAN);
        manager.setTargetFunctionRole(stablecoin, _stablecoinKeeperSelectors(), CapRoles.KEEPER);
        manager.setTargetFunctionRole(stablecoin, _stablecoinGovernorSelectors(), CapRoles.GOVERNOR);

        manager.setTargetFunctionRole(irm, _irmMarketSelectors(), CapRoles.MARKET);
        manager.setTargetFunctionRole(irm, _irmGovernorSelectors(), CapRoles.GOVERNOR);
        manager.setTargetFunctionRole(oracle, _oracleGovernorSelectors(), CapRoles.GOVERNOR);
    }

    /// @dev Wire market function selectors to protocol and operator roles
    /// @param market The market to configure
    /// @param ownerRole The operator role that owns the market
    function _configureMarketRoles(address market, uint64 ownerRole) internal {
        IAccessManager manager = IAccessManager(authority());

        manager.setTargetFunctionRole(market, _marketOwnerSelectors(), ownerRole);

        // borrow / borrowMore / extend used to sit unwired until {setBorrowerRole}, which
        // AccessManager reports as ADMIN. A closed role the owner administers is the same
        // pattern as the tranche depositor role: nobody can draw until they are admitted.
        manager.setTargetFunctionRole(market, _borrowerSelectors(), _newClosedRole(manager, ownerRole));

        manager.setTargetFunctionRole(market, _marketRegistrySelectors(), CapRoles.REGISTRY);
        manager.setTargetFunctionRole(market, _marketGovernorSelectors(), CapRoles.GOVERNOR);
        manager.setTargetFunctionRole(market, _marketGuardianSelectors(), CapRoles.GUARDIAN);
        manager.setTargetFunctionRole(market, _marketKeeperSelectors(), CapRoles.KEEPER);
        manager.setTargetFunctionRole(market, _marketLiquidatorSelectors(), CapRoles.LIQUIDATOR);

        manager.grantRole(CapRoles.MARKET, market, 0);
        manager.grantRole(CapRoles.PROTOCOL, market, 0);
    }

    /// @dev Wire tranche function selectors to the market owner, market and depositor roles
    /// @param tranche The tranche to configure
    /// @param ownerRole The market owner role that administers depositors
    /// @param depositorRoleId The role whose members may deposit
    function _configureTrancheRoles(address tranche, uint64 ownerRole, uint64 depositorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

        manager.setTargetFunctionRole(tranche, _trancheOwnerSelectors(), ownerRole);
        manager.setTargetFunctionRole(tranche, _trancheGovernorSelectors(), CapRoles.GOVERNOR);
        manager.setTargetFunctionRole(tranche, _trancheMarketSelectors(), CapRoles.MARKET);
        manager.setTargetFunctionRole(tranche, _depositorSelectors(), depositorRoleId);
        manager.grantRole(CapRoles.PROTOCOL, tranche, 0);
    }

    /// @dev Wire underwriter function selectors to the curator and keeper roles
    /// @param underwriter The underwriter to configure
    /// @param curatorRoleId The curator operator role
    function _configureUnderwriterRoles(address underwriter, uint64 curatorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

        manager.setTargetFunctionRole(underwriter, _underwriterCuratorSelectors(), curatorRoleId);
        manager.setTargetFunctionRole(underwriter, _underwriterKeeperSelectors(), CapRoles.KEEPER);

        // the seven capital-moving selectors used to sit unwired until {setAllocatorRole} /
        // {setDepositorRole}. Closed roles the curator administers close that ADMIN window.
        manager.setTargetFunctionRole(underwriter, _allocatorSelectors(), _newClosedRole(manager, curatorRoleId));
        manager.setTargetFunctionRole(underwriter, _depositorSelectors(), _newClosedRole(manager, curatorRoleId));

        manager.grantRole(CapRoles.PROTOCOL, underwriter, 0);
    }

    /// @dev A fresh operator role with no members. Same list {createChildRoles} writes, so a
    /// depositor or borrower role minted at create can later be named as an owner, borrower, or
    /// allocator.
    /// @param manager The access manager
    /// @param adminRole The role that will administer the new role
    /// @return roleId The new role id
    function _newClosedRole(IAccessManager manager, uint64 adminRole) internal returns (uint64 roleId) {
        roleId = _nextOperatorRoleId++;
        manager.setRoleAdmin(roleId, adminRole);
        isOperatorRole[roleId] = true;
    }

    function _upgradeSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(UUPSUpgradeable.upgradeToAndCall.selector);
    }

    function _factorySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(IBeaconFactory.create.selector);
    }

    function _registryWhitelistedSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IRegistry.createChildRoles.selector;
        selectors[1] = IRegistry.createFloatingMarket.selector;
        selectors[2] = IRegistry.createFixedMarket.selector;
        selectors[3] = IRegistry.createUnderwriter.selector;
    }

    function _registryProtocolSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IRegistry.setDepositorRole.selector;
        selectors[1] = IRegistry.setBorrowerRole.selector;
        selectors[2] = IRegistry.setAllocatorRole.selector;
    }

    function _stablecoinMarketSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IStablecoin.mintCreditBacked.selector;
        selectors[1] = IStablecoin.burnCreditBacked.selector;
        selectors[2] = IStablecoin.recognizeBadDebtInCredit.selector;
        selectors[3] = IStablecoin.fundCreditBacked.selector;
    }

    function _stablecoinGuardianSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](3);
        selectors[0] = IStablecoin.recognizeBadDebtInReserve.selector;
        selectors[1] = IStablecoin.pause.selector;
        selectors[2] = IStablecoin.unpause.selector;
    }

    function _stablecoinKeeperSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IStablecoin.invest.selector;
        selectors[1] = IStablecoin.recall.selector;
    }

    function _stablecoinGovernorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(IStablecoin.setReserveVault.selector);
    }

    function _irmMarketSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(IInterestRateModel.updateUnderwriterRate.selector);
    }

    function _irmGovernorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IInterestRateModel.setLiquiditySlopes.selector;
        selectors[1] = IInterestRateModel.setTermMultiplierSlope.selector;
        selectors[2] = IInterestRateModel.setLiquidationBonus.selector;
        selectors[3] = IInterestRateModel.setAveragingPeriod.selector;
    }

    function _oracleGovernorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(IOracle.setSource.selector);
    }

    function _marketOwnerSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](6);
        selectors[0] = IBaseMarket.setTrancheWeights.selector;
        selectors[1] = IBaseMarket.setLtv.selector;
        selectors[2] = IBaseMarket.setMarketMultiplier.selector;
        selectors[3] = IBaseMarket.setUnderwriterRate.selector;
        selectors[4] = IBaseMarket.setBorrowerRole.selector;
        selectors[5] = IBaseMarket.setDepositorRole.selector;
    }

    function _marketRegistrySelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(IBaseMarket.setTranches.selector);
    }

    function _marketGovernorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IBaseMarket.setTargetHealth.selector;
        selectors[1] = IFixedMarket.setTermLimits.selector;
    }

    function _marketGuardianSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IBaseMarket.setBuffer.selector;
        selectors[1] = IBaseMarket.setLt.selector;
        selectors[2] = IFloatingMarket.writeOff.selector;
        selectors[3] = IFixedMarket.writeOff.selector;
    }

    function _marketKeeperSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(IFixedMarket.extendAdmin.selector);
    }

    function _marketLiquidatorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IFloatingMarket.liquidate.selector;
        selectors[1] = IFixedMarket.liquidate.selector;
    }

    function _trancheOwnerSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(ITranche.setDepositorRole.selector);
    }

    function _trancheGovernorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(ITranche.setMaxCapital.selector);
    }

    function _trancheMarketSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(ITranche.fund.selector);
    }

    function _underwriterCuratorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IUnderwriter.addTranche.selector;
        selectors[1] = IUnderwriter.removeTranche.selector;
        selectors[2] = IUnderwriter.setDepositorRole.selector;
        selectors[3] = IUnderwriter.setAllocatorRole.selector;
    }

    function _underwriterKeeperSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = _one(IUnderwriter.report.selector);
    }

    /// @dev Borrow, borrowMore, and extend. Shared by create and {setBorrowerRole}.
    function _borrowerSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = IFloatingMarket.borrow.selector;
        selectors[1] = IFixedMarket.borrow.selector;
        selectors[2] = IFixedMarket.borrowMore.selector;
        selectors[3] = IFixedMarket.extend.selector;
    }

    /// @dev Allocate, deallocate, and the default route. Shared by create and {setAllocatorRole}.
    function _allocatorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](5);
        selectors[0] = IUnderwriter.allocate.selector;
        selectors[1] = IUnderwriter.deallocate.selector;
        selectors[2] = IUnderwriter.deallocateAsync.selector;
        selectors[3] = IUnderwriter.finalizeDeallocateAsync.selector;
        selectors[4] = IUnderwriter.setDefaultTranche.selector;
    }

    /// @dev ERC-4626 entry points. Shared by tranche create, underwriter create, and {setDepositorRole}.
    function _depositorSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IERC4626.mint.selector;
    }

    function _one(bytes4 selector) private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = selector;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
