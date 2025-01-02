// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BorrowLogic} from "../libraries/BorrowLogic.sol";
import {LiquidationLogic} from "../libraries/LiquidationLogic.sol";
import {ReserveLogic} from "../libraries/ReserveLogic.sol";
import {ViewLogic} from "../libraries/ViewLogic.sol";
import {CloneLogic} from "../libraries/CloneLogic.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {IRegistry} from "../../interfaces/IRegistry.sol";
import {LenderStorage} from "./LenderStorage.sol";

/// @title Lender for covered agents
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract Lender is Initializable, LenderStorage {
    modifier onlyLenderAdmin() {
        require(msg.sender == IRegistry(ADDRESS_PROVIDER).assetManager(), Errors.CALLER_NOT_POOL_ADMIN);
        _;
    }

    /// @notice Initialize the lender
    /// @param _addressProvider Registry address
    function initialize(address _addressProvider) external initializer {
        ADDRESS_PROVIDER = _addressProvider;
    }

    /// @notice Expose oracle to DebtToken contracts
    function oracle() external view returns (address) {
        return IRegistry(ADDRESS_PROVIDER).oracle();
    }

    /// @notice Borrow an asset
    /// @param _asset Asset to borrow
    /// @param _amount Amount to borrow
    /// @param _receiver Receiver of the borrowed asset
    function borrow(address _asset, uint256 _amount, address _receiver) external {
        BorrowLogic.borrow(
            _reservesData,
            _reservesList,
            _agentConfig[msg.sender],
            DataTypes.BorrowParams({
                id: _reservesData[_asset].id,
                agent: msg.sender,
                asset: _asset,
                vault: _reservesData[_asset].vault,
                debtToken: _reservesData[_asset].debtToken,
                amount: _amount,
                receiver: _receiver,
                collateral: IRegistry(ADDRESS_PROVIDER).collateral(),
                oracle: IRegistry(ADDRESS_PROVIDER).oracle(),
                reserveCount: _reservesCount
            })
        );
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount of principal to repay
    /// @param _interest Amount of interest to repay
    /// @param _agent Repay on behalf of another borrower
    /// @return repaid Actual amount repaid
    function repay(address _asset, uint256 _amount, uint256 _interest, address _agent)
        external
        returns (uint256 repaid, uint256 restakerRepaid, uint256 interestRepaid)
    {
        (repaid, restakerRepaid, interestRepaid) = BorrowLogic.repay(
            _agentConfig[_agent],
            DataTypes.RepayParams({
                id: _reservesData[_asset].id,
                agent: _agent,
                asset: _asset,
                vault: _reservesData[_asset].vault,
                debtToken: _reservesData[_asset].debtToken,
                amount: _amount,
                interest: _interest,
                caller: msg.sender,
                restakerRewarder: IRegistry(ADDRESS_PROVIDER).restakerRewarder(_agent),
                rewarder: IRegistry(ADDRESS_PROVIDER).rewarder(_asset)
            })
        );
    }

    /// @notice Liquidate an agent when the health is below 1
    /// @param _agent Agent address
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay on behalf of the agent
    /// @param _interest Amount of interest to repay on behalf of agent
    /// @param liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(address _agent, address _asset, uint256 _amount, uint256 _interest)
        external
        returns (uint256 liquidatedValue)
    {
        liquidatedValue = LiquidationLogic.liquidate(
            _reservesData,
            _reservesList,
            _agentConfig[_agent],
            DataTypes.LiquidateParams({
                id: _reservesData[_asset].id,
                agent: _agent,
                asset: _asset,
                vault: _reservesData[_asset].vault,
                debtToken: _reservesData[_asset].debtToken,
                bonus: _reservesData[_asset].bonus,
                amount: _amount,
                interest: _interest,
                caller: msg.sender,
                collateral: IRegistry(ADDRESS_PROVIDER).collateral(),
                oracle: IRegistry(ADDRESS_PROVIDER).oracle(),
                reserveCount: _reservesCount,
                restakerRewarder: IRegistry(ADDRESS_PROVIDER).restakerRewarder(_agent),
                rewarder: IRegistry(ADDRESS_PROVIDER).rewarder(_asset)
            })
        );
    }

    /// @notice Calculate the agent data
    /// @param _agent Address of agent
    /// @return totalCollateral Total collateral of an agent
    /// @return totalDebt Total debt of an agent
    /// @return ltv Loan to value ratio
    /// @return liquidationThreshold Liquidation ratio of an agent
    /// @return health Health status of an agent
    function agent(address _agent)
        external
        view
        returns (uint256 totalCollateral, uint256 totalDebt, uint256 ltv, uint256 liquidationThreshold, uint256 health)
    {
        (totalCollateral, totalDebt, ltv, liquidationThreshold, health) = ViewLogic.agent(
            _reservesData,
            _reservesList,
            _agentConfig[_agent],
            DataTypes.AgentParams({
                agent: _agent,
                collateral: IRegistry(ADDRESS_PROVIDER).collateral(),
                oracle: IRegistry(ADDRESS_PROVIDER).oracle(),
                reserveCount: _reservesCount
            })
        );
    }

    /// @notice Add asset to the possible lending
    /// @param _asset Asset address
    /// @param _vault Vault address
    /// @param _liquidationBonus Bonus percentage for liquidating a market to cover holding risk
    function addAsset(address _asset, address _vault, uint256 _liquidationBonus) external onlyLenderAdmin {
        if (
            ReserveLogic.addAsset(
                _reservesData,
                _reservesList,
                DataTypes.AddAssetParams({
                    asset: _asset,
                    vault: _vault,
                    debtTokenInstance: IRegistry(ADDRESS_PROVIDER).debtTokenInstance(),
                    bonus: _liquidationBonus,
                    reserveCount: _reservesCount
                })
            )
        ) {
            ++_reservesCount;
        }
    }

    /// @notice Remove asset from lending when there is no borrows
    /// @param _asset Asset address
    function removeAsset(address _asset) external onlyLenderAdmin {
        ReserveLogic.removeAsset(_reservesData, _reservesList, _asset);
    }

    /// @notice Pause an asset
    /// @param _asset Asset address
    /// @param _pause True if pausing or false if unpausing
    function pauseAsset(address _asset, bool _pause) external onlyLenderAdmin {
        ReserveLogic.pauseAsset(_reservesData, _asset, _pause);
    }

    /// @notice Upgrade an instance owned by the lender
    /// @param _instance Instance of a contract owned by the lender
    /// @param _implementation New implementation address
    function upgradeInstance(address _instance, address _implementation) external onlyLenderAdmin {
        CloneLogic.upgradeTo(_instance, _implementation);
    }
}
