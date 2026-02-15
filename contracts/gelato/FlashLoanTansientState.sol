// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { TransientSlot } from "@openzeppelin/contracts/utils/TransientSlot.sol";

/// @title Flash Loan Transient State
/// @author weso, Cap Labs
/// @notice Transient state for flash loan
contract FlashLoanTransientState {
    using TransientSlot for *;

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.FlashLoanTransientState")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant FLASH_LOAN_TRANSIENT_STATE_SLOT =
        0x080a6eb1727523b7cca4b7cf7a3debc9ba08c2ed83fc97b4f9cb68f53138c400;

    function setFlashLoanInProgress(bool _flashLoanInProgress) internal {
        FLASH_LOAN_TRANSIENT_STATE_SLOT.asBoolean().tstore(_flashLoanInProgress);
    }

    function isFlashLoanInProgress() internal view returns (bool) {
        return FLASH_LOAN_TRANSIENT_STATE_SLOT.asBoolean().tload();
    }
}
