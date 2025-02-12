// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockFractionalReserveVault is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public interestRate; // 18 decimals (1e18 = 100%)
    uint256 public lastUpdate;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    constructor(address _asset, uint256 _interestRate, string memory _name, string memory _symbol)
        ERC4626(IERC20(_asset))
        ERC20(_name, _symbol)
    {
        interestRate = _interestRate;
        lastUpdate = block.timestamp;
    }

    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    function claimableInterest() external view returns (uint256) {
        uint256 principal = totalAssets();
        uint256 timeElapsed = block.timestamp - lastUpdate;
        return (principal * interestRate * timeElapsed) / (SECONDS_PER_YEAR * 1e18);
    }

    function realizeInterest() external returns (uint256 interest) {
        interest = this.claimableInterest();
        if (interest > 0) {
            IERC20(asset()).safeTransfer(msg.sender, interest);
            lastUpdate = block.timestamp;
        }
    }

    function setInterestRate(uint256 _interestRate) external {
        interestRate = _interestRate;
    }
}
