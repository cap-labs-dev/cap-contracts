// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import { Access } from "../../access/Access.sol";
import { IDebtToken } from "../../interfaces/IDebtToken.sol";
import { IOracle } from "../../interfaces/IOracle.sol";
import { DebtTokenStorageUtils } from "../../storage/DebtTokenStorageUtils.sol";

import { MathUtils } from "../libraries/math/MathUtils.sol";
import { WadRayMath } from "../libraries/math/WadRayMath.sol";
import { MintableERC20 } from "./base/MintableERC20.sol";
import { ScaledToken } from "./base/ScaledToken.sol";

/// @title Debt token
/// @author kexley, Cap Labs
/// @notice Debt token for a market on the Lender
contract DebtToken is IDebtToken, UUPSUpgradeable, Access, ScaledToken, DebtTokenStorageUtils {
    using WadRayMath for uint256;

    /// @dev Update the index before minting or burning
    modifier updateIndex() {
        _updateIndex();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @inheritdoc IDebtToken
    function initialize(address _accessControl, address _asset, address _oracle) external initializer {
        DebtTokenStorage storage $ = getDebtTokenStorage();
        $.asset = _asset;
        $.index = 1e27;
        $.lastIndexUpdate = block.timestamp;
        $.oracle = _oracle;

        string memory _name = string.concat("Debt ", IERC20Metadata(_asset).name());
        string memory _symbol = string.concat("debt", IERC20Metadata(_asset).symbol());
        uint8 _decimals = IERC20Metadata(_asset).decimals();

        __ScaledToken_init(_name, _symbol, _decimals);
        __Access_init(_accessControl);
        __UUPSUpgradeable_init();
    }

    /// @inheritdoc IDebtToken
    function mint(address to, uint256 amount) external updateIndex checkAccess(this.mint.selector) {
        _mintScaled(to, amount, getDebtTokenStorage().index);
    }

    /// @inheritdoc IDebtToken
    function burn(address from, uint256 amount) external updateIndex checkAccess(this.burn.selector) {
        _burnScaled(from, amount, getDebtTokenStorage().index);
    }

    /// @inheritdoc IERC20
    function balanceOf(address _agent) public view override(IERC20, MintableERC20) returns (uint256) {
        return _balanceOfScaled(_agent, index());
    }

    /// @inheritdoc IERC20
    function totalSupply() public view override(IERC20, MintableERC20) returns (uint256) {
        return _totalSupplyScaled(index());
    }

    /// @inheritdoc IDebtToken
    function index() public view returns (uint256 currentIndex) {
        DebtTokenStorage storage $ = getDebtTokenStorage();

        currentIndex = $.index;

        if ($.lastIndexUpdate != block.timestamp) {
            currentIndex = currentIndex.rayMul(MathUtils.calculateCompoundedInterest($.interestRate, $.lastIndexUpdate));
        }
    }

    /// @dev Update the index and current interest rate
    function _updateIndex() internal {
        DebtTokenStorage storage $ = getDebtTokenStorage();
        if (super.totalSupply() > 0) $.index = index();
        $.lastIndexUpdate = block.timestamp;
        $.interestRate = _nextInterestRate();
    }

    /// @dev Next interest rate on update, value is encoded in ray (27 decimals) and encodes yearly rates
    /// @return rate Interest rate
    function _nextInterestRate() internal returns (uint256 rate) {
        DebtTokenStorage storage $ = getDebtTokenStorage();
        address _oracle = $.oracle;
        uint256 marketRate = IOracle(_oracle).marketRate($.asset);
        uint256 benchmarkRate = IOracle(_oracle).benchmarkRate($.asset);
        uint256 utilizationRate = IOracle(_oracle).utilizationRate($.asset);

        rate = marketRate > benchmarkRate ? marketRate : benchmarkRate;
        rate += utilizationRate;
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address) internal override checkAccess(bytes4(0)) { }
}
