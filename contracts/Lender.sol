// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessControlEnumerableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IRegistry } from "../interfaces/IRegistry.sol";

/// @title Lender for covered agents
/// @author kexley, @capLabs
/// @notice Whitelisted tokens are borrowed and repaid from this contract by covered agents.
/// @dev Borrow interest rates are calculated from the underlying utilization rates of the assets
/// in the vaults.
contract Lender is Initializable, AccessControlEnumerableUpgradeable {

    struct Reserve {
        uint256 id;
        address vault;
        uint256 borrowIndex;
        uint256 lastUpdate;
        uint256 borrowed;
    }

    struct Agent {
        mapping(uint256 => uint256) principal;
        mapping(uint256 => uint256) restaker;
        mapping(uint256 => uint256) interest;
        mapping(uint256 => uint256) storedBorrowIndex;
        mapping(uint256 => uint256) storedRestakerIndex;
        uint256 restakerIndex;
        uint256 lastUpdate;
    }

    /// @notice Registry that controls whitelisting assets
    IRegistry public registry;

    mapping(address => Reserve) public reserve;
    mapping(address => Agent) public agent;
    mapping(uint256 => address) internal reservesList;
    mapping(address => uint256) internal _agentConfig;
    uint16 internal _reservesCount;

    event Borrow(address indexed asset, address indexed agent, uint256 amount);
    event Repay(
        address indexed asset,
        address indexed agent,
        uint256 principalPaid,
        uint256 restakerPaid,
        uint256 interestPaid
    );
    event Liquidate(address indexed asset, address indexed agent, uint256 amount, uint256 value);
    event AccrueInterest(address indexed asset, address indexed agent, uint256 restakerInterest, uint256 interest);

    /// @notice Initialize the lender
    /// @param _registry Registry address
    function initialize(address _registry) initializer external {
        registry = IRegistry(_registry);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function addAsset(address _asset, address _vault) external returns (bool filled) {
        if (_asset == address(0) || _vault == address(0)) revert EmptyAddress(_asset, _vault);
        if (reserve[_asset].vault != address(0)) revert AlreadyInitialized(_asset);
        uint256 id = reserve[_asset].id;

        for (uint256 i; i < reserveCount; ++i) {
            // Fill empty space if available
            if (reserveList[i] == address(0)) {
                reserveList[i] = _asset;
                filled = true;
                break;
            }
        }

        if (!filled) {
            reserveList[reserveCount] = _asset;
            ++reserveCount;
        }

        reserve[_asset] = Reserve({
            vault: _vault,
            borrowIndex = 1e27,
            lastUpdate = block.timestamp
        });
    }

    function removeAsset(address _asset) external {
        uint256 id = reserve[_asset].id;

        uint256 borrowedBalance = reserve[_asset].borrowed;
        if (borrowedBalance > 0) revert BalanceStillBorrowed(borrowedBalance);

        delete reserveList[id];
        delete reserve[_asset];
    }

    /// @notice Borrow an asset
    /// @param _asset Asset to borrow
    /// @param _amount Amount to borrow
    /// @param _receiver Receiver of the borrowed asset
    function borrow(address _asset, uint256 _amount, address _receiver) external {
        uint256 id = reserveId(_asset);
        _validateBorrow(msg.sender, _asset, _amount);

        bool isFirstBorrow = borrowed(id, msg.sender) == 0;
        if (isFirstBorrow) _agentConfig[msg.sender].setBorrowing(id, true);

        _accrueInterest(id, msg.sender);
        agents[msg.sender].principal[id] += _amount;
        reserve[_asset].borrowed += _amount;
        IVault(reserve[id].vault).borrow(_asset, _amount, _receiver);
        emit Borrow(_asset, msg.sender, _amount);
    }

    /// @notice Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount to repay
    /// @param _onBehalfOf Repay on behalf of another borrower
    /// @return repaid Actual amount repaid
    function repay(
        address _asset,
        uint256 _amount,
        address _onBehalfOf
    ) external returns (uint256 repaid) {
        if (_onBehalfOf == address(0)) _onBehalfOf = msg.sender;
        repaid = _repay(_asset, _amount, _onBehalfOf, msg.sender);
    }

    /// @notice Liquidate an agent when the health is below 1
    /// @param _agent Agent address
    /// @param _asset Asset to repay
    /// @param _debtToCover Amount of asset to repay on behalf of the agent
    /// @param liquidatedValue Value of the liquidation returned to the liquidator
    function liquidate(
        address _agent,
        address _asset,
        uint256 _debtToCover
    ) external returns (uint256 liquidatedValue) {
        (
            uint256 totalCollateral,
            ,
            ,
            ,
            uint256 health
        ) = agentData(_agent);

        if (health >= 1) revert HealthyAgent(health);

        liquidated = _repay(_asset, _debtToCover, _agent, msg.sender);

        uint256 assetPrice = IOracle(oracle).getPrice(_asset);
        liquidatedValue = liquidated * assetPrice;
        if (totalCollateral < liquidatedValue) liquidatedValue = totalCollateral;

        IAvs(avs).slash(_agent, msg.sender, liquidatedValue);
        emit Liquidate(_agent, _asset, liquidated, liquidatedValue);
    }

    /// @dev Repay an asset
    /// @param _asset Asset to repay
    /// @param _amount Amount to repay
    /// @param _agent Repay on behalf of an agent
    /// @param _caller Address that will pay the debt
    /// @return repaid Actual amount repaid
    function _repay(
        address _asset,
        uint256 _amount,
        address _agent,
        address _caller
    ) internal returns (uint256 repaid) {
        uint256 id = reserveId(_asset);
        _accrueInterest(id, _onBehalfOf);

        uint256 principal = agents[_agent].principal[id];
        uint256 restaker = agents[_agent].restaker[id];
        uint256 interest = agents[_agent].interest[id];

        uint256 principalPaid = _amount < principal ? _amount : principal;
        uint256 restakerPaid = _amount - principal < restaker ? _amount - principal : restaker;
        uint256 interestPaid = _amount - principal - restaker < interest ? _amount - principal - restaker : interest;

        repaid = principalPaid + restakerPaid + interestPaid;
        if (repaid == principal + restaker + interest) {
            _agentConfig[_agent].setBorrowing(id, false);
            emit TotalRepayment(_asset, _agent);
        }

        if (principalPaid > 0) {
            agents[_agent].principal[id] -= principalPaid;
            reserve[_asset].borrowed -= principalPaid;
            IERC20(_asset).safeTransferFrom(_caller, address(this), principalPaid);
            IERC20(_asset).forceApprove(reserve[id].vault, principalPaid);
            IVault(reserve[id].vault).repay(_asset, principalPaid);
        }

        if (restakerPaid > 0) {
            agents[_agent].restaker[id] -= restakerPaid;
            IERC20(_asset).safeTransferFrom(_caller, restakerRewarder, restakerPaid);
        }

        if (interestPaid > 0) {
            agents[_agent].interest[id] -= interestPaid;
            IERC20(_asset).safeTransferFrom(_caller, rewarder, interestPaid);
        }

        emit Repay(_asset, _agent, principalPaid, restakerPaid, interestPaid);
    }

    /// @dev Accrue interest to a borrower's balance
    /// @param _id Reserve id of the reserve that has interest
    /// @param _agent Borrower of the asset
    function _accrueInterest(uint256 _id, address _agent) internal {
        _updateIndexes(_id, _agent);

        agents[_agent].restaker[_id] = accruedRestakerInterest(_id, _agent);
        agents[_agent].storedRestakerIndex[id] = agent[_agent].restakerIndex;

        agents[_agent].interest[id] = accruedInterest(_id, _agent);
        agents[_agent].storedBorrowIndex[id] = reserve[_id].borrowIndex;

        emit AccrueInterest(_asset, _agent, agents[_agent].restaker[_id], agents[_agent].interest[_id]);
    }

    /// @dev Update the borrow index of an asset
    /// @param _asset Asset that is borrowed
    function _updateIndexes(uint256 _id, address _agent) internal {
        agent[_agent].restakerIndex *= MathUtils.calculateLinearInterest(
            IAvs(avs).restakerRate(_agent),
            agent[_agent].lastUpdate
        );

        uint256 rate = borrowRate(_id);

        reserve[_id].borrowIndex *= MathUtils.calculateCompoundedInterest(
            rate,
            reserve[_id].lastUpdate
        );

        reserve[_id].lastUpdate = block.timestamp;
        agent[_agent].lastUpdate = block.timestamp;
    }

    /// @notice Fetch the borrow rate based on the highest of either market rate or benchmark yield
    /// @param _asset Asset to borrow
    /// @return rate Borrow rate scaled to 1e27
    function borrowRate(address _asset) public view returns (uint256 rate) {
        uint256 id = reserveId(_asset);
        rate = IOracle(oracle).updateRate(_asset, reserve[id].lastUpdate);
    }

    /// @notice Fetch the amount of restaker interest a borrower has accrued on an asset
    /// @param _id Reserve id
    /// @param _agent Agent that has interest accrued
    /// @return interest Amount of interest accrued
    function accruedRestakerInterest(
        uint256 _id,
        address _agent
    ) public view returns (uint256 restakerInterest) {
        uint256 restakerIndex = agent[_agent].restakerIndex;
        if (agent[_agent].lastUpdate != block.timestamp) {
            restakerIndex *= MathUtils.calculateLinearInterest(
                IAvs(avs).restakerRate(_agent),
                agent[_agent].lastUpdate
            );
        }

        interest = agents[_agent].restaker[_id] + (
            (agents[_agent].principal[_id] ) * ( restakerIndex - agents[_agent].storedRestakerIndex[_id] )
        );
    }

    /// @notice Fetch the amount of interest a borrower has accrued
    /// @param _id Reserve id
    /// @param _agent Borrower of the asset
    /// @return interest Amount of interest accrued
    function accruedInterest(
        uint256 _id,
        address _agent
    ) public view returns (uint256 interest) {
        uint256 borrowIndex = reserve[_id].borrowIndex;
        if (reserve[_id].lastUpdate != block.timestamp) {
            borrowIndex *= MathUtils.calculateCompoundedInterest(
                borrowRate(_id),
                reserve[_id].lastUpdate
            );
        }

        interest = agents[_agent].interest[_id] + (
            (agents[_agent].principal[_id] + agents[_agent].interest[_id] ) 
            * ( borrowIndex - reserve[_id].storedBorrowIndex[_agent] )
        );
    }

    /// @notice Calculate amount borrowed by an agent including interest
    /// @param _asset Asset that was borrowed
    /// @param _agent Borrower of the asset
    /// @return interest Amount of asset borrowed plus interest accrued
    function borrowed(
        address _asset,
        address _agent
    ) external view returns (uint256 borrowed) {
        uint256 id = reserveId(_asset);
        borrowed = agents[_agent].principal[id] 
            + accruedRestakerInterest(id, _agent)
            + accruedInterest(id, _agent);
    }

    /// @notice Calculate the agent data
    /// @param _agent Address of agent
    /// @return totalCollateral Total collateral of an agent
    /// @return totalDebt Total debt of an agent
    /// @return ltv Loan to value ratio
    /// @return liquidationThreshold Liquidation ratio of an agent
    /// @return health Health status of an agent
    function agentData(
        address _agent
    ) external view returns (
        uint256 totalCollateral,
        uint256 totalDebt,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 health
    ) {
        totalCollateral = IAvs(avs).coverage(_agent);
        liquidationThreshold = IAvs(avs).liquidationThreshold(_agent);

        for (uint256 i; i < _reserveCount; ++i) {
            uint256 id = reserveList[i];
            if (!agentConfig.isBorrowing(id)) {
                continue;
            }

            address asset = reserveAsset[id];
            totalDebt += borrowed(id, _agent) * IOracle(oracle).price(asset);
        }

        ltv = totalDebt / totalCollateral;
        health = totalDebt == 0 
            ? type(uint256).max 
            : totalCollateral * liquidationThreshold / totalDebt;
    }

    /// @notice Fetch the amount of asset that is available to borrow
    /// @param _asset Asset to borrow from vault
    function availableBorrow(address _asset) public view returns (uint256 available) {
        available = IVault(reserves[_reserveId[_asset]].vault).balance(_asset);
    }

    /// @notice Reserve id for a given vault and asset
    /// @param _asset Asset address
    /// @return id Id of the reserve
    function reserveId(address _asset) public view returns (uint256 id) {
        id = _reserveId[_asset];
        if (id == 0) revert AssetNotSupported(_asset);
    }

    /// @notice Validate the borrow of an agent
    /// @param _agent Agent making the borrow
    /// @param _id Id of the reserve to borrow from
    /// @param _amount Amount to borrow
    function _validateBorrow(address _agent, address _asset, uint256 _amount) internal {
        uint256 available = availableBorrow(asset);
        if (_amount > available) revert NotEnoughCash(_amount, available);

        (
            uint256 totalCollateral,
            uint256 totalDebt,
            ,
            ,
            uint256 health
        ) = agentData(_agent);

        if (health < 1) revert AgentLiquidatable(health);

        uint256 ltv = IAvs(avs).ltv(_agent);
        uint256 assetPrice = oracle.getPrice(asset);
        uint256 newTotalDebt = ( _amount * assetPrice ) + totalDebt;
        uint256 borrowCapacity = totalCollateral * ltv;
        
        if (newTotalDebt > borrowCapacity) 
            revert BorrowOverCollateralBacking(newTotalDebt, borrowCapacity);
    }
}
