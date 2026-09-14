// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vault } from "../../../../../contracts/cap/Vault.sol";
import { BaseTest } from "../../../../../test/shared/BaseTest.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISenderHook {
    function tokensToSend(address from, address to, uint256 amount) external;
}

contract CallbackToken is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("CB", "CB") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function register() external {
        hooked[msg.sender] = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (hooked[from]) ISenderHook(from).tokensToSend(from, to, amount);
        return super.transferFrom(from, to, amount);
    }
}

contract Attacker is ISenderHook {
    Vault internal vault;
    CallbackToken internal token;
    uint256 public seenBalance;
    uint256 public seenVaultTokens;
    uint256 public seenSupply;
    bool public midFlightWithdrawSucceeded;
    bool internal inHook;

    constructor(Vault _vault, CallbackToken _token) {
        vault = _vault;
        token = _token;
        token.register();
        token.approve(address(vault), type(uint256).max);
    }

    function attack(uint256 amount) external {
        vault.deposit(address(token), amount, address(this));
    }

    function tokensToSend(address, address, uint256 amount) external override {
        if (inHook) return;
        inHook = true;
        seenBalance = vault.balanceOf(address(this), address(token));
        seenVaultTokens = token.balanceOf(address(vault));
        seenSupply = vault.totalSupply(vault.id(address(token)));
        try vault.withdraw(address(token), amount, address(this)) {
            midFlightWithdrawSucceeded = true;
        } catch { }
        inHook = false;
    }
}

/// Round-3 port of round-1 L-18 (WS-A VaultCallback). HEAD `Vault.deposit` (:34-37) pulls with
/// `safeTransferFrom` BEFORE `_mint` (CEI reorder in 2429b6c), so a sender-hook token no longer
/// sees minted ERC-6909 for tokens the vault does not yet hold.
contract R1_L18_VaultCallback is BaseTest {
    Vault internal vault;
    CallbackToken internal token;
    address internal victim = makeAddr("victim");

    function setUp() public {
        _setUpAccessManager();
        vault = Vault(_deployProxy(address(new Vault()), abi.encodeCall(Vault.initialize, (address(accessManager)))));
        token = new CallbackToken();
        token.mint(victim, 100e18);
        vm.startPrank(victim);
        token.approve(address(vault), type(uint256).max);
        vault.deposit(address(token), 100e18, victim);
        vm.stopPrank();
    }

    function test_L18_mintAfterTransfer_noWindow() public {
        Attacker a = new Attacker(vault, token);
        token.mint(address(a), 100e18);
        a.attack(100e18);

        emit log_named_uint("6909 balance seen mid-flight ", a.seenBalance());
        emit log_named_uint("vault tokens seen mid-flight ", a.seenVaultTokens());
        emit log_named_uint("6909 supply seen mid-flight  ", a.seenSupply());
        emit log_named_string("mid-flight withdraw", a.midFlightWithdrawSucceeded() ? "SUCCEEDED" : "refused");

        assertEq(a.seenBalance(), 0, "nothing minted before the pull");
        assertEq(a.seenSupply(), 100e18, "I12 holds in-window");
        assertFalse(a.midFlightWithdrawSucceeded(), "no withdrawal against an unpaid balance");
        assertEq(token.balanceOf(address(vault)), 200e18);
        assertEq(vault.balanceOf(address(a), address(token)), 100e18);
    }
}
