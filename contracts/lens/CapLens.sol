// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { IDelegation } from "../interfaces/IDelegation.sol";
import { IEigenServiceManager } from "../interfaces/IEigenServiceManager.sol";
import { ISymbioticNetworkMiddleware } from "../interfaces/ISymbioticNetworkMiddleware.sol";

/// @title CapLens
/// @notice Immutable lens to query slashable collateral and coverage by agent and epoch diff. Works for both Symbiotic and EigenLayer agents.
contract CapLens {
    IDelegation public immutable delegation;

    constructor(address _delegation) {
        delegation = IDelegation(_delegation);
    }

    /// @notice Slashable collateral for an agent at (current epoch + epochDiff). Works for both Symbiotic and EigenLayer agents.
    /// @param _agent Agent address
    /// @param _epochDiff Epoch offset from current (0 = current epoch, +1 = next, -1 = previous)
    /// @return collateralValue Slashable collateral value in USD (8 decimals)
    /// @return collateral Slashable collateral amount in vault/strategy token units (Symbiotic only; 0 for Eigen as slashableCollateralByStrategy returns value only)
    function slashableCollateral(address _agent, int8 _epochDiff)
        external
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        (
            bool isEigen,
            address middleware,
            address vault,
            address network,
            address oracle,
            uint48 timestamp,
            address strategy
        ) = _resolveParams(_agent, _epochDiff);
        if (middleware == address(0)) return (0, 0);

        if (isEigen) {
            if (strategy == address(0)) return (0, 0);
            collateralValue = IEigenServiceManager(middleware).slashableCollateralByStrategy(_agent, strategy);
            return (collateralValue, 0);
        }

        return
            ISymbioticNetworkMiddleware(middleware)
                .slashableCollateralByVault(network, _agent, vault, oracle, timestamp);
    }

    /// @notice Coverage for an agent at (current epoch + epochDiff). Works for both Symbiotic and EigenLayer agents.
    /// @param _agent Agent address
    /// @param _epochDiff Epoch offset from current (0 = current epoch, +1 = next, -1 = previous)
    /// @return collateralValue Coverage value in USD (8 decimals)
    /// @return collateral Coverage amount in vault/strategy token units
    function coverage(address _agent, int8 _epochDiff)
        external
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        (
            bool isEigen,
            address middleware,
            address vault,
            address network,
            address oracle,
            uint48 timestamp,
            address strategy
        ) = _resolveParams(_agent, _epochDiff);
        if (middleware == address(0)) return (0, 0);

        if (isEigen) {
            if (strategy == address(0)) return (0, 0);
            return IEigenServiceManager(middleware).coverageByStrategy(_agent, strategy, oracle);
        }

        return ISymbioticNetworkMiddleware(middleware).coverageByVault(network, _agent, vault, oracle, timestamp);
    }

    /// @dev Resolve middleware type and all params for either Symbiotic or Eigen.
    /// @return isEigen True if the agent is on EigenLayer, false if Symbiotic
    /// @return middleware Middleware address
    /// @return vault For Symbiotic: vault address; for Eigen: address(0)
    /// @return network For Symbiotic: network address; for Eigen: address(0)
    /// @return oracle For Symbiotic: middleware oracle; for Eigen: IEigenServiceManager(middleware).oracle()
    /// @return timestamp For Symbiotic: timestamp; for Eigen: 0
    /// @return strategy For Eigen: operator's strategy; for Symbiotic: address(0)
    function _resolveParams(address _agent, int8 _epochDiff)
        internal
        view
        returns (
            bool isEigen,
            address middleware,
            address vault,
            address network,
            address oracle,
            uint48 timestamp,
            address strategy
        )
    {
        middleware = delegation.networks(_agent);
        if (middleware == address(0)) return (false, address(0), address(0), address(0), address(0), 0, address(0));

        uint256 epochDuration = delegation.epochDuration();
        uint256 currentEpoch = block.timestamp / epochDuration;
        int256 targetEpoch = int256(currentEpoch) + int256(int8(_epochDiff));
        if (targetEpoch >= 0) timestamp = uint48(uint256(targetEpoch) * epochDuration) + 1;

        try ISymbioticNetworkMiddleware(middleware).vaults(_agent) returns (address v) {
            vault = v;
        } catch { }

        if (vault == address(0)) {
            strategy = IEigenServiceManager(middleware).operatorToStrategy(_agent);
            oracle = IEigenServiceManager(middleware).oracle();
            return (true, middleware, address(0), address(0), oracle, timestamp, strategy);
        } else {
            network = ISymbioticNetworkMiddleware(middleware).network();
            oracle = ISymbioticNetworkMiddleware(middleware).oracle();
            return (false, middleware, vault, network, oracle, timestamp, address(0));
        }
    }
}
