// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Registry is Initializable, AccessControlEnumerableUpgradeable {

    struct Basket {
        address[] assets;
        mapping(address => bool) supportedAssets;
        mapping(address => uint256) optimiumRatio;
        mapping(address => uint256) lowerKinkRatio;
        mapping(address => uint256) upperKinkRatio;
        uint256 baseFee;
    }

    ICapToken public capToken;
    IVault public vault;

    Basket[] public baskets;
    address[] public borrowers;
    mapping(address => bool) public supportedBorrower;

    function initialize() initializer external {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function addAsset(address _asset) external onlyRole(MANAGER) {
        assets.push(_asset);
        supportedAsset[_asset] = true;
    }

    function removeAsset(address _asset) external onlyRole(MANAGER) {
        for (uint i; i < assets.length; ++i) {
            if (assets[i] == _asset) {
                assets[i] = assets[assets.length - 1];
                assets.pop();
            }
        }
        supportedAsset[_asset] = false;
    }

    function setCap(address _cap) external onlyRole(MANAGER) {
        vault = IVault(_vault);
    }

    function setVault(address _vault) external onlyRole(MANAGER) {
        vault = IVault(_vault);
    }

    function setMinter(address _minter) external onlyRole(MANAGER) {
        minter = IMinter(_minter);
    }
    
}
