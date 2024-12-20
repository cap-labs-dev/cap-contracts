// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { ERC20PermitUpgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IRegistry } from "../interfaces/IRegistry.sol";
import { IMinter } from "../interfaces/IMinter.sol";

contract StakedCap is ERC4626Upgradeable, ERC20PermitUpgradeable {
    using SafeERC20 for IERC20;

    uint256 public lastNotify;
    uint256 public storedTotal;
    uint256 public totalLocked;
    uint256 public lockDuration;

    address public registry;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    function initialize(address asset_, address _registry) external initializer {
        string memory name = string.concat("s", IERC20Metadata(asset_).name());
        string memory symbol = string.concat("s", IERC20Metadata(asset_).symbol());

        __ERC4626_init(IERC20(asset_));
        __ERC20_init(name, symbol);
        __ERC20Permit_init(name);

        registry = _registry;
    }

    function decimals() public view virtual override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8) {
        return ERC4626Upgradeable.decimals();
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
        address[] memory assets = IRegistry(registry).basketAssets(asset());
        address minter = IRegistry(registry).minter();
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
        uint256 elapsed = block.timestamp - lastNotify;
        uint256 remaining = elapsed < lockDuration ? lockDuration - elapsed : 0;
        locked = totalLocked * remaining / lockDuration;
    }

    function totalAssets() public override view returns (uint256 total) {
        total = storedTotal - lockedProfit();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
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
        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        storedTotal -= shares;

        emit Withdraw(caller, receiver, owner, assets, shares);
    }
}