// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "../interfaces/IAccessControl.sol";

/// @title AddressProvider
/// @author kexley, @capLabs
/// @notice Addresses are stored here as a central repository
contract AddressProvider is UUPSUpgradeable {
    /// @dev Address provider admin role
    bytes32 public constant ADDRESS_PROVIDER_ADMIN = keccak256("ADDRESS_PROVIDER_ADMIN");

    /// @notice Access control center
    address public accessControl;

    /// @notice Lender for assets
    address public lender;

    /// @notice Collateral controller for collateralizing agents
    address public collateral;

    /// @notice Price oracle
    address public priceOracle;

    /// @notice Rate oracle for interest rates
    address public rateOracle;

    /// @notice Vault data provider
    address public vaultDataProvider;

    /// @notice Minter
    address public minter;

    /// @notice Vault instance
    address public vaultInstance;

    /// @notice Principal debt token instance
    address public principalDebtTokenInstance;

    /// @notice Restaker debt token instance
    address public restakerDebtTokenInstance;

    /// @notice Interest debt token instance
    address public interestDebtTokenInstance;

    /// @notice Interest receiver for an asset
    mapping(address => address) interestReceiver;

    /// @notice Receiver of restaker interest for an asset
    mapping(address => address) restakerInterestReceiver;

    event SetAccessControl(address accessControl);

    event SetLender(address lender);

    event SetCollateral(address collateral);

    event SetPriceOracle(address priceOracle);

    event SetRateOracle(address rateOracle);

    event SetVaultDataProvider(address vaultDataProvider);

    event SetMinter(address minter);

    event SetVaultInstance(address vaultInstance);

    event SetPrincipalDebtTokenInstance(address principalDebtTokenInstance);

    event SetRestakerDebtTokenInstance(address restakerDebtTokenInstance);

    event SetInterestDebtTokenInstance(address interestDebtTokenInstance);

    event SetInterestReceiver(address asset, address interestReceiver);

    event SetRestakerInterestReceiver(address agent, address restakerInterestReceiver);

    /// @dev Only admin are allowed to call functions
    modifier onlyAdmin {
        _onlyAdmin();
        _;
    }

    /// @dev Reverts if the caller is not admin
    function _onlyAdmin() private view {
        IAccessControl(accessControl).checkRole(ADDRESS_PROVIDER_ADMIN, msg.sender);
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the address provider with the access control
    /// @param _accessControl Access control address
    function initialize(address _accessControl) external initializer {
        accessControl = _accessControl;
        emit SetAccessControl(_accessControl);
    }

    /// @notice Check that the caller has the correct permissions
    /// @param _role Role id
    /// @param _account Caller address
    function checkRole(bytes32 _role, address _account) external view {
        IAccessControl(accessControl).checkRole(_role, _account);
    }

    /// @notice Set the access control address
    /// @param _accessControl Access control address
    function setAccessControl(address _accessControl) external onlyAdmin {
        accessControl = _accessControl;
        emit SetAccessControl(_accessControl);
    }

    function setLender(address _lender) external onlyAdmin {
        lender = _lender;
        emit SetLender(_lender);
    }

    function setCollateral(address _collateral) external onlyAdmin {
        collateral = _collateral;
        emit SetCollateral(_collateral);
    }

    function setPriceOracle(address _priceOracle) external onlyAdmin {
        priceOracle = _priceOracle;
        emit SetPriceOracle(_priceOracle);
    }

    function setRateOracle(address _rateOracle) external onlyAdmin {
        rateOracle = _rateOracle;
        emit SetRateOracle(_rateOracle);
    }

    function setVaultDataProvider(address _vaultDataProvider) external onlyAdmin {
        vaultDataProvider = _vaultDataProvider;
        emit SetVaultDataProvider(_vaultDataProvider);
    }

    function setMinter(address _minter) external onlyAdmin {
        minter = _minter;
        emit SetMinter(_minter);
    }

    function setVaultInstance(address _vaultInstance) external onlyAdmin {
        vaultInstance = _vaultInstance;
        emit SetVaultInstance(_vaultInstance);
    }

    function setPrincipalDebtTokenInstance(address _principalDebtTokenInstance)
        external
        onlyAdmin
    {
        principalDebtTokenInstance = _principalDebtTokenInstance;
        emit SetPrincipalDebtTokenInstance(_principalDebtTokenInstance);
    }

    function setRestakerDebtTokenInstance(address _restakerDebtTokenInstance)
        external
        onlyAdmin
    {
        restakerDebtTokenInstance = _restakerDebtTokenInstance;
        emit SetRestakerDebtTokenInstance(_restakerDebtTokenInstance);
    }

    function setInterestDebtTokenInstance(address _interestDebtTokenInstance)
        external
        onlyAdmin
    {
        interestDebtTokenInstance = _interestDebtTokenInstance;
        emit SetInterestDebtTokenInstance(_interestDebtTokenInstance);
    }

    function setInterestReceiver(address _asset, address _receiver) external onlyAdmin {
        interestReceiver[_asset] = _receiver;
        emit SetInterestReceiver(_asset, _receiver);
    }

    function setRestakerInterestReceiver(address _agent, address _receiver) external onlyAdmin {
        restakerInterestReceiver[_agent] = _receiver;
        emit SetRestakerInterestReceiver(_agent, _receiver);
    }

    function _authorizeUpgrade(address) internal override onlyAdmin {}
}
