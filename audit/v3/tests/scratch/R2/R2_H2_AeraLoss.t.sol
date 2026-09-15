// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IAeraVault } from "../../../../../contracts/interfaces/IAeraVault.sol";
import { CapDeployer } from "../../../../../test/shared/CapDeployer.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// MockAeraVault plus a strategy-loss knob (round-2 N2/LossyAeraVault).
contract LossyAeraVault is IAeraVault {
    using SafeERC20 for IERC20;

    error Aera__UnexpectedTokenAllowance(uint256 allowance);

    function deposit(TokenAmount[] calldata tokenAmounts) external {
        for (uint256 i; i < tokenAmounts.length; ++i) {
            TokenAmount calldata t = tokenAmounts[i];
            t.token.safeTransferFrom(msg.sender, address(this), t.amount);
            uint256 allowance = t.token.allowance(msg.sender, address(this));
            if (allowance != 0) revert Aera__UnexpectedTokenAllowance(allowance);
        }
    }

    function withdraw(TokenAmount[] calldata tokenAmounts) external {
        for (uint256 i; i < tokenAmounts.length; ++i) {
            tokenAmounts[i].token.safeTransfer(msg.sender, tokenAmounts[i].amount);
        }
    }

    function lose(IERC20 token, uint256 bps) external returns (uint256 lost) {
        lost = token.balanceOf(address(this)) * bps / 10_000;
        if (lost > 0) token.safeTransfer(address(0xdead), lost);
    }
}

/// Round-3 port of round-2 R2-H2 (verify/R2-HIGH-AERA-LOSS) plus R2-L1 and R2-L6.
/// HEAD adds GUARDIAN `recognizeBadDebtInReserve` (Stablecoin.sol:152-156), GOVERNOR
/// `setReserveVault` (:120-124) and caps `unlockedSupply` by the on-hand balance (:184-192).
/// `totalAssets`/`backing`/`_convertToAssets` are still supply-derived (:195-202, :236-261):
/// an Aera loss is invisible until GUARDIAN acts, and every redeemer before that exits at par.
contract R2_H2_AeraLoss is CapDeployer {
    LossyAeraVault aera;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _deployCap();
        aera = new LossyAeraVault();
        stablecoin.setReserveVault(address(aera)); // GOVERNOR
        _depositStable(alice, 500e18);
        _depositStable(bob, 500e18);
    }

    function _redeemAll(address who) internal returns (uint256 paid) {
        uint256 shares = stablecoin.maxInstantRedeem(who);
        vm.prank(who);
        paid = stablecoin.instantRedeem(shares, who, who);
    }

    /// The lead's question: does a redeemer still exit at par after an Aera loss? Yes.
    function test_lossInvisible_redeemerExitsAtPar() public {
        stablecoin.invest(500e18); // KEEPER
        uint256 lost = aera.lose(IERC20(address(cusdUnderlying)), 2_000); // 20% of the invested leg = 100
        emit log_named_uint("aera loss", lost);
        emit log_named_uint("totalAssets while invested (unchanged)", stablecoin.totalAssets());
        emit log_named_uint("unlockedSupply while invested (on-hand cap)", stablecoin.unlockedSupply());
        emit log_named_uint("backing()", stablecoin.backing());
        assertEq(stablecoin.badDebt(), 0, "nothing recognised");

        stablecoin.recall(400e18);
        uint256 onHand = cusdUnderlying.balanceOf(address(stablecoin));
        assertEq(onHand, 900e18);
        uint256 supply = stablecoin.totalSupply();
        uint256 fairAlice = 500e18 * onHand / supply; // 450

        uint256 alicePaid = _redeemAll(alice);
        emit log_named_uint("alice paid", alicePaid);
        emit log_named_uint("alice fair (pro-rata of real reserve)", fairAlice);
        emit log_named_uint("bob maxInstantRedeem now", stablecoin.maxInstantRedeem(bob));
        emit log_named_uint("bob convertToAssets(500)", stablecoin.convertToAssets(500e18));
        assertLe(
            alicePaid,
            fairAlice + 1,
            "a redeemer exits at par after an Aera loss; the whole loss lands on whoever is last"
        );
    }

    /// After GUARDIAN recognition the curve applies and creditBackedSupply is untouched.
    function test_guardianRecognition_thenCurve() public {
        stablecoin.invest(500e18);
        uint256 lost = aera.lose(IERC20(address(cusdUnderlying)), 2_000);
        stablecoin.recall(400e18);
        uint256 cbs = stablecoin.creditBackedSupply();
        stablecoin.recognizeBadDebtInReserve(lost); // GUARDIAN
        assertEq(stablecoin.badDebt(), lost);
        assertEq(stablecoin.creditBackedSupply(), cbs, "credit untouched");
        assertEq(stablecoin.totalAssets(), 900e18, "totalAssets now matches the real reserve");
        uint256 a = _redeemAll(alice);
        uint256 b = _redeemAll(bob);
        emit log_named_uint("alice on curve", a);
        emit log_named_uint("bob on curve", b);
        assertLt(a, 500e18);
        assertLe(a + b, 900e18, "sum payable within the real reserve");
    }

    /// R2-L1 re-check: views now track the on-hand balance, so an over-liquid claim is refused by
    /// `maxInstantRedeem` rather than failing inside the transfer.
    function test_R2L1_viewsTrackOnHandBalance() public {
        stablecoin.invest(600e18);
        assertEq(stablecoin.unlockedSupply(), 400e18, "unlocked capped by on-hand");
        assertEq(stablecoin.maxInstantRedeem(alice), 400e18);
        vm.prank(alice);
        stablecoin.instantRedeem(400e18, alice, alice);
        assertEq(stablecoin.maxInstantRedeem(bob), 0);
        vm.prank(bob);
        vm.expectRevert(); // ERC4626ExceededMaxRedeem, not a failed transfer
        stablecoin.instantRedeem(1, bob, bob);
        stablecoin.recall(600e18);
        assertEq(stablecoin.maxInstantRedeem(bob), 500e18);
    }

    /// R2-L6 re-check: the setter exists (GOVERNOR). Residual: no `invested == 0` gate, so a
    /// switch while funds sit in the old vault makes them unreachable until switched back.
    function test_R2L6_setReserveVault_noInvestedGate() public {
        stablecoin.invest(500e18);
        LossyAeraVault other = new LossyAeraVault();
        stablecoin.setReserveVault(address(other));
        (bool ok,) = address(stablecoin).call(abi.encodeCall(stablecoin.recall, (500e18)));
        emit log_named_string("recall from the new vault", ok ? "ok" : "REVERT (funds sit in the old vault)");
        assertFalse(ok);
        stablecoin.setReserveVault(address(aera));
        stablecoin.recall(500e18);
        assertEq(cusdUnderlying.balanceOf(address(stablecoin)), 1_000e18);
    }
}
