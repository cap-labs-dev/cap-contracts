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
    uint256 public lt;

    /// @inheritdoc IRegistry
    uint256 public buffer;

    /// @inheritdoc IRegistry
    uint256 public targetHealth;

    /// @dev Next operator role id to assign
    uint64 private _nextOperatorRoleId;

    /// @inheritdoc IRegistry
    mapping(address account => uint64 roleId) public operatorRole;

    /// @inheritdoc IRegistry
    mapping(address market => bool deployed) public isMarket;

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
        lt = init.lt;
        buffer = init.buffer;
        targetHealth = init.targetHealth;
        _nextOperatorRoleId = CapRoles.FIRST_OPERATOR_ROLE;
        _configureInfraRoles();
    }

    /// @inheritdoc IRegistry
    function assignOperator(address account) external restricted returns (uint64 roleId) {
        if (account == address(0)) revert ZeroAddress();
        if (operatorRole[account] != 0) revert AlreadyAssigned();

        roleId = _nextOperatorRoleId++;
        operatorRole[account] = roleId;

        IAccessManager manager = IAccessManager(authority());
        manager.setRoleAdmin(roleId, CapRoles.REGISTRY);

        emit OperatorAssigned(account, roleId);
    }

    /// @inheritdoc IRegistry
    function createFloatingMarket(
        address[] calldata _assets,
        uint256[] calldata _weights,
        string memory _name,
        address _marketOwner,
        address _borrower
    ) external restricted returns (address market, address[] memory deployedTranches) {
        (market, deployedTranches) = _createMarket(
            floatingMarketBeacon,
            abi.encodeCall(FloatingMarket.initialize, (authority(), address(this), _name)),
            _assets,
            _weights,
            _name,
            _marketOwner,
            _borrower
        );
    }

    /// @inheritdoc IRegistry
    function createFixedMarket(
        address[] calldata _assets,
        uint256[] calldata _weights,
        string memory _name,
        address _marketOwner,
        address _borrower,
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
            _marketOwner,
            _borrower
        );
    }

    /// @inheritdoc IRegistry
    function createUnderwriter(address _asset, string memory _name, string memory _symbol, address _operator)
        external
        restricted
        returns (address underwriter)
    {
        uint64 roleId = operatorRole[_operator];
        if (roleId == 0) revert OperatorNotAssigned();

        _grantOperatorRole(roleId, _operator);

        // depositor allowlist is an AccessManager role the curator administers
        uint64 depositorRoleId = _nextOperatorRoleId++;

        underwriter = _deploy(
            underwriterBeacon,
            abi.encodeCall(IUnderwriter.initialize, (authority(), _name, _symbol, _asset, vault, stablecoin))
        );

        _configureUnderwriterRoles(underwriter, roleId, depositorRoleId);

        emit CreateUnderwriter(underwriter, _asset, _name, _symbol, _operator, roleId, depositorRoleId);
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
    function marketOwnerRole(address _market) public view returns (uint64 roleId) {
        // Live from the AccessManager, so rehoming owner selectors moves this too.
        if (!isMarket[_market]) return 0;
        roleId = IAccessManager(authority()).getTargetFunctionRole(_market, IBaseMarket.setTrancheWeights.selector);
    }

    /// @dev Deploy a market with tranches and wire AccessManager roles
    /// @param beacon The market implementation beacon
    /// @param marketInitData The encoded market initializer call
    /// @param _assets The asset of each tranche, index 0 is most senior
    /// @param _weights Tranche weights in ray decimals, index 0 is most senior
    /// @param _name The market name
    /// @param _marketOwner The market owner operator address
    /// @param _borrower The borrower operator address
    /// @return market The deployed market
    /// @return deployedTranches The deployed tranche addresses in seniority order
    function _createMarket(
        address beacon,
        bytes memory marketInitData,
        address[] calldata _assets,
        uint256[] calldata _weights,
        string memory _name,
        address _marketOwner,
        address _borrower
    ) internal returns (address market, address[] memory deployedTranches) {
        if (_assets.length == 0) revert InvalidTrancheCount();
        if (_assets.length != _weights.length) revert TrancheAssetsMismatch();

        uint64 ownerRole = operatorRole[_marketOwner];
        uint64 borrowerRole = operatorRole[_borrower];
        if (ownerRole == 0 || borrowerRole == 0) revert OperatorNotAssigned();

        _grantOperatorRole(ownerRole, _marketOwner);
        _grantOperatorRole(borrowerRole, _borrower);

        market = _deploy(beacon, marketInitData);
        isMarket[market] = true;
        _trancheCount[market] = _assets.length;

        deployedTranches = new address[](_assets.length);
        IBaseMarket.Tranche[] memory marketTranches = new IBaseMarket.Tranche[](_assets.length);

        for (uint256 i; i < _assets.length; ++i) {
            address tranche = _deployTranche(_assets[i], _name, market, ownerRole, i);
            deployedTranches[i] = tranche;
            marketTranches[i] = IBaseMarket.Tranche({ tranche: tranche, weight: _weights[i] });
        }

        _configureMarketRoles(market, ownerRole, borrowerRole);
        IBaseMarket(market).setTranches(marketTranches);

        emit CreateMarket(market, _assets, _name, _marketOwner, _borrower, ownerRole, borrowerRole, deployedTranches);
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
                ITranche.initialize, (authority(), _asset, trancheName, trancheSymbol, market, vault, oracle)
            )
        );

        // one depositor role per tranche, administered by the market owner
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

    /// @dev Grant an operator role to an account. Registry must hold REGISTRY_ROLE and be role admin.
    /// @param roleId The operator role to grant
    /// @param account The account receiving the role
    function _grantOperatorRole(uint64 roleId, address account) internal {
        IAccessManager(authority()).grantRole(roleId, account, 0);
    }

    /// @dev Wire shared-infrastructure selectors. This contract must hold ADMIN.
    function _configureInfraRoles() internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory factorySelectors = new bytes4[](1);
        factorySelectors[0] = IBeaconFactory.create.selector;
        manager.setTargetFunctionRole(factory, factorySelectors, CapRoles.REGISTRY);

        bytes4[] memory registryGovernorSelectors = new bytes4[](1);
        registryGovernorSelectors[0] = IRegistry.assignOperator.selector;
        manager.setTargetFunctionRole(address(this), registryGovernorSelectors, CapRoles.GOVERNOR);

        bytes4[] memory registryKeeperSelectors = new bytes4[](3);
        registryKeeperSelectors[0] = IRegistry.createFloatingMarket.selector;
        registryKeeperSelectors[1] = IRegistry.createFixedMarket.selector;
        registryKeeperSelectors[2] = IRegistry.createUnderwriter.selector;
        manager.setTargetFunctionRole(address(this), registryKeeperSelectors, CapRoles.KEEPER);

        // mint, burn, write-off, and credit-backed premium — markets only
        bytes4[] memory marketSelectors = new bytes4[](4);
        marketSelectors[0] = IStablecoin.mintCreditBacked.selector;
        marketSelectors[1] = IStablecoin.burnCreditBacked.selector;
        marketSelectors[2] = IStablecoin.recognizeBadDebt.selector;
        marketSelectors[3] = IStablecoin.fundCreditBacked.selector;
        manager.setTargetFunctionRole(stablecoin, marketSelectors, CapRoles.MARKET);

        // parking reserve is keeper work
        bytes4[] memory stablecoinKeeperSelectors = new bytes4[](2);
        stablecoinKeeperSelectors[0] = IStablecoin.invest.selector;
        stablecoinKeeperSelectors[1] = IStablecoin.recall.selector;
        manager.setTargetFunctionRole(stablecoin, stablecoinKeeperSelectors, CapRoles.KEEPER);

        bytes4[] memory irmMarketSelectors = new bytes4[](2);
        irmMarketSelectors[0] = IInterestRateModel.updateUnderwriterRate.selector;
        irmMarketSelectors[1] = IInterestRateModel.updateMarketMultiplier.selector;
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
    }

    /// @dev Wire market function selectors to protocol and operator roles
    /// @param market The market to configure
    /// @param ownerRole The operator role that owns the market
    /// @param borrowerRole The operator role that may borrow
    function _configureMarketRoles(address market, uint64 ownerRole, uint64 borrowerRole) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory ownerSelectors = new bytes4[](6);
        ownerSelectors[0] = IBaseMarket.setTrancheWeights.selector;
        ownerSelectors[1] = IBaseMarket.setLtv.selector;
        ownerSelectors[2] = IBaseMarket.setMarketMultiplier.selector;
        ownerSelectors[3] = IFixedMarket.extend.selector;
        ownerSelectors[4] = IBaseMarket.setUnderwriterRate.selector;
        ownerSelectors[5] = IBaseMarket.setTranches.selector;
        manager.setTargetFunctionRole(market, ownerSelectors, ownerRole);
        // this contract calls setTranches from createFloatingMarket / createTranche
        manager.grantRole(ownerRole, address(this), 0);

        bytes4[] memory borrowerSelectors = new bytes4[](3);
        borrowerSelectors[0] = IFloatingMarket.borrow.selector;
        borrowerSelectors[1] = IFixedMarket.borrow.selector;
        borrowerSelectors[2] = IFixedMarket.borrowMore.selector;
        manager.setTargetFunctionRole(market, borrowerSelectors, borrowerRole);

        bytes4[] memory governorSelectors = new bytes4[](3);
        governorSelectors[0] = IBaseMarket.setTargetHealth.selector;
        governorSelectors[1] = IBaseMarket.setFixedCreditLimit.selector;
        governorSelectors[2] = IFixedMarket.setTermLimits.selector;
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
    }

    /// @dev Wire tranche function selectors to the market owner, market and depositor roles
    /// @param tranche The tranche to configure
    /// @param ownerRole The market owner role that administers depositors
    /// @param depositorRoleId The role whose members may deposit
    function _configureTrancheRoles(address tranche, uint64 ownerRole, uint64 depositorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

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
    }

    /// @dev Wire underwriter function selectors to the operator, keeper and depositor roles
    /// @param underwriter The underwriter to configure
    /// @param roleId The curator operator role
    /// @param depositorRoleId The role whose members may deposit
    function _configureUnderwriterRoles(address underwriter, uint64 roleId, uint64 depositorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory operatorSelectors = new bytes4[](7);
        operatorSelectors[0] = IUnderwriter.allocate.selector;
        operatorSelectors[1] = IUnderwriter.deallocate.selector;
        operatorSelectors[2] = IUnderwriter.deallocateAsync.selector;
        operatorSelectors[3] = IUnderwriter.finalizeDeallocateAsync.selector;
        operatorSelectors[4] = IUnderwriter.setDefaultTranche.selector;
        operatorSelectors[5] = IUnderwriter.addTranche.selector;
        operatorSelectors[6] = IUnderwriter.removeTranche.selector;
        manager.setTargetFunctionRole(underwriter, operatorSelectors, roleId);

        bytes4[] memory keeperSelectors = new bytes4[](1);
        keeperSelectors[0] = IUnderwriter.report.selector;
        manager.setTargetFunctionRole(underwriter, keeperSelectors, CapRoles.KEEPER);

        // depositor role is the whitelist for entry into the underwriter
        bytes4[] memory depositorSelectors = new bytes4[](2);
        depositorSelectors[0] = IERC4626.deposit.selector;
        depositorSelectors[1] = IERC4626.mint.selector;
        manager.setTargetFunctionRole(underwriter, depositorSelectors, depositorRoleId);

        // depositor role is administered by the underwriter operator
        manager.setRoleAdmin(depositorRoleId, roleId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
