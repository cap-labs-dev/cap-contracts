// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";

contract StakedCap is ERC4626Upgradeable, ERC20PermitUpgradeable {
    uint256 public lastNotify;
    uint256 public storedTotal;
    uint256 public totalLocked;
    uint256 public lockDuration;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    function initialize(address asset_) external initializer {
        string memory name = "s" + IERC20(asset_).name();
        string memory symbol = "s" + IERC20(asset_).symbol();

        __ERC20_init(name, symbol);
        __ERC4626_init(asset_);
        __ERC20Permit_init(name);
    }

    function notify() external {
        _swap();
        uint256 total = IERC20(asset()).balanceOf(address(this));
        if (total > storedTotal) {
            totalLocked = lockedProfit() + total - storedTotal;
            storedTotal = total;
            lastNotify = block.timestamp;
        }
    }

    function _swap() internal {
        address[] memory assets = ICap(asset()).assets();
        for (uint i; i < assets.length; ++i) {
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            if (balance > 0) {
                IMinter(minter).swapExactTokenForTokens(
                    balance,
                    0,
                    assets[i],
                    asset(),
                    address(this),
                    type(uint256).max
                );
            }
        }
    }

    function lockedProfit() public view returns (uint256 locked) {
        if (lockDuration == 0) return 0;
        uint256 elapsed = block.timestamp - lastHarvest;
        uint256 remaining = elapsed < lockDuration ? lockDuration - elapsed : 0;
        locked = totalLocked * remaining / lockDuration;
    }

    function totalAssets() public override view returns (uint256 total) {
        total = storedTotal - lockedProfit();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        SafeERC20.safeTransferFrom(asset(), caller, address(this), assets);
        _mint(receiver, shares);
        storedTotal += shares;

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @dev Withdraw/redeem common workflow.
     */
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        _burn(owner, shares);
        SafeERC20.safeTransfer(asset(), receiver, assets);
        storedTotal -= shares;

        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}