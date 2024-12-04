// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Vault is Initializable, AccessControlEnumerableUpgradeable {
    bytes32 public constant SUPPLIER_ROLE = keccak256("SUPPLIER_ROLE");
    bytes32 public constant BORROWER_ROLE = keccak256("BORROWER_ROLE");

    mapping(address => uint256) public totalSupplies;
    mapping(address => uint256) public totalBorrows;
    mapping(address => uint256) public utilizationIndex;

    error TransferTaxNotSupported();

    function initialize() initializer external {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function deposit(address _asset, uint256 _amount) external onlyRole(SUPPLIER_ROLE) {
        _updateIndex(_asset);
        totalSupplies[_asset] += _amount;
        uint256 beforeBalance = IERC20(_asset).balanceOf(address(this));
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 afterBalance = IERC20(_asset).balanceOf(address(this));
        if (afterBalance != beforeBalance + _amount) TransferTaxNotSupported();
    }

    function withdraw(address _asset, uint256 _amount, address _receiver) external onlyRole(SUPPLIER_ROLE) {
        _updateIndex(_asset);
        totalSupplies[_asset] -= _amount;
        IERC20(_asset).safeTransfer(_receiver, _amount);
    }

    function borrow(address _asset, uint256 _amount) external onlyRole(BORROWER_ROLE) {
        _updateIndex(_asset);
        totalBorrows[_asset] += _amount;
        IERC20(_asset).safeTransfer(msg.sender, _amount);
    }

    function repay(address _asset, uint256 _amount) external onlyRole(BORROWER_ROLE) {
        _updateIndex(_asset);
        totalBorrows[_asset] -= _amount;
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
    }

    function _updateIndex(address _asset) internal {
        utilizationIndex[_asset] += utilization(_asset) * ( block.timestamp - lastUpdate[_asset] );
        lastUpdate[_asset] = block.timestamp;
    }

    function availableBalance(address _asset) external view returns (uint256 amount) {
        amount = totalSupplies[_asset] - totalBorrows[_asset];
    }

    function utilization(address _asset) public view returns (uint256 ratio) {
        ratio = totalBorrows[_asset] * 1e27 / totalSupplies[_asset];
    }
}
