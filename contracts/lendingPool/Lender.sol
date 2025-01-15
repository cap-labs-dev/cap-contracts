// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IAddressProvider } from "../interfaces/IAddressProvider.sol";
import { AccessUpgradeable } from "../registry/AccessUpgradeable.sol";
import { BorrowLogic } from "./libraries/BorrowLogic.sol";
import { LiquidationLogic } from "./libraries/LiquidationLogic.sol";
import { ReserveLogic } from "./libraries/ReserveLogic.sol";
import { ViewLogic } from "./libraries/ViewLogic.sol";
import { Errors } from "./libraries/helpers/Errors.sol";
import { DataTypes } from "./libraries/types/DataTypes.sol";

/// @title Lender for covered agents
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract Lender is UUPSUpgradeable, AccessUpgradeable {
    /// @custom:storage-location erc7201:cap.storage.Lender
    struct LenderStorage {
        address addressProvider;
        mapping(address => DataTypes.ReserveData) reservesData;
        mapping(uint256 => address) reservesList;
        mapping(address => DataTypes.AgentConfigurationMap) agentConfig;
        uint16 reservesCount;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.Lender")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LenderStorageLocation = 0xd6af1ec8a1789f5ada2b972bd1569f7c83af2e268be17cd65efe8474ebf08800;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getLenderStorage() private pure returns (LenderStorage storage $) {
        assembly {
            $.slot := LenderStorageLocation
        }
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the lender
    /// @param _addressProvider Address provider
    function initialize(address _addressProvider, address _accessControl) external initializer {
        LenderStorage storage $ = _getLenderStorage();
        $.addressProvider = _addressProvider;
        __Access_init(_accessControl);
    }

    /// @notice Borrow an asset
    /// @param _asset Asset to borrow
    /// @param _amount Amount to borrow
    /// @param _receiver Receiver of the borrowed asset
    function borrow(address _asset, uint256 _amount, address _receiver) external {
        LenderStorage storage $ = _getLenderStorage();
        BorrowLogic.borrow(
            $.reservesData,
            $.reservesList,
            $.agentConfig[msg.sender],
            DataTypes.BorrowParams({
                id: $.reservesData[_asset].id,
                agent: msg.sender,
                asset: _asset,
                vault: $.reservesData[_asset].vault,
                principalDebtToken: $.reservesData[_asset].principalDebtToken,
                restakerDebtToken: $.reservesData[_asset].restakerDebtToken,
                interestDebtToken: $.reservesData[_asset].interestDebtToken,
                amount: _amount,
                receiver: _receiver,
                collateral: IAddressProvider($.addressProvider).collateral(),
                oracle: IAddressProvider($.addressProvider).oracle(),
                reserveCount: $.reservesCount
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
        LenderStorage storage $ = _getLenderStorage();
        (principalRepaid, restakerRepaid, interestRepaid) = BorrowLogic.repay(
            $.reservesData,
            $.agentConfig[_agent],
            DataTypes.RepayParams({
                id: $.reservesData[_asset].id,
                agent: _agent,
                asset: _asset,
                vault: $.reservesData[_asset].vault,
                principalDebtToken: $.reservesData[_asset].principalDebtToken,
                restakerDebtToken: $.reservesData[_asset].restakerDebtToken,
                interestDebtToken: $.reservesData[_asset].interestDebtToken,
                amount: _amount,
                caller: msg.sender,
                realizedInterest: $.reservesData[_asset].realizedInterest,
                restakerInterestReceiver: IAddressProvider($.addressProvider).restakerInterestReceiver(_agent),
                interestReceiver: IAddressProvider($.addressProvider).interestReceiver(_asset)
            })
        );
    }

    /// @notice Realize interest for an asset
    /// @param _asset Asset to realize interest for
    /// @param _amount Amount of interest to realize (type(uint).max for all available interest)
    /// @return actualRealized Actual amount realized
    function realizeInterest(address _asset, uint256 _amount) external returns (uint256 actualRealized) {
        LenderStorage storage $ = _getLenderStorage();
        actualRealized = BorrowLogic.realizeInterest(
            $.reservesData,
            DataTypes.RealizeInterestParams({
                asset: _asset,
                vault: $.reservesData[_asset].vault,
                interestDebtToken: $.reservesData[_asset].interestDebtToken,
                interestReceiver: IAddressProvider($.addressProvider).interestReceiver(_asset),
                amount: _amount,
                realizedInterest: $.reservesData[_asset].realizedInterest
            })
        );
    }

    /// @notice Liquidate an agent when the health is below 1
    /// @param _agent Agent address
    /// @param _asset Asset to repay
    /// @param _amount Amount of asset to repay on behalf of the agent
    /// @param liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(address _agent, address _asset, uint256 _amount) external returns (uint256 liquidatedValue) {
        LenderStorage storage $ = _getLenderStorage();
        liquidatedValue = LiquidationLogic.liquidate(
            $.reservesData,
            $.reservesList,
            $.agentConfig[_agent],
            DataTypes.LiquidateParams({
                id: $.reservesData[_asset].id,
                agent: _agent,
                asset: _asset,
                vault: $.reservesData[_asset].vault,
                principalDebtToken: $.reservesData[_asset].principalDebtToken,
                restakerDebtToken: $.reservesData[_asset].restakerDebtToken,
                interestDebtToken: $.reservesData[_asset].interestDebtToken,
                bonus: $.reservesData[_asset].bonus,
                amount: _amount,
                caller: msg.sender,
                realizedInterest: $.reservesData[_asset].realizedInterest,
                collateral: IAddressProvider($.addressProvider).collateral(),
                oracle: IAddressProvider($.addressProvider).oracle(),
                reserveCount: $.reservesCount,
                restakerInterestReceiver: IAddressProvider($.addressProvider).restakerInterestReceiver(_agent),
                interestReceiver: IAddressProvider($.addressProvider).interestReceiver(_asset)
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
        LenderStorage storage $ = _getLenderStorage();
        (totalCollateral, totalDebt, ltv, liquidationThreshold, health) = ViewLogic.agent(
            $.reservesData,
            $.reservesList,
            $.agentConfig[_agent],
            DataTypes.AgentParams({
                agent: _agent,
                collateral: IAddressProvider($.addressProvider).collateral(),
                oracle: IAddressProvider($.addressProvider).oracle(),
                reserveCount: $.reservesCount
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
    ) external checkAccess(this.addAsset.selector) {
        LenderStorage storage $ = _getLenderStorage();
        if (
            ReserveLogic.addAsset(
                $.reservesData,
                $.reservesList,
                DataTypes.AddAssetParams({
                    asset: _asset,
                    vault: _vault,
                    principalDebtToken: _principalDebtToken,
                    restakerDebtToken: _restakerDebtToken,
                    interestDebtToken: _interestDebtToken,
                    bonus: _liquidationBonus,
                    reserveCount: $.reservesCount,
                    addressProvider: $.addressProvider
                })
            )
        ) {
            ++$.reservesCount;
        }
    }

    /// @notice Remove asset from lending when there is no borrows
    /// @param _asset Asset address
    function removeAsset(address _asset) external checkAccess(this.removeAsset.selector) {
        LenderStorage storage $ = _getLenderStorage();
        ReserveLogic.removeAsset($.reservesData, $.reservesList, _asset);
    }

    /// @notice Pause an asset from being borrowed
    /// @param _asset Asset address
    /// @param _pause True if pausing or false if unpausing
    function pauseAsset(address _asset, bool _pause) external checkAccess(this.pauseAsset.selector) {
        LenderStorage storage $ = _getLenderStorage();
        ReserveLogic.pauseAsset($.reservesData, _asset, _pause);
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
