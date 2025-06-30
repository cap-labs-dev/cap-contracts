// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { MockERC20 } from "@recon/MockERC20.sol";
import { INetworkMiddleware } from "contracts/interfaces/INetworkMiddleware.sol";
import { IOracle } from "contracts/interfaces/IOracle.sol";
import "forge-std/console2.sol";

contract MockMiddleware is INetworkMiddleware {
    NetworkMiddlewareStorage internal _storage;

    // Mock control variables
    mapping(address => mapping(address => uint256)) public mockCollateralByVault;

    constructor(address _oracle) {
        _storage.oracle = _oracle;
    }

    function registerAgent(address _agent, address _vault) external {
        _storage.agentsToVault[_agent] = _vault;
        emit AgentRegistered(_agent);
    }

    function registerVault(address _vault, address _stakerRewarder) external {
        _storage.vaults[_vault] = Vault({ stakerRewarder: _stakerRewarder, exists: true });
        emit VaultRegistered(_vault);
    }

    function setFeeAllowed(uint256 _feeAllowed) external {
        _storage.feeAllowed = _feeAllowed;
    }

    function slash(address _agent, address _recipient, uint256 _slashShare, uint48) external {
        address _vault = _storage.agentsToVault[_agent];
        // Round up in favor of the liquidator
        uint256 slashShareOfCollateral = (mockCollateralByVault[_agent][_vault] * _slashShare / 1e18) + 1;

        // If the slash share is greater than the total slashable collateral, set it to the total slashable collateral
        if (slashShareOfCollateral > mockCollateralByVault[_agent][_vault]) {
            slashShareOfCollateral = mockCollateralByVault[_agent][_vault];
        }
        mockCollateralByVault[_agent][_vault] -= slashShareOfCollateral;
        MockERC20(_vault).mint(_recipient, slashShareOfCollateral);
        emit Slash(_agent, _recipient, _slashShare);
    }

    function slashableCollateralByVault(address, address _agent, address _vault, address, uint48)
        public
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        collateral = mockCollateralByVault[_agent][_vault];
        (uint256 collateralPrice,) = IOracle(_storage.oracle).getPrice(_vault);
        uint8 decimals = MockERC20(_vault).decimals();
        collateralValue = collateral * collateralPrice / (10 ** decimals);
    }

    function coverageByVault(address, address _agent, address _vault, address, uint48)
        external
        view
        returns (uint256 collateralValue, uint256 collateral)
    {
        return slashableCollateralByVault(address(0), _agent, _vault, address(0), 0);
    }

    function coverage(address _agent) external view returns (uint256 delegation) {
        (delegation,) =
            slashableCollateralByVault(address(0), _agent, _storage.agentsToVault[_agent], _storage.oracle, 0);
    }

    function slashableCollateral(address _agent, uint48) external view returns (uint256 _slashableCollateral) {
        (_slashableCollateral,) =
            slashableCollateralByVault(address(0), _agent, _storage.agentsToVault[_agent], _storage.oracle, 0);
    }

    function vaults(address _agent) external view returns (address vault) {
        return _storage.agentsToVault[_agent];
    }

    function distributeRewards(address _agent, address _token) external {
        // Mock implementation - no-op
    }

    // Mock control functions
    function setMockCollateralByVault(address _agent, address _vault, uint256 _collateral) external {
        _collateral %= type(uint88).max;
        mockCollateralByVault[_agent][_vault] = _collateral;
    }
}
