// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { BaseMarket } from "../../../../contracts/cap/market/BaseMarket.sol";
import { IBaseMarket } from "../../../../contracts/interfaces/IBaseMarket.sol";
import { BaseTest } from "../../../shared/BaseTest.sol";

contract BareMarket is BaseMarket {
    function initialize(address authority) external initializer {
        __AccessManaged_init(authority);
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
        vm.mockCall(irm, abi.encodeWithSignature("buffer()"), abi.encode(uint256(0.05e27)));
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
