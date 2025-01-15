// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { ERC20Upgradeable, IERC20 } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { IOracle } from "../../interfaces/IOracle.sol";
import { AccessUpgradeable } from "../../registry/AccessUpgradeable.sol";
import { Errors } from "../libraries/helpers/Errors.sol";
import { WadRayMath } from "../libraries/math/WadRayMath.sol";

/// @title Restaker debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Restaker debt tokens accrue over time representing the debt in the underlying asset to be
/// paid to the restakers collateralizing an agent
/// @dev Each agent can have a different rate so the weighted mean is used to calculate the total
/// accrued debt. This means that the total supply may not be exact.
contract RestakerDebtToken is UUPSUpgradeable, ERC20Upgradeable, AccessUpgradeable {
    using WadRayMath for uint256;

    /// @custom:storage-location erc7201:cap.storage.RestakerDebt
    struct RestakerDebtStorage {
        address oracle;
        address debtToken;
        address asset;
        uint8 decimals;
        uint256 totalSupply;
        mapping(address => uint256) interestPerSecond;
        mapping(address => uint256) lastAgentUpdate;
        uint256 totalInterestPerSecond;
        uint256 lastUpdate;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("cap.storage.RestakerDebt")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant RestakerDebtStorageLocation = 0x2dd1dd482e00c02bf87ac740376f032edca8a52ab1bbd273a66a2eb62e294e00;

    /// @dev Get this contract storage pointer
    /// @return $ Storage pointer
    function _getRestakerDebtStorage() private pure returns (RestakerDebtStorage storage $) {
        assembly {
            $.slot := RestakerDebtStorageLocation
        }
    }

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the debt token with the underlying asset
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _debtToken Principal debt token
    /// @param _asset Asset address
    function initialize(address _accessControl, address _oracle, address _debtToken, address _asset) external initializer {
        RestakerDebtStorage storage $ = _getRestakerDebtStorage();
        $.oracle = _oracle;
        $.debtToken = _debtToken;
        $.asset = _asset;
        $.decimals = IERC20Metadata(_asset).decimals();

        string memory _name = string.concat("restaker", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("restaker", IERC20Metadata(_asset).symbol());

        __ERC20_init(_name, _symbol);
        __Access_init(_accessControl);
    }

    /// @notice Update the interest per second of the agent and the scaled total supply
    /// @dev Left permissionless
    /// @param _agent Agent address to update interest rate for
    function update(address _agent) external {
        _accrueInterest(_agent);

        RestakerDebtStorage storage $ = _getRestakerDebtStorage();
        uint256 rate = IOracle($.oracle).restakerRate(_agent);
        uint256 oldInterestPerSecond = $.interestPerSecond[_agent];
        uint256 newInterestPerSecond = IERC20($.debtToken).balanceOf(_agent).rayMul(rate);

        $.interestPerSecond[_agent] = newInterestPerSecond;
        $.totalInterestPerSecond = $.totalInterestPerSecond + newInterestPerSecond - oldInterestPerSecond;
    }

    /// @notice Burn the debt token, only callable by the lender
    /// @dev All underlying token transfers are handled by the lender instead of this contract
    /// @param _agent Agent address that will have it's debt repaid
    /// @param _amount Amount of underlying asset to repay to lender
    /// @return actualRepaid Actual amount repaid
    function burn(address _agent, uint256 _amount)
        external
        checkAccess(this.burn.selector)
        returns (uint256 actualRepaid)
    {
        _accrueInterest(_agent);

        uint256 agentBalance = super.balanceOf(_agent);

        actualRepaid = _amount > agentBalance ? agentBalance : _amount;

        if (actualRepaid > 0) {
            _burn(_agent, actualRepaid);

            RestakerDebtStorage storage $ = _getRestakerDebtStorage();
            if (actualRepaid < $.totalSupply) {
                $.totalSupply -= actualRepaid;
            } else {
                $.totalSupply = 0;
            }
        }
    }

    /// @notice Interest accrued by an agent to be repaid to restakers
    /// @param _agent Agent address
    /// @return balance Interest amount
    function balanceOf(address _agent) public view override returns (uint256 balance) {
        RestakerDebtStorage storage $ = _getRestakerDebtStorage();
        uint256 timestamp = block.timestamp;
        if (timestamp > $.lastAgentUpdate[_agent]) {
            balance = super.balanceOf(_agent) + $.interestPerSecond[_agent].rayMul(timestamp - $.lastAgentUpdate[_agent]);
        } else {
            balance = super.balanceOf(_agent);
        }
    }

    /// @notice Total amount of interest accrued by agents
    /// @return supply Total amount of interest
    function totalSupply() public view override returns (uint256 supply) {
        RestakerDebtStorage storage $ = _getRestakerDebtStorage();
        uint256 timestamp = block.timestamp;
        if (timestamp > $.lastUpdate) {
            supply = $.totalSupply + $.totalInterestPerSecond.rayMul(timestamp - $.lastUpdate);
        } else {
            supply = $.totalSupply;
        }
    }

    /// @notice Average rate of all restakers weighted by debt
    /// @param rate Average rate
    function averageRate() external view returns (uint256 rate) {
        RestakerDebtStorage storage $ = _getRestakerDebtStorage();
        uint256 totalDebt = IERC20($.debtToken).totalSupply();
        rate = totalDebt > 0 ? $.totalInterestPerSecond.rayDiv(totalDebt) : 0;
    }

    /// @notice Accrue interest for a specific agent and the total supply
    /// @param _agent Agent address
    function _accrueInterest(address _agent) internal {
        RestakerDebtStorage storage $ = _getRestakerDebtStorage();
        uint256 timestamp = block.timestamp;

        if (timestamp > $.lastAgentUpdate[_agent]) {
            uint256 amount = $.interestPerSecond[_agent].rayMul(timestamp - $.lastAgentUpdate[_agent]);

            if (amount > 0) _mint(_agent, amount);

            $.lastAgentUpdate[_agent] = timestamp;
        }

        if (timestamp > $.lastUpdate) {
            $.totalSupply += $.totalInterestPerSecond.rayMul(timestamp - $.lastUpdate);

            $.lastUpdate = timestamp;
        }
    }

    /// @notice Match decimals with underlying asset
    /// @return decimals
    function decimals() public view override returns (uint8) {
        RestakerDebtStorage storage $ = _getRestakerDebtStorage();
        return $.decimals;
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

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
