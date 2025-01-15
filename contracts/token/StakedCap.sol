// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20PermitUpgradeable } from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import { ERC4626Upgradeable, ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { SafeERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IVaultUpgradeable } from "../interfaces/IVaultUpgradeable.sol";
import { AccessUpgradeable } from "../access/AccessUpgradeable.sol";

/// @title Staked Cap Token
/// @author kexley, @capLabs
/// @notice Slow releasing yield-bearing token that distributes the yield accrued from agents
/// borrowing from the underlying assets.
/// @dev Calling notify permissionlessly will swap the underlying assets to the cap token and start
/// the linear unlock
contract StakedCap is UUPSUpgradeable, ERC4626Upgradeable, ERC20PermitUpgradeable, AccessUpgradeable {
    using SafeERC20 for IERC20;

    /// @custom:storage-location erc7201:cap.storage.StakedCap
    struct StakedCapStorage {
        uint256 storedTotal;
        uint256 totalLocked;
        uint256 lastNotify;
        uint256 lockDuration;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.StakedCap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant StakedCapStorageLocation = 0xc3a6ec7b30f1d79063d00dcbb5942b226b77fe48a28f1a19018e7d1f70fd7600;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getStakedCapStorage() private pure returns (StakedCapStorage storage $) {
        assembly {
            $.slot := StakedCapStorageLocation
        }
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the staked cap token by matching the name and symbol of the underlying
    /// @param _accessControl Address of the access control
    /// @param _asset Address of the cap token
    function initialize(address _accessControl, address _asset, uint256 _lockDuration) external initializer {
        string memory _name = string.concat("s", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("s", IERC20Metadata(_asset).symbol());

        __ERC4626_init(IERC20(_asset));
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __Access_init(_accessControl);

        StakedCapStorage storage $ = _getStakedCapStorage();
        $.lockDuration = _lockDuration;
    }

    /// @notice Override the decimals function to match underlying decimals
    /// @return _decimals Decimals of the staked cap token
    function decimals() public view override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
        _decimals = ERC4626Upgradeable.decimals();
    }

    /// @notice Notify this contract that it has yield to convert and start vesting
    function notify() external {
        _swap();
        uint256 total = IERC20(asset()).balanceOf(address(this));
        StakedCapStorage storage $ = _getStakedCapStorage();
        if (total > $.storedTotal) {
            $.totalLocked = lockedProfit() + total - $.storedTotal;
            $.storedTotal = total;
            $.lastNotify = block.timestamp;
        }
    }

    /// @dev Swap yield using the minter into the cap token
    function _swap() internal {
        address[] memory assets = IVaultUpgradeable(asset()).assets();
        for (uint256 i; i < assets.length; ++i) {
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            if (balance > 0) {
                IVaultUpgradeable(asset()).mint(
                    assets[i], balance, 0, address(this), type(uint256).max
                );
            }
        }
    }

    /// @notice Remaining locked profit after a notification
    /// @return locked Amount remaining to be vested
    function lockedProfit() public view returns (uint256 locked) {
        StakedCapStorage storage $ = _getStakedCapStorage();
        if ($.lockDuration == 0) return 0;
        uint256 elapsed = block.timestamp - $.lastNotify;
        uint256 remaining = elapsed < $.lockDuration ? $.lockDuration - elapsed : 0;
        locked = $.totalLocked * remaining / $.lockDuration;
    }

    /// @notice Total vested cap tokens on this contract
    /// @return total Total amount of vested cap tokens
    function totalAssets() public view override returns (uint256 total) {
        StakedCapStorage storage $ = _getStakedCapStorage();
        total = $.storedTotal - lockedProfit();
    }

    /// @dev Overriden to update the total assets including unvested tokens
    /// @param _caller Caller of the deposit
    /// @param _receiver Receiver of the staked cap tokens
    /// @param _assets Amount of cap tokens to pull from the caller
    /// @param _shares Amount of staked cap tokens to send to receiver
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal override {
        SafeERC20.safeTransferFrom(IERC20(asset()), _caller, address(this), _assets);
        _mint(_receiver, _shares);

        StakedCapStorage storage $ = _getStakedCapStorage();
        $.storedTotal += _shares;

        emit Deposit(_caller, _receiver, _assets, _shares);
    }

    /// @dev Overriden to reduce the total assts including unvested tokens
    /// @param _caller Caller of the withdrawal
    /// @param _receiver Receiver of the cap tokens
    /// @param _owner Owner of the staked cap tokens being burnt
    /// @param _assets Amount of cap tokens to send to the receiver
    /// @param _shares Amount of staked cap tokens to burn from the owner
    function _withdraw(address _caller, address _receiver, address _owner, uint256 _assets, uint256 _shares)
        internal
        override
    {
        if (_caller != _owner) {
            _spendAllowance(_owner, _caller, _shares);
        }

        _burn(_owner, _shares);
        SafeERC20.safeTransfer(IERC20(asset()), _receiver, _assets);

        StakedCapStorage storage $ = _getStakedCapStorage();
        $.storedTotal -= _shares;

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    /// @dev Only admin can upgrade implementation
    function _authorizeUpgrade(address) internal view override checkAccess(bytes4(0)) { }
}
