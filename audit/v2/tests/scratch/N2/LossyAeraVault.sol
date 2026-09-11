// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAeraVault } from "../../../../../contracts/interfaces/IAeraVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice MockAeraVault (same pull/allowance semantics) plus a strategy-loss knob and a refuse switch.
contract LossyAeraVault is IAeraVault {
    using SafeERC20 for IERC20;

    error Aera__UnexpectedTokenAllowance(uint256 allowance);
    error Aera__Refused();

    bool public refuseWithdraw;
    uint256 public totalLost;

    function deposit(TokenAmount[] calldata tokenAmounts) external {
        for (uint256 i; i < tokenAmounts.length; ++i) {
            TokenAmount calldata t = tokenAmounts[i];
            t.token.safeTransferFrom(msg.sender, address(this), t.amount);
            uint256 allowance = t.token.allowance(msg.sender, address(this));
            if (allowance != 0) revert Aera__UnexpectedTokenAllowance(allowance);
        }
    }

    function withdraw(TokenAmount[] calldata tokenAmounts) external {
        if (refuseWithdraw) revert Aera__Refused();
        for (uint256 i; i < tokenAmounts.length; ++i) {
            tokenAmounts[i].token.safeTransfer(msg.sender, tokenAmounts[i].amount);
        }
    }

    /// @dev Simulate a strategy loss / fee / guardian drain of `bps` of current holdings.
    function lose(IERC20 token, uint256 bps) external returns (uint256 lost) {
        lost = token.balanceOf(address(this)) * bps / 10_000;
        if (lost > 0) token.safeTransfer(address(0xdead), lost);
        totalLost += lost;
    }

    function setRefuse(bool r) external {
        refuseWithdraw = r;
    }
}
