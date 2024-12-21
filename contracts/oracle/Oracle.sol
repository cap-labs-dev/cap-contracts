// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { IAavePool } from "../interfaces/IAavePool.sol";
import { IChainlink } from "../interfaces/IChainlink.sol";

/// @title Oracle for fetching prices and interest rate indices
/// @author kexley, @capLabs
/// @notice Prices are sources from places like Chainlink and market rates from Aave. Admin can set
/// the rates for agents.
contract Oracle is Initializable {
    address public aavePool;
    mapping(address => address) public priceSource;
    mapping(address => address) public backupSource;

    mapping(address => uint256) public agentRate;
    mapping(address => uint256) public storedIndex;
    mapping(address => uint256) public lastUpdate;

    /// @notice Initialize the oracle with the Aave pool address
    /// @param _aavePool Aave pool address
    function initialize(address _aavePool) external initializer {
        aavePool = _aavePool;
    }

    /// TODO Needs authentication
    /// @notice Add a price source and backup for an asset
    /// @param _asset Asset address
    /// @param _source Price source for an asset
    /// @param _backupSource Backup source for an asset
    function addPriceSource(address _asset, address _source, address _backupSource) external {
        priceSource[_asset] = _source;
        backupSource[_asset] = _backupSource;
    }

    /// @notice Fetch price of an asset from Chainlink or a backup source if Chainlink fails
    /// @param _asset Asset address
    /// @return price Price of the asset 
    function getPrice(address _asset) external view returns (uint256 price) {
        address source = priceSource[_asset];

        if (source != address(0)) {
            price = uint256(IChainlink(source).latestAnswer());
        }

        if (price == 0) {
            address backup = backupSource[_asset];
            if (backup != address(0)) {
                price = uint256(IChainlink(backup).latestAnswer());
            }
        }
    }

    /// TODO Needs authentication
    /// @notice Update the rate at which an agent accrues interest explicitly to pay restakers
    /// @param _agent Agent address
    /// @param _rate New interest rate
    function updateAgentRate(address _agent, uint256 _rate) external {
        storedIndex[_agent] = agentIndex(_agent);
        lastUpdate[_agent] = block.timestamp;

        agentRate[_agent] = _rate;
    }

    /// @notice Fetch the current debt interest index from the Aave market
    /// @param _asset Asset address
    /// @return index Current index of the market debt
    function marketIndex(address _asset) external view returns (uint256 index) {
        index = IAavePool(aavePool).getReserveNormalizedVariableDebt(_asset);
    }

    /// @notice Fetch the index for an agent's debt to restakers
    /// @param _agent Agent address
    /// @return index Current index of the agent debt
    function agentIndex(address _agent) public view returns (uint256 index) {
        index = storedIndex[_agent];

        uint256 elapsed = block.timestamp - lastUpdate[_agent];
        if (elapsed > 0) {
            index += elapsed * agentRate[_agent];
        }
    }
}