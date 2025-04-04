// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC20Upgradeable, IERC20, ScaledToken } from "./base/ScaledToken.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Access } from "../../access/Access.sol";

import { IInterestDebtToken } from "../../interfaces/IInterestDebtToken.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { IPrincipalDebtToken } from "../../interfaces/IPrincipalDebtToken.sol";
import { InterestDebtTokenStorageUtils } from "../../storage/InterestDebtTokenStorageUtils.sol";
import { MathUtils, WadRayMath } from "../libraries/math/MathUtils.sol";

/// @title Interest debt token for a market on the Lender
/// @author kexley, @capLabs
/// @notice Interest debt tokens accrue over time representing the debt in the underlying asset to be
/// paid to the fee auction
/// @dev Scaled balance is the principal debt + interest, scaled by the index which represents the
/// compounded interest rate
contract InterestDebtToken is
    IInterestDebtToken,
    UUPSUpgradeable,
    ScaledToken,
    Access,
    InterestDebtTokenStorageUtils
{
    using WadRayMath for uint256;

    /// @dev Disable initializers on the implementation
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize the debt token with the underlying asset
    /// @param _accessControl Access control address
    /// @param _oracle Oracle address
    /// @param _debtToken Principal debt token
    /// @param _asset Asset address
    function initialize(address _accessControl, address _oracle, address _debtToken, address _asset)
        external
        initializer
    {
        InterestDebtTokenStorage storage $ = getInterestDebtTokenStorage();
        $.asset = _asset;
        $.debtToken = _debtToken;
        $.decimals = IERC20Metadata(_asset).decimals();
        $.oracle = _oracle;
        $.index = 1e27;
        $.lastIndexUpdate = block.timestamp;

        string memory name = string.concat("interest", IERC20Metadata(_asset).name());
        string memory symbol = string.concat("interest", IERC20Metadata(_asset).symbol());

        __Access_init(_accessControl);
        __ScaledToken_init(name, symbol);
        __UUPSUpgradeable_init();
    }

    /// @notice Get the current balance of the agent
    /// @param _agent Agent address
    /// @return balance The balance of the agent
    function balanceOf(address _agent) public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return _balanceOf(_agent, index());
    }

    /// @notice Get the current total supply of the token
    /// @return totalSupply The total supply of the token
    function totalSupply() public view override(ERC20Upgradeable, IERC20) returns (uint256) {
        return _totalSupply(index());
    }

    /// @notice Accrue interest and update the scaled balance of the agent
    /// @dev Must be called after principal debt change
    /// @param _agent Agent address
    function update(address _agent) public {
        InterestDebtTokenStorage storage $ = getInterestDebtTokenStorage();
        uint256 amount = balanceOf(_agent) + IERC20Metadata($.debtToken).balanceOf(_agent);
        _update(_agent, amount, index());
        $.index = index();
        $.interestRate = _nextInterestRate();
        $.lastIndexUpdate = block.timestamp;
    }

    /// @notice Burn interest from the agent's balance
    /// @param _agent Agent address
    /// @param _amount Amount to burn
    function burn(address _agent, uint256 _amount) external checkAccess(this.burn.selector) {
        update(_agent);
        _burnFrom(_agent, _amount);
    }

    /// @notice Get the current index
    /// @return currentIndex The current index
    function index() public view returns (uint256 currentIndex) {
        InterestDebtTokenStorage storage $ = getInterestDebtTokenStorage();

        currentIndex = $.index;

        if ($.lastIndexUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.interestRate, $.lastIndexUpdate));
        }
    }

    /// @notice Next interest rate on update
    /// @dev Value is encoded in ray (27 decimals) and encodes yearly rates
    /// @param rate Interest rate
    function _nextInterestRate() internal returns (uint256 rate) {
        InterestDebtTokenStorage storage $ = getInterestDebtTokenStorage();
        address _oracle = $.oracle;
        uint256 marketRate = IOracle(_oracle).marketRate($.asset);
        uint256 benchmarkRate = IOracle(_oracle).benchmarkRate($.asset);
        uint256 utilizationRate = IOracle(_oracle).utilizationRate($.asset);

        rate = marketRate > benchmarkRate ? marketRate : benchmarkRate;
        rate += utilizationRate;
    }

    /// @notice Get the asset address
    /// @return asset The asset address
    function asset() external view returns (address) {
        return getInterestDebtTokenStorage().asset;
    }

    /// @notice Get the debt token address
    /// @return debtToken The debt token address
    function debtToken() external view returns (address) {
        return getInterestDebtTokenStorage().debtToken;
    }

    /// @notice Get the decimals of the token
    /// @return decimals The decimals of the token
    function decimals() public view override returns (uint8) {
        return getInterestDebtTokenStorage().decimals;
    }

    /// @notice Get the oracle address
    /// @return oracle The oracle address
    function oracle() external view returns (address) {
        return getInterestDebtTokenStorage().oracle;
    }

    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
