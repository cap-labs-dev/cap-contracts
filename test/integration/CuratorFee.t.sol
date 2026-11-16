// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Tranche } from "../../contracts/cap/Tranche.sol";
import { Underwriter } from "../../contracts/cap/Underwriter.sol";
import { FloatingMarket } from "../../contracts/cap/market/FloatingMarket.sol";
import { IInterestRateModel } from "../../contracts/interfaces/IInterestRateModel.sol";
import { IUnderwriter } from "../../contracts/interfaces/IUnderwriter.sol";
import { CapDeployer } from "../shared/CapDeployer.sol";
import { IAccessManaged } from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/// @notice The curator fee is paid in cUSD out of premium as the Underwriter harvests it, before the
/// rest vests to the pool. It is taken once per claim at the rate then in force.
contract CuratorFeeTest is CapDeployer {
    address internal borrower = makeAddr("borrower");
    address internal depositor = makeAddr("depositor");
    address internal recipient = makeAddr("curator fee recipient");
    FloatingMarket internal market;
    Tranche internal tranche0;
    Underwriter internal underwriter;

    function setUp() public {
        _deployCap();
        (address marketAddr, address t0,) = _createMarket("Curator fee");
        market = FloatingMarket(marketAddr);
        tranche0 = Tranche(t0);
        _setMarketSlopes(marketAddr);
        irm.setLiquiditySlopes(
            IInterestRateModel.Slopes({ base: 0.05e27, slope0: 0.05e27, slope1: 0.1e27, kink: 0.8e27 })
        );
        market.setMarketMultiplier(1e27);
        _setMaxCapital(market, 1_000e18);

        underwriter = _deployUnderwriter();
        _admitDepositor(address(tranche0), address(underwriter));
        underwriter.addTranche(address(tranche0));
        underwriter.setDefaultTranche(address(tranche0));
        _fundUnderwriter(address(underwriter), depositor, 1_000e18);
    }

    /// @dev Borrow, let a year of premium accrue, and let it fully vest on the tranche.
    function _accruePremium() internal returns (uint256 claimable) {
        vm.prank(borrower);
        market.borrow(borrower, 400e18);
        vm.warp(block.timestamp + 365 days);
        market.chargePremium();
        vm.warp(block.timestamp + 40 * tranche0.vestingPeriod());
        claimable = tranche0.claimable(address(underwriter));
        assertGt(claimable, 0);
    }

    function test_defaultsOff() public view {
        assertEq(underwriter.curatorFeeRecipient(), address(0));
        assertEq(underwriter.curatorFeeRate(), 0);
        assertEq(underwriter.MAX_CURATOR_FEE(), 0.5e27);
    }

    function test_setCuratorFee_curatorSetsAndEmits() public {
        vm.expectEmit(address(underwriter));
        emit IUnderwriter.SetCuratorFee(recipient, 0.2e27);
        underwriter.setCuratorFee(recipient, 0.2e27);
        assertEq(underwriter.curatorFeeRecipient(), recipient);
        assertEq(underwriter.curatorFeeRate(), 0.2e27);

        underwriter.setCuratorFee(address(0), 0);
        assertEq(underwriter.curatorFeeRecipient(), address(0));
        assertEq(underwriter.curatorFeeRate(), 0);
    }

    function test_setCuratorFee_validation() public {
        vm.expectRevert(IUnderwriter.InvalidCuratorFee.selector);
        underwriter.setCuratorFee(recipient, 0.5e27 + 1);
        vm.expectRevert(IUnderwriter.CuratorFeeRecipientRequired.selector);
        underwriter.setCuratorFee(address(0), 1);
        underwriter.setCuratorFee(recipient, 0.5e27);
    }

    function test_setCuratorFee_onlyCurator() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, stranger));
        underwriter.setCuratorFee(recipient, 0.1e27);
        // the keeper who reports is not the curator either
        address keeper = makeAddr("keeper");
        _grantKeeper(keeper);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, keeper));
        underwriter.setCuratorFee(recipient, 0.1e27);
    }

    function test_report_paysFeeInCusdAndVestsTheRest() public {
        underwriter.setCuratorFee(recipient, 0.2e27);
        uint256 premium = _accruePremium();
        uint256 fee = _rayMul(premium, 0.2e27);

        vm.expectEmit(address(underwriter));
        emit IUnderwriter.ChargeCuratorFee(address(tranche0), recipient, fee);
        underwriter.report(address(tranche0));

        assertEq(stablecoin.balanceOf(recipient), fee);
        assertEq(stablecoin.balanceOf(address(underwriter)), premium - fee);
        // the pot the depositors vest from is the net amount
        assertEq(underwriter.remaining() + underwriter.vested(), premium - fee);
        // the recipient holds plain cUSD, nothing is owed to it by the pool
        assertEq(underwriter.pendingPremium(recipient), 0);

        vm.warp(block.timestamp + 40 * underwriter.vestingPeriod());
        vm.prank(depositor);
        underwriter.claim(depositor);
        assertApproxEqRel(stablecoin.balanceOf(depositor), premium - fee, 1e12);
    }

    function test_report_feeOffPaysNothing() public {
        uint256 premium = _accruePremium();
        underwriter.report(address(tranche0));
        assertEq(stablecoin.balanceOf(recipient), 0);
        assertEq(stablecoin.balanceOf(address(underwriter)), premium);
    }

    function test_rateChangeDoesNotReachFundedPremium() public {
        uint256 premium = _accruePremium();
        underwriter.report(address(tranche0));
        assertEq(stablecoin.balanceOf(address(underwriter)), premium);

        underwriter.setCuratorFee(recipient, 0.5e27);
        // nothing new to claim: a fresh report pays no fee and leaves the funded pot alone
        underwriter.report(address(tranche0));
        assertEq(stablecoin.balanceOf(recipient), 0);
        assertEq(stablecoin.balanceOf(address(underwriter)), premium);
    }

    function test_feeStacksOnTopOfProtocolFee() public {
        address protocol = makeAddr("protocol fee receiver");
        registry.setProtocolFee(protocol, 0, 0.25e27);
        underwriter.setCuratorFee(recipient, 0.2e27);

        uint256 premium = _accruePremium();
        underwriter.report(address(tranche0));

        // the tranche only ever saw the post-protocol-fee premium; the curator takes 20% of that
        uint256 protocolTake = stablecoin.balanceOf(protocol);
        assertGt(protocolTake, 0);
        uint256 fee = _rayMul(premium, 0.2e27);
        assertEq(stablecoin.balanceOf(recipient), fee);
        assertEq(stablecoin.balanceOf(address(underwriter)), premium - fee);
    }

    /// @dev Half-up ray multiplication, as {WadRayMath-rayMul}
    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * b + 0.5e27) / 1e27;
    }

    function testFuzz_feePlusPotEqualsClaimed(uint64 rawRate) public {
        uint256 rate = bound(rawRate, 0, 0.5e27);
        underwriter.setCuratorFee(recipient, rate);
        uint256 premium = _accruePremium();
        underwriter.report(address(tranche0));
        assertEq(stablecoin.balanceOf(recipient) + stablecoin.balanceOf(address(underwriter)), premium);
        assertLe(stablecoin.balanceOf(recipient), (premium + 1) / 2);
    }
}
