// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IDelegation } from "../../interfaces/IDelegation.sol";
import { ISymbioticNetworkMiddleware } from "../../interfaces/ISymbioticNetworkMiddleware.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title CoverageLens
/// @author weso, Cap Labs
/// @notice Lens for coverage calculations
contract CoverageLens {
    /// @notice Coverage for an agent at a given Delegation epoch (best-effort lens)
    /// @dev Per Delegation's epoch semantics, coverage becomes meaningfully "active" only after time has passed.
    ///      This lens intentionally queries `slashableCollateral` at the start of epoch `(_epoch - 2)`.
    /// @param delegation Delegation contract address
    /// @param network Network middleware address for the agent
    /// @param _agent Agent address
    /// @param _epoch Epoch index (same epoch numbering as `IDelegation.epoch()`)
    /// @return coverage Coverage for the agent at that epoch boundary (USD, 8 decimals)
    function coverageAtEpoch(address delegation, address network, address _agent, uint256 _epoch)
        external
        view
        returns (uint256 coverage)
    {
        if (_epoch < 2) return 0;

        uint256 ts = _epochToTimestamp(delegation, _epoch - 2);
        require(ts <= type(uint48).max, "epoch too large");

        uint256 cap = IDelegation(delegation).coverageCap(_agent);

        uint48 captureTimestamp = uint48(ts);
        if (captureTimestamp >= block.timestamp) return 0;

        uint256 epochCoverage = ISymbioticNetworkMiddleware(network).slashableCollateral(_agent, captureTimestamp);
        coverage = Math.min(epochCoverage, cap);
    }

    function _epochToTimestamp(address delegation, uint256 _epoch) internal view returns (uint256 timestamp) {
        return IDelegation(delegation).epochDuration() * _epoch;
    }
}
