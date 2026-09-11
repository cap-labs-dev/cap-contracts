// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Stablecoin } from "../../../../contracts/cap/Stablecoin.sol";
import { CapRoles } from "../../../../contracts/utils/CapRoles.sol";
import { BaseTest } from "../../../../test/shared/BaseTest.sol";
import { MockERC20 } from "../../../../test/shared/mocks/MockERC20.sol";
import { MockIRM } from "../../../../test/shared/mocks/MockIRM.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Standalone Stablecoin harness for wei-level curve tests, parameterised on underlying decimals.
abstract contract CurveHarness is BaseTest {
    Stablecoin internal scoin;
    MockERC20 internal asset;
    MockIRM internal irm;
    uint8 internal dec;
    uint256 internal scale; // 10 ** (18 - dec)

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal sink = makeAddr("defaultedBorrower");
    address internal treasury = makeAddr("treasury");

    function _decimals() internal pure virtual returns (uint8);

    function setUp() public virtual {
        _setUpAccessManager();
        dec = _decimals();
        scale = 10 ** (18 - dec);
        asset = new MockERC20("USD", "USD", dec);
        irm = new MockIRM();
        Stablecoin impl = new Stablecoin();
        scoin = Stablecoin(
            _deployProxy(
                address(impl),
                abi.encodeCall(
                    Stablecoin.initialize, (address(accessManager), address(asset), "Cap USD", "cUSD", "", address(irm))
                )
            )
        );
        _grantRoleForTarget(CapRoles.GOVERNOR, treasury, address(scoin), _selectors(Stablecoin.coverBadDebt.selector));
        asset.mint(alice, type(uint128).max);
        asset.mint(bob, type(uint128).max);
        vm.prank(alice);
        asset.approve(address(scoin), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(scoin), type(uint256).max);
    }

    /// @dev deposit `dep` underlying units from alice, mint `credit` credit-backed to a sink, write off `bad`.
    function _seed(uint256 dep, uint256 credit, uint256 bad) internal {
        vm.prank(alice);
        scoin.deposit(dep, alice);
        if (credit > 0) scoin.mintCreditBacked(sink, credit);
        if (bad > 0) scoin.recognizeBadDebt(bad);
    }

    function _reserve18() internal view returns (uint256) {
        return asset.balanceOf(address(scoin)) * scale;
    }

    /// @dev k = badDebt / (supply * backing), scaled by 1e54 for comparison
    function _k() internal view returns (uint256) {
        uint256 s = scoin.totalSupply();
        uint256 a = scoin.totalAssets();
        if (s == 0 || a == 0) return 0;
        return Math.mulDiv(scoin.badDebt(), 1e54, s * a);
    }
}
