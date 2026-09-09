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
/// @notice Deploys markets and underwriters and wires AccessManager roles on new instances.
/// @dev GOVERNOR assigns operator role ids via {assignOperator}. KEEPER deploys with operator addresses.
/// Registry holds REGISTRY_ROLE on AccessManager and is admin of each assigned operator role.
///
/// Trust assumption: Registry must also hold ADMIN on the AccessManager, and this is accepted
/// rather than fixed. OpenZeppelin's AccessManager hardcodes `setTargetFunctionRole` and
/// `setRoleAdmin` to ADMIN_ROLE in `_getAdminRestrictions`, with no way to delegate them to a
/// narrower role. Since wiring a freshly deployed instance means calling both, no lesser role can
/// do this contract's job. Only `grantRole` is delegable, through `getRoleAdmin(roleId)`, which is
/// why {assignOperator} makes REGISTRY_ROLE the admin of each operator role. The practical
/// consequence is that a Registry upgrade is equivalent to full control of the AccessManager, so
/// the upgrade path must be governed as tightly as ADMIN itself.
contract Registry layout at erc7201("cap.storage.Registry") is IRegistry, AccessManagedUpgradeable, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @inheritdoc IRegistry
    address public vault;

    /// @inheritdoc IRegistry
    address public stablecoin;

    /// @inheritdoc IRegistry
    address public stakedStablecoin;

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

    /// @dev Tranches ever deployed for a market, which is what names their suffix. Counts
    /// deployments rather than seats so it only ever increases, and a tranche added to take over
    /// from a retired one is named apart from it rather than inheriting its number.
    mapping(address market => uint256 count) private _trancheCount;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IRegistry
    function initialize(address _authority, IRegistry.InitParams calldata init) external initializer {
        __AccessManaged_init(_authority);
        if (
            init.vault == address(0) || init.stablecoin == address(0) || init.stakedStablecoin == address(0)
                || init.oracle == address(0) || init.irm == address(0) || init.factory == address(0)
                || init.floatingMarketBeacon == address(0) || init.fixedMarketBeacon == address(0)
                || init.trancheBeacon == address(0) || init.underwriterBeacon == address(0)
        ) revert ZeroAddress();
        vault = init.vault;
        stablecoin = init.stablecoin;
        stakedStablecoin = init.stakedStablecoin;
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
    function createMarket(
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

        // the depositor set is a role of its own rather than a list on the vault, so the curator
        // can admit and remove depositors through the AccessManager without the Registry standing
        // in the middle
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
        restricted
        returns (address tranche)
    {
        if (!isMarket[_market]) revert UnknownMarket();
        uint64 ownerRole = marketOwnerRole(_market);

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
        // Derived rather than recorded at deployment, so that repointing a market's owner
        // selectors moves the owner for later tranches too instead of leaving a copy here saying
        // otherwise. {IBaseMarket-setTrancheWeights} is the anchor because it is the one owner
        // selector whose authority is the waterfall, which is what a new tranche joins.
        if (!isMarket[_market]) return 0;
        roleId = IAccessManager(authority()).getTargetFunctionRole(_market, IBaseMarket.setTrancheWeights.selector);
    }

    /// @dev Deploy a market with tranches and wire AccessManager roles
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
    function _deployTranche(address _asset, string memory _name, address market, uint64 ownerRole, uint256 index)
        internal
        returns (address tranche)
    {
        // Reverts if the asset is not priced
        IOracle(oracle).price(_asset);

        string memory trancheName = string.concat(_name, " Tranche ", Strings.toString(index));
        string memory trancheSymbol = string.concat("TR", Strings.toString(index));
        tranche = _deploy(
            trancheBeacon,
            abi.encodeCall(
                ITranche.initialize, (authority(), _asset, trancheName, trancheSymbol, market, vault, oracle)
            )
        );

        // the depositor set is a role of its own rather than a list on the tranche, so the market
        // owner can admit and remove depositors through the AccessManager without the Registry
        // standing in the middle. One role per tranche rather than per market, so a waterfall can
        // be open at one level and closed at another
        uint64 depositorRoleId = _nextOperatorRoleId++;
        _configureTrancheRoles(tranche, ownerRole, depositorRoleId);

        emit CreateTranche(market, tranche, _asset, ownerRole, depositorRoleId);
    }

    /// @dev Deploy a beacon proxy through the shared factory
    function _deploy(address beacon, bytes memory initData) internal returns (address instance) {
        instance = IBeaconFactory(factory).create(beacon, initData);
    }

    /// @dev Grant an operator role to an account. Registry must hold REGISTRY_ROLE and be role admin.
    function _grantOperatorRole(uint64 roleId, address account) internal {
        IAccessManager(authority()).grantRole(roleId, account, 0);
    }

    /// @dev Wire market function selectors to protocol and operator roles
    function _configureMarketRoles(address market, uint64 ownerRole, uint64 borrowerRole) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory ownerSelectors = new bytes4[](5);
        ownerSelectors[0] = IBaseMarket.setTrancheWeights.selector;
        ownerSelectors[1] = IBaseMarket.setLtv.selector;
        ownerSelectors[2] = IBaseMarket.setMarketMultiplier.selector;
        ownerSelectors[3] = IFixedMarket.extend.selector;
        ownerSelectors[4] = IBaseMarket.setUnderwriterRate.selector;
        manager.setTargetFunctionRole(market, ownerSelectors, ownerRole);

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
        // writing off debt recognises a loss, so it sits with the guardian rather than the keeper
        guardianSelectors[2] = IFloatingMarket.writeOff.selector;
        guardianSelectors[3] = IFixedMarket.writeOff.selector;
        manager.setTargetFunctionRole(market, guardianSelectors, CapRoles.GUARDIAN);

        bytes4[] memory adminSelectors = new bytes4[](2);
        adminSelectors[0] = IBaseMarket.setTranches.selector;
        adminSelectors[1] = IBaseMarket.setStakedStablecoin.selector;
        manager.setTargetFunctionRole(market, adminSelectors, CapRoles.ADMIN);

        bytes4[] memory keeperSelectors = new bytes4[](1);
        keeperSelectors[0] = IFixedMarket.extendAdmin.selector;
        manager.setTargetFunctionRole(market, keeperSelectors, CapRoles.KEEPER);

        bytes4[] memory liquidatorSelectors = new bytes4[](2);
        liquidatorSelectors[0] = IFloatingMarket.liquidate.selector;
        liquidatorSelectors[1] = IFixedMarket.liquidate.selector;
        manager.setTargetFunctionRole(market, liquidatorSelectors, CapRoles.LIQUIDATOR);

        manager.grantRole(CapRoles.MINTER, market, 0);

        bytes4[] memory irmSelectors = new bytes4[](2);
        irmSelectors[0] = IInterestRateModel.updateUnderwriterRate.selector;
        irmSelectors[1] = IInterestRateModel.updateMarketMultiplier.selector;
        manager.setTargetFunctionRole(irm, irmSelectors, CapRoles.MARKET);
        manager.grantRole(CapRoles.MARKET, market, 0);
    }

    /// @dev Wire tranche function selectors to the market owner, market and depositor roles
    function _configureTrancheRoles(address tranche, uint64 ownerRole, uint64 depositorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory ownerSelectors = new bytes4[](1);
        // matches IUnderwriter.setVestingPeriod sitting with the underwriter's operator: the
        // smoothing window on premium is a curator knob, and the worst it can do is re-vest
        ownerSelectors[0] = ITranche.setVestingPeriod.selector;
        manager.setTargetFunctionRole(tranche, ownerSelectors, ownerRole);

        // {ITranche-notifyPremium} re-anchors the vesting epoch, so leaving it public let anyone
        // restart the release schedule by donating a wei of premium and poking it: the remaining
        // locked balance was re-spread over a fresh full period each time, turning linear release
        // into decay that never finishes. The market is the only caller with a reason to be here,
        // since it notifies in the same breath as minting the premium
        bytes4[] memory marketSelectors = new bytes4[](2);
        marketSelectors[0] = ITranche.slash.selector;
        marketSelectors[1] = ITranche.notifyPremium.selector;
        manager.setTargetFunctionRole(tranche, marketSelectors, CapRoles.MARKET);

        // admission is the gate on the entry points themselves, so the allowlist is the membership
        // of this role and there is nothing to keep in step on the tranche. Registering an
        // underwriter to allocate here is the same grant. Repointing it later means another
        // setTargetFunctionRole, which AccessManager reserves to ADMIN
        bytes4[] memory depositorSelectors = new bytes4[](2);
        depositorSelectors[0] = IERC4626.deposit.selector;
        depositorSelectors[1] = IERC4626.mint.selector;
        manager.setTargetFunctionRole(tranche, depositorSelectors, depositorRoleId);

        // grant and revoke over the depositor role, and nothing else: they are the only
        // AccessManager calls delegable to a role other than ADMIN
        manager.setRoleAdmin(depositorRoleId, ownerRole);
    }

    /// @dev Wire underwriter function selectors to the operator, keeper and depositor roles
    function _configureUnderwriterRoles(address underwriter, uint64 roleId, uint64 depositorRoleId) internal {
        IAccessManager manager = IAccessManager(authority());

        bytes4[] memory operatorSelectors = new bytes4[](6);
        operatorSelectors[0] = IUnderwriter.allocate.selector;
        operatorSelectors[1] = IUnderwriter.deallocate.selector;
        operatorSelectors[2] = IUnderwriter.deallocateAsync.selector;
        operatorSelectors[3] = IUnderwriter.finalizeDeallocateAsync.selector;
        operatorSelectors[4] = IUnderwriter.setDefaultTranche.selector;
        operatorSelectors[5] = IUnderwriter.setVestingPeriod.selector;
        manager.setTargetFunctionRole(underwriter, operatorSelectors, roleId);

        bytes4[] memory keeperSelectors = new bytes4[](1);
        keeperSelectors[0] = IUnderwriter.report.selector;
        manager.setTargetFunctionRole(underwriter, keeperSelectors, CapRoles.KEEPER);

        // Registration is held above the curator on purpose. addTranche hands its argument vault
        // operator rights over the underwriter's entire balance and does not check that the address
        // is a tranche this registry deployed, so a curator holding it could register a contract of
        // their own and move the balance out. Wired explicitly even though ADMIN is AccessManager's
        // default for an unconfigured selector, so the role table shows a decision rather than an
        // omission.
        bytes4[] memory adminSelectors = new bytes4[](2);
        adminSelectors[0] = IUnderwriter.addTranche.selector;
        adminSelectors[1] = IUnderwriter.removeTranche.selector;
        manager.setTargetFunctionRole(underwriter, adminSelectors, CapRoles.ADMIN);

        // admission is the gate on the entry points themselves, so the allowlist is the membership
        // of this role and there is nothing to keep in step on the vault. Repointing it later means
        // another setTargetFunctionRole, which AccessManager reserves to ADMIN
        bytes4[] memory depositorSelectors = new bytes4[](2);
        depositorSelectors[0] = IERC4626.deposit.selector;
        depositorSelectors[1] = IERC4626.mint.selector;
        manager.setTargetFunctionRole(underwriter, depositorSelectors, depositorRoleId);

        // grant and revoke over the depositor role, and nothing else: they are the only
        // AccessManager calls delegable to a role other than ADMIN
        manager.setRoleAdmin(depositorRoleId, roleId);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override restricted { }
}
