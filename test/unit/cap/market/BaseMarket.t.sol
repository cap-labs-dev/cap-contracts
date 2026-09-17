// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseMarket } from "../../../../contracts/cap/market/BaseMarket.sol";
import { IBaseMarket } from "../../../../contracts/interfaces/IBaseMarket.sol";
import { IInterestRateModel } from "../../../../contracts/interfaces/IInterestRateModel.sol";
import { ITranche } from "../../../../contracts/interfaces/ITranche.sol";
import { BaseTest } from "../../../shared/BaseTest.sol";

contract BareMarket is BaseMarket {
    function initialize(address authority) external initializer {
        __AccessManaged_init(authority);
    }
}

/// @dev Supplies an exact debt boundary without overwriting storage in a concrete market.
contract MarketHealthHarness is BaseMarket {
    uint256 internal debt;

    function initialize(address authority, address registry_) external initializer {
        __BaseMarket_init(authority, registry_, "Health boundary");
    }

    function setDebt(uint256 amount) external {
        debt = amount;
    }

    function totalDebt() public view override returns (uint256) {
        return debt;
    }

    function checkLiquidation() external view returns (uint256) {
        return _checkLiquidation(totalCapital(), debt);
    }
}

contract MarketHealthTest is BaseTest {
    MarketHealthHarness internal market;
    address internal tranche = makeAddr("tranche");

    function setUp() public {
        _setUpAccessManager();
        address registry = makeAddr("registry");
        address irm = makeAddr("irm");
        vm.mockCall(registry, abi.encodeWithSignature("irm()"), abi.encode(irm));
        vm.mockCall(registry, abi.encodeWithSignature("stablecoin()"), abi.encode(makeAddr("stablecoin")));
        vm.mockCall(irm, abi.encodeCall(IInterestRateModel.liquidationThreshold, ()), abi.encode(0.8e27));
        vm.mockCall(irm, abi.encodeCall(IInterestRateModel.buffer, ()), abi.encode(0.1e27));
        vm.mockCall(irm, abi.encodeCall(IInterestRateModel.targetHealth, ()), abi.encode(1.25e27));
        vm.mockCall(irm, abi.encodeWithSignature("liquidationBonus()"), abi.encode(0.1e27));
        market = MarketHealthHarness(
            _deployProxy(
                address(new MarketHealthHarness()),
                abi.encodeCall(MarketHealthHarness.initialize, (address(accessManager), registry))
            )
        );
        vm.mockCall(tranche, abi.encodeCall(ITranche.market, ()), abi.encode(address(market)));
        vm.mockCall(tranche, abi.encodeCall(ITranche.totalCapital, ()), abi.encode(10e27));
        IBaseMarket.Tranche[] memory ts = new IBaseMarket.Tranche[](1);
        ts[0] = IBaseMarket.Tranche(tranche, RAY);
        market.setTranches(ts);
    }

    function test_oneWeiOverThresholdIsUnhealthyEvenWhenHalfUpWouldSayOneRay() public {
        market.setDebt(8e27 + 1);
        assertEq(market.healthiness(), RAY - 1);
        assertGt(market.checkLiquidation(), 0);
        assertGt(market.maxLiquidatable(), 0);
    }

    function test_exactThresholdAndZeroDebtRemainHealthy() public {
        assertEq(market.healthiness(), RAY);
        assertEq(market.maxLiquidatable(), 0);
        market.setDebt(8e27);
        assertEq(market.healthiness(), RAY);
        assertEq(market.maxLiquidatable(), 0);
        vm.expectRevert(IBaseMarket.Healthy.selector);
        market.checkLiquidation();
    }

    function test_maxLiquidatableValuesCollateralOnce() public {
        market.setDebt(9e27);
        vm.expectCall(tranche, abi.encodeCall(ITranche.totalCapital, ()), uint64(1));
        assertGt(market.maxLiquidatable(), 0);
    }

    function testFuzz_healthAgreesWithExactDebtThreshold(uint96 rawDebt) public {
        uint256 debt = bound(rawDebt, 1, 20e27);
        market.setDebt(debt);
        assertEq(market.healthiness() >= RAY, debt <= 8e27);
    }
}

contract ChargeableMarket is BaseMarket {
    function initialize(address authority, address registry, string memory name) external initializer {
        __BaseMarket_init(authority, registry, name);
    }

    function charge(uint256 liquidityPremium, uint256 underwriterPremium) external {
        _chargePremium(liquidityPremium, underwriterPremium);
    }
}

