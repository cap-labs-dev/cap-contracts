// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Errors } from "../lendingPool/libraries/helpers/Errors.sol";
import { WadRayMath } from "../lendingPool/libraries/math/WadRayMath.sol";
import { ILender } from "../interfaces/ILender.sol";
import { IOracle } from "../interfaces/IOracle.sol";
import { IDebtToken } from "../interfaces/IDebtToken.sol";

/// @title Agent debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Agent debt tokens accrue over time representing the debt in the underlying asset to be 
/// paid to the restakers collateralizing an agent
/// @dev Each agent can have a different rate so the weighted mean is used to calculate the total
/// accrued debt. This means that the total supply may not be exact.
contract AgentDebtToken is ERC20Upgradeable {
    using WadRayMath for uint256;

    /// @notice Lender contract
    address public lender;

    /// @notice Principal debt token
    address public debtToken;

    /// @notice asset Underlying asset
    address public asset;

    /// @dev Decimals of the underlying asset
    uint8 private _decimals;

    /// @dev Total supply
    uint256 private _totalSupply;
 
    /// @notice Amount of interest an agent accrues per second
    mapping(address => uint256) public interestPerSecond;

    /// @notice Last time the agent had interest accrued
    mapping(address => uint256) public lastAgentUpdate;

    /// @notice Total amount of interest accrued per second
    uint256 public totalInterestPerSecond;

    /// @notice Last time the total supply was updated
    uint256 public lastUpdate;

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
    /// @param _debtToken Principal debt token
    /// @param asset_ Asset address
    function initialize(address _debtToken, address asset_) external initializer {
        debtToken = _debtToken;
        
        string memory name = string.concat("a", IERC20Metadata(asset_).name());
        string memory symbol = string.concat("a", IERC20Metadata(asset_).symbol());
        _decimals = IERC20Metadata(asset_).decimals();
        asset = asset_;

        __ERC20_init(name, symbol);
        lender = msg.sender;
    }

    /// @notice Update the interest per second of the agent and the scaled total supply
    /// @dev Left permissionless
    /// @param _agent Agent address to update interest rate for
    function update(address _agent) external {
        _accrueInterest(_agent);

        uint256 rate = IOracle(ILender(lender).oracle()).agentRate(_agent);
        uint256 oldInterestPerSecond = interestPerSecond[_agent];
        uint256 newInterestPerSecond = IDebtToken(debtToken).balanceOf(_agent) * rate;

        interestPerSecond[_agent] = newInterestPerSecond;
        totalInterestPerSecond = totalInterestPerSecond + newInterestPerSecond - oldInterestPerSecond;
    }

    /// @notice Burn the debt token, only callable by the lender
    /// @dev All underlying token transfers are handled by the lender instead of this contract
    /// @param _agent Agent address that will have it's debt repaid
    /// @param _amount Amount of underlying asset to repay to lender
    /// @return actualRepaid Actual amount repaid
    function burn(address _agent, uint256 _amount) external onlyLender returns (uint256 actualRepaid) {
        _accrueInterest(_agent);

        uint256 agentBalance = super.balanceOf(_agent);

        actualRepaid = _amount > agentBalance ? agentBalance : _amount;

        if (actualRepaid > 0) {
            _burn(_agent, actualRepaid);
            
            if (actualRepaid < _totalSupply) {
                _totalSupply -= actualRepaid;
            } else {
                _totalSupply = 0;
            }
        }
    }

    /// @notice Interest accrued by an agent to be repaid to restakers
    /// @param _agent Agent address
    /// @return balance Interest amount
    function balanceOf(address _agent) public override view returns (uint256 balance) {
        uint256 timestamp = block.timestamp;
        if (timestamp > lastAgentUpdate[_agent]) {
            balance = super.balanceOf(_agent) 
                + interestPerSecond[_agent].rayMul(timestamp - lastAgentUpdate[_agent]);
        } else {
            balance = super.balanceOf(_agent);
        }
    }

    /// @notice Total amount of interest accrued by agents
    /// @return supply Total amount of interest
    function totalSupply() public override view returns (uint256 supply) {
        uint256 timestamp = block.timestamp;
        if (timestamp > lastUpdate) {
            supply = _totalSupply + totalInterestPerSecond.rayMul(timestamp - lastUpdate);
        } else {
            supply = _totalSupply;
        }
    }

    /// @notice Average rate of all restakers weighted by debt
    /// @param rate Average rate
    function averageRate() external view returns (uint256 rate) {
        uint256 totalDebt = IDebtToken(debtToken).totalSupply();
        rate = totalDebt > 0 ? totalInterestPerSecond.rayDiv(totalDebt) : 0;
    }

    /// @notice Accrue interest for a specific agent and the total supply
    /// @param _agent Agent address
    function _accrueInterest(address _agent) internal {
        uint256 timestamp = block.timestamp;

        if (timestamp > lastAgentUpdate[_agent]) {
            uint256 amount = interestPerSecond[_agent].rayMul(timestamp - lastAgentUpdate[_agent]);
            
            if (amount > 0) _mint(_agent, amount);

            lastAgentUpdate[_agent] = timestamp;
        }

        if (timestamp > lastUpdate) {
            _totalSupply += totalInterestPerSecond.rayMul(timestamp - lastUpdate);

            lastUpdate = timestamp;
        }
    }

    /// @notice Match decimals with underlying asset
    /// @return decimals
    function decimals() public override view returns (uint8) {
        return _decimals;
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
