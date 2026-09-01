// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC7575 } from "../interfaces/IERC7575.sol";

/// @title ERC7575
/// @author kexley
/// @notice This contract implements the ERC7575 standard
contract ERC7575 is IERC7575 {
    /// @inheritdoc IERC7575
    function share() public view virtual returns (address shareTokenAddress) {
        shareTokenAddress = address(this);
    }
}
