// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20Upgradeable, IERC20} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {AccessUpgradeable} from "../../registry/AccessUpgradeable.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {MathUtils} from "../libraries/math/MathUtils.sol";
import {WadRayMath} from "../libraries/math/WadRayMath.sol";
import {IAddressProvider} from "../../interfaces/IAddressProvider.sol";
import {IRateOracle} from "../../interfaces/IRateOracle.sol";

/// @title Interest debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Compound interest accrues for agents borrowing an asset.
/// @dev Total supply is calculated therefore an estimation rather than exact.
contract InterestDebtToken is ERC20Upgradeable, AccessUpgradeable {
    using MathUtils for uint256;
    using WadRayMath for uint256;

    /// @notice Address provider
    IAddressProvider public addressProvider;

    /// @notice Principal debt token
    address public debtToken;

    /// @notice asset Underlying asset
    address public asset;

    /// @dev Decimals of the underlying asset
    uint8 private _decimals;

    /// @dev Total supply
    uint256 private _totalSupply;

    /// @notice Interest rate
    uint256 public interestRate;

    /// @notice Current index at time of last agent update
    mapping(address => uint256) public storedIndex;

    /// @notice Last time the agent had interest accrued
    mapping(address => uint256) public lastAgentUpdate;

    /// @notice Last time the total supply was updated
    uint256 public lastUpdate;

    /// @notice Interest rate index,
    uint256 public index;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the interest debt token with the underlying asset
    /// @param _addressProvider Address provider
    /// @param _debtToken Principal debt token
    /// @param _asset Asset address
    function initialize(
        address _addressProvider,
        address _debtToken,
        address _asset
    ) external initializer {
        addressProvider = IAddressProvider(_addressProvider);
        debtToken = _debtToken;

        string memory _name = string.concat("interest", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("interest", IERC20Metadata(_asset).symbol());
        _decimals = IERC20Metadata(_asset).decimals();
        asset = _asset;
        index = 1e27;

        __ERC20_init(_name, _symbol);
        __Access_init(addressProvider.accessControl());
    }

    /// @notice Update the accrued interest and the interest rate
    /// @dev Left permissionless
    /// @param _agent Agent address to accrue interest for
    function update(address _agent) external {
        _update(_agent);
    }

    /// @notice Interest rate index representing the increase of debt per asset borrowed
    /// @dev A value of 1e27 means there is no debt. As time passes, the debt is accrued. A value
    /// of 2*1e27 means that for each unit of debt, one unit worth of interest has been accumulated
    /// @return latestIndex Current interest rate index
    function currentIndex() public view returns (uint256 latestIndex) {
        uint256 timestamp = block.timestamp;
        if (timestamp != lastUpdate) {
            latestIndex = MathUtils.calculateCompoundedInterest(interestRate, lastUpdate).rayMul(index);
        } else {
            latestIndex = index;
        }
    }

    /// @notice Burn the debt token, only callable by the lender
    /// @dev All underlying token transfers are handled by the lender instead of this contract
    /// @param _agent Agent address that will have it's debt repaid
    /// @param _amount Amount of underlying asset to repay to lender
    /// @return actualRepaid Actual amount repaid
    function burn(
        address _agent,
        uint256 _amount
    ) external checkRole(this.burn.selector) returns (uint256 actualRepaid) {
        _update(_agent);

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
    function balanceOf(address _agent) public view override returns (uint256 balance) {
        uint256 timestamp = block.timestamp;
        if (timestamp > lastAgentUpdate[_agent]) {
            balance = super.balanceOf(_agent)
                + (IERC20(debtToken).balanceOf(_agent) + super.balanceOf(_agent)).rayMul(
                    currentIndex() - storedIndex[_agent]
                );
        } else {
            balance = super.balanceOf(_agent);
        }
    }

    /// @notice Total amount of interest accrued by agents
    /// @return supply Total amount of interest
    function totalSupply() public view override returns (uint256 supply) {
        uint256 timestamp = block.timestamp;

        if (timestamp > lastUpdate) {
            supply = _totalSupply + (IERC20(debtToken).totalSupply() + _totalSupply).rayMul(currentIndex() - index);
        } else {
            supply = _totalSupply;
        }
    }

    /// @notice Next interest rate on update
    /// @param rate Interest rate
    function nextInterestRate() public view returns (uint256 rate) {
        address oracle = addressProvider.rateOracle();
        uint256 marketRate = IRateOracle(oracle).marketRate(asset);
        uint256 benchmarkRate = IRateOracle(oracle).benchmarkRate(asset);

        rate = marketRate > benchmarkRate ? marketRate : benchmarkRate;
    }

    /// @notice Accrue interest for a specific agent and the total supply
    /// @param _agent Agent address
    function _update(address _agent) internal {
        uint256 timestamp = block.timestamp;

        if (timestamp > lastAgentUpdate[_agent]) {
            uint256 amount = (IERC20(debtToken).balanceOf(_agent) + super.balanceOf(_agent)).rayMul(
                currentIndex() - storedIndex[_agent]
            );

            if (amount > 0) _mint(_agent, amount);

            storedIndex[_agent] = currentIndex();
            lastAgentUpdate[_agent] = timestamp;
        }

        if (timestamp > lastUpdate) {
            _totalSupply += (IERC20(debtToken).totalSupply() + _totalSupply).rayMul(currentIndex() - index);

            index = currentIndex();

            lastUpdate = timestamp;
        }

        interestRate = nextInterestRate();
    }

    /// @notice Match decimals with underlying asset
    /// @return decimals
    function decimals() public view override returns (uint8) {
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
