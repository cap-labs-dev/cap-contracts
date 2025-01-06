// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControlEnumerableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {CloneLogic} from "../lendingPool/libraries/CloneLogic.sol";

contract Registry is Initializable, AccessControlEnumerableUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToAddressMap;

    struct Basket {
        string name;
        address vault;
        address[] assets;
        uint256 baseFee;
    }

    struct BasketFees {
        uint256 slope0;
        uint256 slope1;
        uint256 mintKinkRatio;
        uint256 burnKinkRatio;
        uint256 optimalRatio;
    }

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    address public priceOracle;
    address public rateOracle;
    address public lender;
    address public collateral;
    address public minter;
    address public assetManager;

    // TODO: these token addresses could be immutable as they are beacon proxies and
    //       implementation can be updated without changing the address
    address public principalDebtTokenInstance;
    address public restakerDebtTokenInstance;
    address public interestDebtTokenInstance;

    // TODO: rework registry api and storage to minimize SLOAD calls on read ops
    mapping(address => address) private _basketVault; // cToken => vault
    EnumerableMap.AddressToAddressMap private _basketScToken; // cToken => scToken
    mapping(address => uint256) private _basketBaseFee; // cToken => baseFee
    mapping(address => uint256) private _basketRedeemFee; // cToken => redeemFee
    mapping(address => mapping(address => BasketFees)) private _basketFees; // cToken => asset => fees
    mapping(address => address) private _restakerRewarder; // cToken => restakerRewarder
    mapping(address => EnumerableSet.AddressSet) private _vaultAssetWhitelist; // vault => set(whitelisted asset)
    mapping(address => address) private _rewarder; // asset => rewarder

    event AssetAdded(address indexed cToken, address indexed asset);
    event AssetRemoved(address indexed cToken, address indexed asset);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event RateOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event LenderUpdated(address indexed oldLender, address indexed newLender);
    event CollateralUpdated(address indexed oldCollateral, address indexed newCollateral);
    event PrincipalDebtTokenInstanceUpdated(address indexed oldInstance, address indexed newInstance);
    event RestakerDebtTokenInstanceUpdated(address indexed oldInstance, address indexed newInstance);
    event InterestDebtTokenInstanceUpdated(address indexed oldInstance, address indexed newInstance);
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event AssetManagerUpdated(address indexed oldManager, address indexed newManager);
    event BasketSet(address indexed cToken, address indexed scToken, address indexed vault, uint256 baseFee);

    error VaultNotFound();
    error BasketNotFound();
    error PairNotSupported(address tokenIn, address tokenOut);

    function initialize() external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function baskets() external view returns (address[] memory) {
        return _basketScToken.keys();
    }

    function supportedCToken(address cToken) public view returns (bool) {
        return _basketVault[cToken] != address(0);
    }

    function basketVault(address _cToken) public view returns (address vault) {
        vault = _basketVault[_cToken];
        if (vault == address(0)) revert BasketNotFound();
    }

    function basketAssets(address _cToken) external view returns (address[] memory) {
        address vault = basketVault(_cToken);
        return _vaultAssetWhitelist[vault].values();
    }

    function basketBaseFee(address _cToken) external view returns (uint256) {
        return _basketBaseFee[_cToken];
    }

    function basketFees(address _cToken, address _asset) external view returns (BasketFees memory) {
        return _basketFees[_cToken][_asset];
    }

    function basketRedeemFee(address _cToken) external view returns (uint256) {
        return _basketRedeemFee[_cToken];
    }

    function restakerRewarder(address _cToken) external view returns (address) {
        return _restakerRewarder[_cToken];
    }

    function rewarder(address _asset) external view returns (address) {
        return _rewarder[_asset];
    }

    function basketSupportsAsset(address _cToken, address _asset) public view returns (bool) {
        address vault = basketVault(_cToken);
        return vaultSupportsAsset(vault, _asset);
    }

    function vaultSupportsAsset(address _vault, address _asset) public view returns (bool) {
        return _vaultAssetWhitelist[_vault].contains(_asset);
    }

    function setPriceOracle(address _priceOracle) external onlyRole(MANAGER_ROLE) {
        address oldPriceOracle = priceOracle;
        priceOracle = _priceOracle;
        emit PriceOracleUpdated(oldPriceOracle, _priceOracle);
    }

    function setRateOracle(address _rateOracle) external onlyRole(MANAGER_ROLE) {
        address oldRateOracle = rateOracle;
        rateOracle = _rateOracle;
        emit RateOracleUpdated(oldRateOracle, _rateOracle);
    }

    function setLender(address _lender) external onlyRole(MANAGER_ROLE) {
        address oldLender = lender;
        lender = _lender;
        emit LenderUpdated(oldLender, _lender);
    }

    function setCollateral(address _collateral) external onlyRole(MANAGER_ROLE) {
        address oldCollateral = collateral;
        collateral = _collateral;
        emit CollateralUpdated(oldCollateral, _collateral);
    }

    function setPrincipalDebtTokenImplementation(address _principalDebtTokenImplementation)
        external
        onlyRole(MANAGER_ROLE)
    {
        address newInstance = CloneLogic.initializeBeacon(_principalDebtTokenImplementation);
        address oldInstance = principalDebtTokenInstance;
        principalDebtTokenInstance = newInstance;
        emit PrincipalDebtTokenInstanceUpdated(oldInstance, newInstance);
    }

    function setRestakerDebtTokenImplementation(address _restakerDebtTokenImplementation)
        external
        onlyRole(MANAGER_ROLE)
    {
        address newInstance = CloneLogic.initializeBeacon(_restakerDebtTokenImplementation);
        address oldInstance = restakerDebtTokenInstance;
        restakerDebtTokenInstance = newInstance;
        emit RestakerDebtTokenInstanceUpdated(oldInstance, newInstance);
    }

    function setInterestDebtTokenImplementation(address _interestDebtTokenImplementation)
        external
        onlyRole(MANAGER_ROLE)
    {
        address newInstance = CloneLogic.initializeBeacon(_interestDebtTokenImplementation);
        address oldInstance = interestDebtTokenInstance;
        interestDebtTokenInstance = newInstance;
        emit InterestDebtTokenInstanceUpdated(oldInstance, newInstance);
    }

    function setMinter(address _minter) external onlyRole(MANAGER_ROLE) {
        address oldMinter = minter;
        minter = _minter;
        emit MinterUpdated(oldMinter, _minter);
    }

    function setAssetManager(address _manager) external onlyRole(MANAGER_ROLE) {
        address oldManager = assetManager;
        assetManager = _manager;
        emit AssetManagerUpdated(oldManager, _manager);
    }

    function addAsset(address _cToken, address _asset) external onlyRole(MANAGER_ROLE) {
        require(!basketSupportsAsset(_cToken, _asset), "Asset already supported");
        _vaultAssetWhitelist[basketVault(_cToken)].add(_asset);
        emit AssetAdded(_cToken, _asset);
    }

    function removeAsset(address _cToken, address _asset) external onlyRole(MANAGER_ROLE) {
        require(basketSupportsAsset(_cToken, _asset), "Asset not supported");
        _vaultAssetWhitelist[basketVault(_cToken)].remove(_asset);
        emit AssetRemoved(_cToken, _asset);
    }

    function setBasket(address _cToken, address _scToken, address _vault, uint256 _baseFee)
        external
        onlyRole(MANAGER_ROLE)
    {
        _basketVault[_cToken] = _vault;
        EnumerableMap.set(_basketScToken, _cToken, _scToken);
        _basketBaseFee[_cToken] = _baseFee;
        emit BasketSet(_cToken, _scToken, _vault, _baseFee);
    }
}
