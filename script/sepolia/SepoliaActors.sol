// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Vm } from "forge-std/Vm.sol";
import { console } from "forge-std/console.sol";

/// @title SepoliaActors
/// @notice The cast of testnet operators the Sepolia scenarios act as, derived from one mnemonic
/// @dev Every actor is a real key so the UI sees distinct addresses signing their own
/// transactions. The deployer funds them with Sepolia ETH in-script; the mnemonic is the only thing
/// to keep. Indices are fixed so an address can be recovered from `ACTORS_MNEMONIC` alone.
abstract contract SepoliaActors {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Foundry's well-known test mnemonic. Fine for rehearsals, never for a real broadcast.
    string public constant TEST_MNEMONIC = "test test test test test test test test test test test junk";

    struct Actor {
        address addr;
        uint256 key;
        string label;
    }

    // ── indices on the mnemonic ───────────────────────────────────────────────
    uint32 internal constant OWNER_BASE = 0; // 3 market owners
    uint32 internal constant BORROWER_BASE = 3; // 6 borrowers
    uint32 internal constant DEPOSITOR_BASE = 9; // 5 tranche / cUSD depositors
    uint32 internal constant CURATOR_BASE = 14; // 3 underwriter curators
    uint32 internal constant ALLOCATOR_BASE = 17; // 3 underwriter allocators
    uint32 internal constant LP_BASE = 20; // 3 underwriter pool depositors
    uint32 internal constant LIQUIDATOR_INDEX = 23; // 1 liquidator
    uint32 public constant ACTOR_COUNT = 24;

    Actor[3] public owners;
    Actor[6] public borrowers;
    Actor[5] public depositors;
    Actor[3] public curators;
    Actor[3] public allocators;
    Actor[3] public lps;
    Actor public liquidator;

    /// @dev Every actor in index order, for funding and the manifest
    Actor[] public allActors;

    /// @dev Added to every index; nonzero when the actors share the deployer's phrase
    uint32 public indexOffset;

    /// @dev Derive the cast. Refuses the public test mnemonic when `broadcasting`, because anyone
    /// can sweep those keys the moment they hold Sepolia ETH.
    /// @param mnemonic The BIP-39 phrase actors are derived from
    /// @param broadcasting Whether these keys are about to sign real transactions
    function _deriveActors(string memory mnemonic, bool broadcasting) internal {
        _deriveActors(mnemonic, 0, broadcasting, address(0));
    }

    /// @dev Derive the cast starting at `offset` on the phrase. When the deployer's own phrase is
    /// reused, pass the first unused index (usually 1) so no actor collides with the admin wallet;
    /// a collision with `deployer` reverts either way.
    /// @param mnemonic The BIP-39 phrase actors are derived from
    /// @param offset Added to every index in the table
    /// @param broadcasting Whether these keys are about to sign real transactions
    /// @param deployer The admin wallet no actor may coincide with
    function _deriveActors(string memory mnemonic, uint32 offset, bool broadcasting, address deployer) internal {
        indexOffset = offset;
        if (broadcasting) {
            require(
                keccak256(bytes(mnemonic)) != keccak256(bytes(TEST_MNEMONIC)),
                "ACTORS_MNEMONIC is the public Foundry test mnemonic; set a private one"
            );
        }

        string[3] memory ownerNames = ["Atlas Capital (owner)", "Boreal Credit (owner)", "Cinder Markets (owner)"];
        for (uint32 i; i < 3; ++i) {
            owners[i] = _actor(mnemonic, OWNER_BASE + i, ownerNames[i]);
        }
        for (uint32 i; i < 6; ++i) {
            borrowers[i] = _actor(mnemonic, BORROWER_BASE + i, string.concat("Borrower ", _letter(i)));
        }
        for (uint32 i; i < 5; ++i) {
            depositors[i] = _actor(mnemonic, DEPOSITOR_BASE + i, string.concat("Depositor ", _letter(i)));
        }
        for (uint32 i; i < 3; ++i) {
            curators[i] = _actor(mnemonic, CURATOR_BASE + i, string.concat("Curator ", _letter(i)));
        }
        for (uint32 i; i < 3; ++i) {
            allocators[i] = _actor(mnemonic, ALLOCATOR_BASE + i, string.concat("Allocator ", _letter(i)));
        }
        for (uint32 i; i < 3; ++i) {
            lps[i] = _actor(mnemonic, LP_BASE + i, string.concat("Pool LP ", _letter(i)));
        }
        liquidator = _actor(mnemonic, LIQUIDATOR_INDEX, "Liquidator");

        for (uint256 i; i < allActors.length; ++i) {
            require(allActors[i].addr != deployer, "an actor index collides with the deployer; set ACTORS_INDEX_OFFSET");
        }
    }

    function _actor(string memory mnemonic, uint32 index, string memory label) private returns (Actor memory actor) {
        actor.key = VM.deriveKey(mnemonic, index + indexOffset);
        actor.addr = VM.addr(actor.key);
        actor.label = label;
        allActors.push(actor);
    }

    function _letter(uint32 i) private pure returns (string memory) {
        bytes memory b = new bytes(1);
        // casting to 'uint8' is safe because i is at most 5
        // forge-lint: disable-next-line(unsafe-typecast)
        b[0] = bytes1(uint8(65 + i));
        return string(b);
    }

    /// @dev Print the cast with addresses, for the operator and the UI team
    function _printActors() internal view {
        console.log("== actors (ACTORS_MNEMONIC index: label address) ==");
        for (uint256 i; i < allActors.length; ++i) {
            console.log(i + indexOffset, allActors[i].label, allActors[i].addr);
        }
    }
}