/// @notice Hits the empty {BaseMarket-totalDebt} body that every concrete market overrides.
contract BaseMarketTest is BaseTest {
    address internal registry = makeAddr("registry");
    address internal irm = makeAddr("irm");
    address internal scoin = makeAddr("stablecoin");

    function test_baseTotalDebtIsZero() public {
        _setUpAccessManager();
        BareMarket market = BareMarket(
            _deployProxy(address(new BareMarket()), abi.encodeCall(BareMarket.initialize, (address(accessManager))))
        );
        assertEq(market.totalDebt(), 0);
    }

    function test_unsetMarketMultiplierReadsAsOneRay() public {
        _setUpAccessManager();
        BareMarket market = BareMarket(
            _deployProxy(address(new BareMarket()), abi.encodeCall(BareMarket.initialize, (address(accessManager))))
        );
        assertEq(market.marketMultiplier(), 1e27);
    }

    /// @dev Liquidity premium is its own event. It always funds the stablecoin.
    function test_chargePremium_emitsLiquiditySeparately() public {
        (ChargeableMarket market,,) = _readyMarket(true, true);

        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeLiquidityPremium(10e18);
        market.charge(10e18, 0);
    }

    /// @dev Live junior takes its weight; leftover goes to a live senior. Not liquidity.
    function test_chargePremium_emitsUnderwriterToTranches() public {
        (ChargeableMarket market, MockEarnTranche senior, MockEarnTranche junior) = _readyMarket(true, true);

        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeLiquidityPremium(10e18);
        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeUnderwriterPremium(address(junior), 20e18);
        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeUnderwriterPremium(address(senior), 80e18);
        market.charge(10e18, 100e18);
    }

    /// @dev No earning senior: leftover vests on cUSD, so it is recorded as liquidity premium.
    function test_chargePremium_fallbackToStablecoinIsLiquidity() public {
        (ChargeableMarket market,, MockEarnTranche junior) = _readyMarket(false, true);

        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeLiquidityPremium(10e18);
        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeUnderwriterPremium(address(junior), 20e18);
        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeLiquidityPremium(80e18);
        market.charge(10e18, 100e18);
    }

    /// @dev No earning tranche: the whole underwriter pot vests on cUSD as liquidity premium.
    function test_chargePremium_allUnallocatedVestsAsLiquidity() public {
        (ChargeableMarket market,,) = _readyMarket(false, false);

        vm.expectEmit(address(market));
        emit IBaseMarket.ChargeLiquidityPremium(100e18);
        market.charge(0, 100e18);
    }

    function _readyMarket(bool seniorEarns, bool juniorEarns)
        internal
        returns (ChargeableMarket market, MockEarnTranche senior, MockEarnTranche junior)
    {
        _setUpAccessManager();
        vm.mockCall(registry, abi.encodeWithSignature("irm()"), abi.encode(irm));
        vm.mockCall(registry, abi.encodeWithSignature("stablecoin()"), abi.encode(scoin));
        vm.mockCall(irm, abi.encodeWithSignature("liquidationThreshold()"), abi.encode(uint256(0.9e27)));
        vm.mockCall(irm, abi.encodeWithSignature("buffer()"), abi.encode(uint256(0.1e27)));
        vm.mockCall(irm, abi.encodeWithSignature("targetHealth()"), abi.encode(uint256(1.25e27)));
        vm.mockCall(scoin, abi.encodeWithSignature("fundCreditBacked(uint256)"), "");
        vm.mockCall(scoin, abi.encodeWithSignature("mintCreditBacked(address,uint256)"), "");

        market = ChargeableMarket(
            _deployProxy(
                address(new ChargeableMarket()),
                abi.encodeCall(ChargeableMarket.initialize, (address(accessManager), registry, "Charge"))
            )
        );

        senior = new MockEarnTranche(address(market));
        junior = new MockEarnTranche(address(market));
        if (!seniorEarns) senior.setEarning(false);
        if (!juniorEarns) junior.setEarning(false);

        IBaseMarket.Tranche[] memory ts = new IBaseMarket.Tranche[](2);
        ts[0] = IBaseMarket.Tranche({ tranche: address(senior), weight: 0.8e27 });
        ts[1] = IBaseMarket.Tranche({ tranche: address(junior), weight: 0.2e27 });
        market.setTranches(ts);
    }
}

/// @dev Eligibility knobs for {_earnsPremium}: killed / staked / assets.
contract MockEarnTranche {
    address public market;
    bool public killed;
    uint256 public stakedSupply = 1e18;
    uint256 public totalAssets = 1e18;

    constructor(address market_) {
        market = market_;
    }

    function setEarning(bool earning) external {
        killed = !earning;
        stakedSupply = earning ? 1e18 : 0;
        totalAssets = earning ? 1e18 : 0;
    }

    function fund(uint256) external { }
}
