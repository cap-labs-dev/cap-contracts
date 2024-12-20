// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { Errors } from "./libraries/helpers/Errors.sol";
import { MathUtils } from "./libraries/math/MathUtils.sol";
import { ILender } from "./interfaces/ILender.sol";
import { IOracle } from "./interfaces/IOracle.sol";

contract pToken is ERC20Upgradeable {

    address public lender;
    address public asset;
    uint8 _decimals;

    mapping(address => uint256) public marketInterest;
    mapping(address => uint256) public storedMarketIndex;
    mapping(address => uint256) public lastMarketUpdate;

    mapping(address => uint256) public agentInterest;
    mapping(address => uint256) public storedAgentIndex;
    mapping(address => uint256) public lastAgentUpdate;

    modifier onlyLender() {
        require(msg.sender == lender, Errors.CALLER_NOT_POOL_OR_EMERGENCY_ADMIN);
        _;
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    function initialize(address asset_) external initializer {
        string memory name = string.concat("p", IERC20Metadata(asset_).name());
        string memory symbol = string.concat("p", IERC20Metadata(asset_).symbol());
        _decimals = IERC20Metadata(asset_).decimals();
        asset = asset_;

        __ERC20_init(name, symbol);
        lender = msg.sender;
    }

    function decimals() public override view returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external onlyLender {
        _accrueInterest(to);

        _mint(to, amount);
    }

    function burn(
        address from,
        uint256 amount,
        uint256 interest
    ) external onlyLender returns (uint256 paybackMarket, uint256 paybackAgent) {
        _accrueInterest(from);
        if (interest > 0) (paybackMarket, paybackAgent) = _repayInterest(from, interest);
        if (amount > 0) _burn(from, amount);
    }

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

    function totalBalanceOf(address _agent) external view returns (uint256 balance) {
        balance = balanceOf(_agent) + accruedInterest(_agent) + accruedAgentInterest(_agent);
    }

    function accruedInterest(address _agent) public view returns (uint256 interest) {
        interest = marketInterest[_agent];

        if (block.timestamp != lastMarketUpdate[_agent]) {
            address oracle = ILender(lender).oracle();
            uint256 marketIndex = IOracle(oracle).marketIndex(asset);

            uint256 marketRate = ( marketIndex - storedMarketIndex[_agent] ) 
                / ( block.timestamp - lastMarketUpdate[_agent] );

            uint256 compoundedIncrease = MathUtils.calculateCompoundedInterest(
                marketRate,
                lastMarketUpdate[_agent]
            );

            interest += (interest + balanceOf(_agent)) * compoundedIncrease;
        }
    }

    function accruedAgentInterest(address _agent) public view returns (uint256 interest) {
        interest = agentInterest[_agent];

        if (block.timestamp != lastAgentUpdate[_agent]) {
            address oracle = ILender(lender).oracle();
            uint256 agentIndex = IOracle(oracle).agentIndex(asset);

            uint256 agentRate = ( agentIndex - storedAgentIndex[_agent] ) 
                / ( block.timestamp - lastAgentUpdate[_agent] );

            uint256 compoundedIncrease = MathUtils.calculateLinearInterest(
                agentRate,
                lastAgentUpdate[_agent]
            );

            interest += balanceOf(_agent) * compoundedIncrease;
        }
    }

    function _accrueInterest(address _agent) internal {
        address oracle = ILender(lender).oracle();
        marketInterest[_agent] = accruedInterest(_agent);
        agentInterest[_agent] = accruedAgentInterest(_agent);

        storedMarketIndex[_agent] = IOracle(oracle).marketIndex(asset);
        storedAgentIndex[_agent] = IOracle(oracle).agentIndex(_agent);
        lastMarketUpdate[_agent] = lastAgentUpdate[_agent] = block.timestamp;
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function allowance(address, address) public pure override returns (uint256) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert(Errors.OPERATION_NOT_SUPPORTED);
    }
}
