// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Errors } from "../lendingPool/libraries/helpers/Errors.sol";
import { MathUtils } from "../lendingPool/libraries/math/MathUtils.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IOracle } from "../interfaces/IOracle.sol";

/// @title Debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Debt tokens are minted 1:1 with the principal loan amount
/// @dev Asset interest is calculated from the oracle returning both the market rate and the benchmark
/// rate and taking the higher of the two. Interest is returned to a rewarder to be converted into
/// cTokens and distributed via ERC4626. Restaker interest is calculated from the agent specific index
/// in the oracle and sent to an agent specific rewarder.
contract DebtToken is ERC20Upgradeable {

    /// @notice Lender contract
    address public lender;

    /// @notice asset Underlying asset
    address public asset;

    /// @dev Decimals of the underlying asset
    uint8 private _decimals;

    /// @notice Recorded amount of interest an agent has accrued
    mapping(address => uint256) public marketInterest;

    /// @notice Stored market index at the last time the agent interacted the market
    mapping(address => uint256) public storedMarketIndex;

    /// @notice Recorded amount of restaker interest an agent has accrued 
    mapping(address => uint256) public agentInterest;

    /// @notice Stored agent index at the last time the agent interacted the market
    mapping(address => uint256) public storedAgentIndex;

    /// @notice Last time the agent interacted with the market
    mapping(address => uint256) public lastUpdate;

    /// @dev Only the lender can use these functions
    modifier onlyLender() {
        require(msg.sender == lender, Errors.CALLER_NOT_POOL_OR_EMERGENCY_ADMIN);
        _;
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the debt token with the underlying asset
    /// @param asset_ Asset address
    function initialize(address asset_) external initializer {
        string memory name = string.concat("p", IERC20Metadata(asset_).name());
        string memory symbol = string.concat("p", IERC20Metadata(asset_).symbol());
        _decimals = IERC20Metadata(asset_).decimals();
        asset = asset_;

        __ERC20_init(name, symbol);
        lender = msg.sender;
    }

    /// @notice Match decimals with underlying asset
    /// @return decimals
    function decimals() public override view returns (uint8) {
        return _decimals;
    }

    /// @notice Lender will mint debt tokens to match the amount borrowed by an agent. Interest and
    /// restaker interest is accrued to the agent.
    /// @param to Address to mint tokens to
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external onlyLender {
        _accrueInterest(to);

        _mint(to, amount);
    }

    /// @notice Lender will burn debt tokens when the principal debt is repaid by an agent. Interest 
    /// can be repaid or not. Unpaid interest will accrue more interest.
    /// @param from Burn tokens from agent
    /// @param amount Amount to burn
    /// @param interest Amount of interest to repay
    /// @return paybackMarket Amount of market interest that is repaid
    /// @return paybackAgent Amount of restaker interest that is repaid
    function burn(
        address from,
        uint256 amount,
        uint256 interest
    ) external onlyLender returns (uint256 paybackMarket, uint256 paybackAgent) {
        _accrueInterest(from);
        if (interest > 0) (paybackMarket, paybackAgent) = _repayInterest(from, interest);
        if (amount > 0) _burn(from, amount);
    }

    /// @dev Repay market and restaker interest, but do not overpay
    /// @param _agent Agent address
    /// @param _amount Amount of interest to repay
    /// @return paybackMarket Amount of market interest actually repaid
    /// @return paybackAgent Amount of restaker interest actually repaid
    function _repayInterest(
        address _agent,
        uint256 _amount
    ) internal returns (uint256 paybackMarket, uint256 paybackAgent) {
        paybackMarket = _amount;
        if (paybackMarket > marketInterest[_agent]) {
            paybackMarket = marketInterest[_agent];
        }
        marketInterest[_agent] -= paybackMarket;

        paybackAgent = _amount - paybackMarket;
        if (paybackAgent > agentInterest[_agent]) {
            paybackAgent = agentInterest[_agent];
        }
        agentInterest[_agent] -= paybackAgent;
    }

    /// @notice Total underlying asset debt owed by an agent including all interest
    /// @param _agent Agent address
    /// @return balance Total debt
    function totalBalanceOf(address _agent) external view returns (uint256 balance) {
        balance = balanceOf(_agent) + accruedInterest(_agent) + accruedAgentInterest(_agent);
    }

    /// @notice Current total accrued market interest for an agent
    /// @param _agent Agent address
    /// @return interest Accrued market interest
    function accruedInterest(address _agent) public view returns (uint256 interest) {
        interest = marketInterest[_agent];

        if (block.timestamp != lastUpdate[_agent]) {
            address oracle = ILender(lender).oracle();
            uint256 marketIndex = IOracle(oracle).marketIndex(asset);

            uint256 marketRate = ( marketIndex - storedMarketIndex[_agent] ) 
                / ( block.timestamp - lastUpdate[_agent] );

            uint256 compoundedIncrease = MathUtils.calculateCompoundedInterest(
                marketRate,
                lastUpdate[_agent]
            );

            interest += (interest + balanceOf(_agent)) * compoundedIncrease;
        }
    }

    /// @notice Current total accrued restaker interest for an agent
    /// @param _agent Agent address
    /// @return interest Accrued restaker interest
    function accruedAgentInterest(address _agent) public view returns (uint256 interest) {
        interest = agentInterest[_agent];

        if (block.timestamp != lastUpdate[_agent]) {
            address oracle = ILender(lender).oracle();
            uint256 agentIndex = IOracle(oracle).agentIndex(asset);

            uint256 agentRate = ( agentIndex - storedAgentIndex[_agent] ) 
                / ( block.timestamp - lastUpdate[_agent] );

            uint256 compoundedIncrease = MathUtils.calculateLinearInterest(
                agentRate,
                lastUpdate[_agent]
            );

            interest += balanceOf(_agent) * compoundedIncrease;
        }
    }

    /// @dev Accrue interest into storage when the agent makes any balance changes
    /// @param _agent Agent address
    function _accrueInterest(address _agent) internal {
        address oracle = ILender(lender).oracle();
        marketInterest[_agent] = accruedInterest(_agent);
        agentInterest[_agent] = accruedAgentInterest(_agent);

        storedMarketIndex[_agent] = IOracle(oracle).marketIndex(asset);
        storedAgentIndex[_agent] = IOracle(oracle).agentIndex(_agent);
        lastUpdate[_agent] = block.timestamp;
    }

    /// @notice Disabled due to this being a non-transferrable token
    function transfer(address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to this being a non-transferrable token
    function allowance(address, address) public pure override returns (uint256) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to this being a non-transferrable token
    function approve(address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    /// @notice Disabled due to this being a non-transferrable token
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }
}
