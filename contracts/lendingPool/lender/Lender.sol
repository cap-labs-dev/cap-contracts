// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {AccessUpgradeable} from "../../registry/AccessUpgradeable.sol";
import {BorrowLogic} from "../libraries/BorrowLogic.sol";
import {LiquidationLogic} from "../libraries/LiquidationLogic.sol";
import {ReserveLogic} from "../libraries/ReserveLogic.sol";
import {ViewLogic} from "../libraries/ViewLogic.sol";
import {DataTypes} from "../libraries/types/DataTypes.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {IAddressProvider} from "../../interfaces/IAddressProvider.sol";
import {LenderStorage} from "./LenderStorage.sol";

/// @title Lender for covered agents
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract Lender is UUPSUpgradeable, LenderStorage, AccessUpgradeable {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the lender
    /// @param _addressProvider Address provider
    function initialize(address _addressProvider) external initializer {
        addressProvider = _addressProvider;
        __Access_init(IAddressProvider(addressProvider).accessControl());
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
                principalDebtToken: _reservesData[_asset].principalDebtToken,
                restakerDebtToken: _reservesData[_asset].restakerDebtToken,
                interestDebtToken: _reservesData[_asset].interestDebtToken,
                amount: _amount,
                receiver: _receiver,
                collateral: IAddressProvider(addressProvider).collateral(),
                oracle: IAddressProvider(addressProvider).priceOracle(),
                reserveCount: _reservesCount
            })
        );
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount to repay
    /// @param _agent Repay on behalf of another borrower
    /// @return principalRepaid Actual amount repaid
    /// @return restakerRepaid Actual restaker amount repaid
    /// @return interestRepaid Actual interest amount repaid
    function repay(address _asset, uint256 _amount, address _agent)
        external
        returns (uint256 principalRepaid, uint256 restakerRepaid, uint256 interestRepaid)
    {
        (principalRepaid, restakerRepaid, interestRepaid) = BorrowLogic.repay(
            _agentConfig[_agent],
            DataTypes.RepayParams({
                id: _reservesData[_asset].id,
                agent: _agent,
                asset: _asset,
                vault: _reservesData[_asset].vault,
                principalDebtToken: _reservesData[_asset].principalDebtToken,
                restakerDebtToken: _reservesData[_asset].restakerDebtToken,
                interestDebtToken: _reservesData[_asset].interestDebtToken,
                amount: _amount,
                caller: msg.sender,
                restakerInterestReceiver: IAddressProvider(addressProvider).restakerInterestReceiver(_agent),
                interestReceiver: IAddressProvider(addressProvider).interestReceiver(_asset)
            })
        );
    }

    /// @notice Liquidate an agent when the health is below 1
    /// @param _agent Agent address
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay on behalf of the agent
    /// @param liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(address _agent, address _asset, uint256 _amount) external returns (uint256 liquidatedValue) {
        liquidatedValue = LiquidationLogic.liquidate(
            _reservesData,
            _reservesList,
            _agentConfig[_agent],
            DataTypes.LiquidateParams({
                id: _reservesData[_asset].id,
                agent: _agent,
                asset: _asset,
                vault: _reservesData[_asset].vault,
                principalDebtToken: _reservesData[_asset].principalDebtToken,
                restakerDebtToken: _reservesData[_asset].restakerDebtToken,
                interestDebtToken: _reservesData[_asset].interestDebtToken,
                bonus: _reservesData[_asset].bonus,
                amount: _amount,
                caller: msg.sender,
                collateral: IAddressProvider(addressProvider).collateral(),
                oracle: IAddressProvider(addressProvider).priceOracle(),
                reserveCount: _reservesCount,
                restakerInterestReceiver: IAddressProvider(addressProvider).restakerInterestReceiver(_agent),
                interestReceiver: IAddressProvider(addressProvider).interestReceiver(_asset)
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
                collateral: IAddressProvider(addressProvider).collateral(),
                oracle: IAddressProvider(addressProvider).priceOracle(),
                reserveCount: _reservesCount
            })
        );
    }

    /// @notice Add asset to the possible lending
    /// @param _asset Asset address
    /// @param _vault Vault address
    /// @param _principalDebtToken Principal debt address
    /// @param _restakerDebtToken Restaker debt address
    /// @param _interestDebtToken Interest debt address
    /// @param _liquidationBonus Bonus percentage for liquidating a market to cover holding risk
    function addAsset(
        address _asset,
        address _vault,
        address _principalDebtToken,
        address _restakerDebtToken,
        address _interestDebtToken,
        uint256 _liquidationBonus
    ) external checkRole(this.addAsset.selector) {
        if (
            ReserveLogic.addAsset(
                _reservesData,
                _reservesList,
                DataTypes.AddAssetParams({
                    asset: _asset,
                    vault: _vault,
                    principalDebtToken: _principalDebtToken,
                    restakerDebtToken: _restakerDebtToken,
                    interestDebtToken: _interestDebtToken,
                    bonus: _liquidationBonus,
                    reserveCount: _reservesCount,
                    addressProvider: addressProvider
                })
            )
        ) {
            ++_reservesCount;
        }
    }

    /// @notice Remove asset from lending when there is no borrows
    /// @param _asset Asset address
    function removeAsset(address _asset) external checkRole(this.removeAsset.selector) {
        ReserveLogic.removeAsset(_reservesData, _reservesList, _asset);
    }

    /// @notice Pause an asset from being borrowed
    /// @param _asset Asset address
    /// @param _pause True if pausing or false if unpausing
    function pauseAsset(address _asset, bool _pause) external checkRole(this.pauseAsset.selector) {
        ReserveLogic.pauseAsset(_reservesData, _asset, _pause);
    }

    function _authorizeUpgrade(address) internal override checkRole(bytes4(0)) {}
}
