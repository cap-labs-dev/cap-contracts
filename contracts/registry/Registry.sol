// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";


contract Registry is IRegistry, Initializable, AccessControlEnumerableUpgradeable {

    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    address public override oracle;
    address public override collateral;
    address public override pTokenInstance;
    address public override minter;
    address public override assetManager;

    mapping(address => Basket) public baskets; // cToken => Basket
    mapping(address => mapping(address => BasketFees)) public basketFeesData; // cToken => asset => fees
    mapping(address => EnumerableSet.AddressSet) private vaultAssetWhitelist; // vault => set(whitelisted asset)
    mapping(address => address) public override restakerRewarder; // cToken => restakerRewarder
    mapping(address => address) public override rewarder; // asset => rewarder

    event AssetAdded(address indexed cToken, address indexed asset);
    event AssetRemoved(address indexed cToken, address indexed asset);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event CollateralUpdated(address indexed oldCollateral, address indexed newCollateral);
    event PTokenInstanceUpdated(address indexed oldInstance, address indexed newInstance);
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event AssetManagerUpdated(address indexed oldManager, address indexed newManager);

    function initialize() initializer external {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    function supportedCToken(address cToken) public view override returns (bool) {
        return baskets[cToken].vault != address(0);
    }

    function _basketSupportsAsset(address _cToken, address _asset) internal view returns (bool) {
        Basket storage basket = baskets[_cToken];
        return vaultAssetWhitelist[basket.vault].contains(_asset);   
    }

    function basketVault(address _cToken) external view override returns (address vault) {
        return baskets[_cToken].vault;
    }

    function basketAssets(address _cToken) external view override returns (address[] memory) {
        return vaultAssetWhitelist[baskets[_cToken].vault].values();
    }

    function basketBaseFee(address _cToken) external view override returns (uint256) {
        return baskets[_cToken].baseFee;
    }

    function basketFees(address _cToken, address _asset) external view override returns (BasketFees memory) {
        return basketFeesData[_cToken][_asset];
    }

    function basketSupportsAsset(address _cToken, address _asset) external view override returns (bool) {
        return _basketSupportsAsset(_cToken, _asset);
    }

    function vaultSupportsAsset(address _vault, address _asset) external view override returns (bool) {
        return vaultAssetWhitelist[_vault].contains(_asset);
    }

    function setOracle(address _oracle) external onlyRole(MANAGER_ROLE) {
        address oldOracle = oracle;
        oracle = _oracle;
        emit OracleUpdated(oldOracle, _oracle);
    }

    function setCollateral(address _collateral) external onlyRole(MANAGER_ROLE) {
        address oldCollateral = collateral;
        collateral = _collateral;
        emit CollateralUpdated(oldCollateral, _collateral);
    }

    function setPTokenInstance(address _pTokenInstance) external onlyRole(MANAGER_ROLE) {
        address oldInstance = pTokenInstance;
        pTokenInstance = _pTokenInstance;
        emit PTokenInstanceUpdated(oldInstance, _pTokenInstance);
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

    function addAsset(address _basket, address _asset) external onlyRole(MANAGER_ROLE) {
        require(!_basketSupportsAsset(_basket, _asset), "Asset already supported");
        
        vaultAssetWhitelist[_basket].add(_asset);
        emit AssetAdded(_basket, _asset);
    }

    function removeAsset(address _basket, address _asset) external onlyRole(MANAGER_ROLE) {
        vaultAssetWhitelist[_basket].remove(_asset);
        emit AssetRemoved(_basket, _asset);
    }
}

