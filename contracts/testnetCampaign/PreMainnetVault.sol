// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PreMainnetVault
 * @notice Vault for pre-mainnet campaign
 */
contract PreMainnetVault is ERC20, Ownable {

    /// @notice Deposit token most likely USDC
    IERC20 public depositToken;

    /// @notice Decimals of the token
    uint8 private _decimals;

    /// @notice Withdraw enabled flag after campaign ends
    bool public withdrawEnabled;

    error ZeroAmount();
    error WithdrawNotEnabled();
    error TransferNotEnabled();

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event WithdrawEnabled();

    constructor(address _depositToken) ERC20("Pre Mainnet Vault Token", "capPMV") Ownable(msg.sender) {
        depositToken = IERC20(_depositToken);

        _decimals = IERC20Metadata(_depositToken).decimals();
    }


    /***
     * @notice Deposit depositToken to mint cUSD on MegaETH Testnet
     * @param _amount Amount of depositToken to deposit
     */
    function deposit(uint256 _amount) external {
        if (_amount == 0) revert ZeroAmount();

        depositToken.transferFrom(_msgSender(), address(this), _amount);

        _mint(_msgSender(), _amount);

        /// todo: lz bridge logic to mint on testnet 

        emit Deposit(_msgSender(), _amount);
    }

    /***
     * @notice Withdraw depositToken after campaign ends
     * @param _amount Amount of depositToken to withdraw
     */
    function withdraw(uint256 _amount) external {
        if (!withdrawEnabled) revert WithdrawNotEnabled();

        _burn(_msgSender(), _amount);

        depositToken.transfer(msg.sender, _amount);

        emit Withdraw(_msgSender(), _amount);
    }

    /**
     * @notice Enable withdraw after campaign ends
     */
    function enableWithdraw() external onlyOwner {
        withdrawEnabled = true;

        emit WithdrawEnabled();
    }

    /// @dev override decimals to return decimals of deposit token
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /// @dev override _update to disable transfer before campaign ends
    function _update(address from, address to, uint256 value) internal virtual override {
        if (!withdrawEnabled && from != address(0)) revert TransferNotEnabled();
        super._update(from, to, value);
    }
}