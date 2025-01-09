// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IVaultDataProvider} from "../interfaces/IVaultDataProvider.sol";
import {IAddressProvider} from "../interfaces/IAddressProvider.sol";
import {IMinter} from "../interfaces/IMinter.sol";

/// @title Staked Cap Token
/// @author kexley, @capLabs
/// @notice Slow releasing yield-bearing token that distributes the yield accrued from agents
/// borrowing from the underlying assets.
/// @dev Calling notify permissionlessly will swap the underlying assets to the cap token and start
/// the linear unlock
contract StakedCap is UUPSUpgradeable, ERC4626Upgradeable, ERC20PermitUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Staked cap token admin role id
    bytes32 public constant STAKED_CAP_ADMIN = keccak256("STAKED_CAP_ADMIN");

    /// @notice Address provider
    IAddressProvider public addressProvider;

    /// @notice Stored total balance of cap tokens on this contract, including locked
    uint256 public storedTotal;

    /// @notice Total cap tokens locked in latest notification
    uint256 public totalLocked;

    /// @notice Timestamp of the last notification of yield
    uint256 public lastNotify;

    /// @notice Lock duration for the linear vesting period, in seconds
    uint256 public lockDuration;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the staked cap token by matching the name and symbol of the underlying
    /// @param _addressProvider Address of the address provider
    /// @param _asset Address of the cap token
    function initialize(address _addressProvider, address _asset) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
        string memory _name = string.concat("s", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("s", IERC20Metadata(_asset).symbol());

        __ERC4626_init(IERC20(_asset));
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
    }

    /// @notice Override the decimals function to match underlying decimals
    /// @return _decimals Decimals of the staked cap token
    function decimals() public view virtual override(ERC20Upgradeable, ERC4626Upgradeable) returns (uint8 _decimals) {
        _decimals = ERC4626Upgradeable.decimals();
    }

    /// @notice Notify this contract that it has yield to convert and start vesting
    function notify() external {
        _swap();
        uint256 total = IERC20(asset()).balanceOf(address(this));
        if (total > storedTotal) {
            totalLocked = lockedProfit() + total - storedTotal;
            storedTotal = total;
            lastNotify = block.timestamp;
        }
    }

    /// @dev Swap yield using the minter into the cap token
    function _swap() internal {
        IVaultDataProvider vaultDataProvider = IVaultDataProvider(addressProvider.vaultDataProvider());
        address vault = vaultDataProvider.vault(asset());
        address[] memory assets = vaultDataProvider.vaultData(vault).assets;
        address minter = addressProvider.minter();
        for (uint256 i; i < assets.length; ++i) {
            uint256 balance = IERC20(assets[i]).balanceOf(address(this));
            if (balance > 0) {
                IMinter(minter).swapExactTokenForTokens(
                    balance, 0, assets[i], asset(), address(this), type(uint256).max
                );
            }
        }
    }

    /// @notice Remaining locked profit after a notification
    /// @return locked Amount remaining to be vested
    function lockedProfit() public view returns (uint256 locked) {
        if (lockDuration == 0) return 0;
        uint256 elapsed = block.timestamp - lastNotify;
        uint256 remaining = elapsed < lockDuration ? lockDuration - elapsed : 0;
        locked = totalLocked * remaining / lockDuration;
    }

    /// @notice Total vested cap tokens on this contract
    /// @return total Total amount of vested cap tokens
    function totalAssets() public view override returns (uint256 total) {
        total = storedTotal - lockedProfit();
    }

    /// @dev Overriden to update the total assets including unvested tokens
    /// @param _caller Caller of the deposit
    /// @param _receiver Receiver of the staked cap tokens
    /// @param _assets Amount of cap tokens to pull from the caller
    /// @param _shares Amount of staked cap tokens to send to receiver
    function _deposit(address _caller, address _receiver, uint256 _assets, uint256 _shares) internal override {
        SafeERC20.safeTransferFrom(IERC20(asset()), _caller, address(this), _assets);
        _mint(_receiver, _shares);
        storedTotal += _shares;

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
        storedTotal -= _shares;

        emit Withdraw(_caller, _receiver, _owner, _assets, _shares);
    }

    /// @dev Only admin can upgrade
    function _authorizeUpgrade(address) internal override view {
        addressProvider.checkRole(STAKED_CAP_ADMIN, msg.sender);
    }
}
