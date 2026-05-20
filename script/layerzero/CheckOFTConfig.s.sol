// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ILayerZeroEndpointV2 } from "@layerzerolabs/interfaces/ILayerZeroEndpointV2.sol";
import { Script } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { console } from "forge-std/console.sol";

/// @title CheckOFTConfig
/// @notice Read-only script that prints all LayerZero OFT settings (send/receive libs,
///         DVNs, executor, confirmations, and peer wiring) for cUSD and stcUSD across
///         every configured chain pair.
///
/// @dev Usage:
///      1. Fill in OFT addresses in config/oft-deployments.json
///      2. Fill in TODO entries in config/layerzero-v2-deployments.json (Monad/Tempo/Katana)
///      3. Export RPC URLs:
///            export ETH_RPC_URL=https://...
///            export MONAD_RPC_URL=https://...
///            export TEMPO_RPC_URL=https://...
///            export MEGAETH_RPC_URL=https://...
///            export KATANA_RPC_URL=https://...
///      4. Run:
///            forge script script/layerzero/CheckOFTConfig.s.sol
///      5. To save output to a file:
///            forge script script/layerzero/CheckOFTConfig.s.sol 2>&1 | tee oft-config-report.txt
///      Tip: add --retries 3 if you get transient HTTP 500 errors from the RPC provider.
contract CheckOFTConfig is Script {
    using stdJson for string;

    // ── LZ config types ──────────────────────────────────────────────────────
    uint32 constant CONFIG_TYPE_EXECUTOR = 1;
    uint32 constant CONFIG_TYPE_ULN = 2;

    // ── LZ struct definitions (mirrors UlnBase.sol / SendLibBase.sol) ────────
    struct UlnConfig {
        uint64 confirmations;
        uint8 requiredDVNCount;
        uint8 optionalDVNCount;
        uint8 optionalDVNThreshold;
        address[] requiredDVNs;
        address[] optionalDVNs;
    }

    struct ExecutorConfig {
        uint32 maxMessageSize;
        address executor;
    }

    // ── Internal helpers ─────────────────────────────────────────────────────
    struct ChainEntry {
        string name;
        string rpcEnvVar;
        string lzChainName; // API name for metadata.layerzero-api.com DVN lookup
        uint256 chainId;
        uint32 eid;
        address endpoint;
    }

    // Cached DVN metadata (loaded once in run())
    string private _dvnMetaJson;

    struct OFTInfo {
        string symbol;
        address addr;
    }

    // ── Trusted DVN addresses sourced from LayerZero-Labs/lz-address-book ────
    struct TrustedDVNs {
        address lzLabs; // address(0) = not deployed on this chain
        address nethermind; // address(0) = not deployed on this chain
        address canary; // address(0) = not deployed on this chain
    }

    // ─────────────────────────────────────────────────────────────────────────
    function run() external {
        ChainEntry[] memory chains = _buildChains();

        string memory lzJson = vm.readFile(string.concat(vm.projectRoot(), "/config/layerzero-v2-deployments.json"));
        string memory oftJson = vm.readFile(string.concat(vm.projectRoot(), "/config/oft-deployments.json"));
        _dvnMetaJson = vm.readFile(string.concat(vm.projectRoot(), "/config/lz-dvn-metadata.json"));

        for (uint256 i = 0; i < chains.length; i++) {
            ChainEntry memory src = chains[i];

            // Override endpoint from lz deployments JSON when chainId is known
            if (src.chainId != 0 && src.endpoint == address(0)) {
                src.endpoint = _readEndpoint(lzJson, src.chainId);
                src.eid = _readEid(lzJson, src.chainId);
            }

            if (src.eid == 0 || src.endpoint == address(0)) {
                console.log(
                    "[SKIP] %s - eid or endpoint not configured (update layerzero-v2-deployments.json)", src.name
                );
                continue;
            }

            string memory rpcUrl = vm.envOr(src.rpcEnvVar, string(""));
            if (bytes(rpcUrl).length == 0) {
                console.log("[SKIP] %s - %s not set", src.name, src.rpcEnvVar);
                continue;
            }

            OFTInfo[] memory ofts = _loadOFTs(oftJson, src.eid);
            bool hasAny = false;
            for (uint256 t = 0; t < ofts.length; t++) {
                if (ofts[t].addr != address(0)) {
                    hasAny = true;
                    break;
                }
            }
            if (!hasAny) {
                console.log("[SKIP] %s - no OFT addresses in oft-deployments.json", src.name);
                continue;
            }

            console.log("");
            console.log("==================================================================");
            console.log(
                "  SOURCE: %s  |  chainId: %s  |  eid: %s",
                src.name,
                vm.toString(src.chainId),
                vm.toString(uint256(src.eid))
            );
            console.log("  Endpoint: %s", src.endpoint);
            console.log("  Forking %s ...", src.rpcEnvVar);
            console.log("==================================================================");

            uint256 forkId = vm.createFork(rpcUrl);
            vm.selectFork(forkId);

            ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(src.endpoint);

            for (uint256 t = 0; t < ofts.length; t++) {
                OFTInfo memory oft = ofts[t];
                if (oft.addr == address(0)) continue;

                console.log("");
                console.log("  OFT: %s  addr: %s", oft.symbol, oft.addr);

                for (uint256 j = 0; j < chains.length; j++) {
                    if (i == j) continue;
                    ChainEntry memory dst = chains[j];

                    // Ensure dst has eid populated from JSON if needed
                    if (dst.chainId != 0 && dst.eid == 0) {
                        dst.eid = _readEid(lzJson, dst.chainId);
                    }
                    if (dst.eid == 0) continue;

                    console.log("");
                    console.log("    -> %s  (eid: %s)", dst.name, vm.toString(uint256(dst.eid)));
                    console.log("    -------------------------------------------------------");
                    _checkPathway(ep, oft.addr, dst.eid, src.eid, src.lzChainName);
                }
            }
        }

        console.log("");
        console.log("==================================================================");
        console.log("  Done.");
        console.log("==================================================================");
    }

    // ─────────────────────────────────────────────────────────────────────────

    function _checkPathway(
        ILayerZeroEndpointV2 ep,
        address oapp,
        uint32 dstEid,
        uint32 srcEid,
        string memory lzChainName
    ) internal view {
        // Send library
        address sendLib = _getSendLib(ep, oapp, dstEid);
        bool sendIsDefault = ep.isDefaultSendLibrary(oapp, dstEid);
        console.log(
            "    Send Lib   : %s%s",
            sendLib == address(0) ? "NOT SET" : vm.toString(sendLib),
            sendIsDefault ? " [default]" : ""
        );

        // Receive library
        (address recvLib, bool recvIsDefault) = ep.getReceiveLibrary(oapp, dstEid);
        console.log(
            "    Receive Lib: %s%s",
            recvLib == address(0) ? "NOT SET" : vm.toString(recvLib),
            recvIsDefault ? " [default]" : ""
        );

        // Send path: executor + ULN/DVNs
        if (sendLib != address(0)) {
            _checkSendConfig(ep, oapp, sendLib, dstEid, srcEid, lzChainName);
        }

        // Receive path: ULN/DVNs
        if (recvLib != address(0)) {
            bytes memory recvUlnBytes = ep.getConfig(oapp, recvLib, dstEid, CONFIG_TYPE_ULN);
            if (recvUlnBytes.length > 0) {
                UlnConfig memory uln = abi.decode(recvUlnBytes, (UlnConfig));
                _printUlnConfig("[RECV]", uln, lzChainName);
                _verifyDVNs("[RECV]", uln, srcEid);
            } else {
                console.log("    [RECV] ULN config: empty (using default)");
            }
        }

        _printEnforcedOptions(oapp, dstEid);
        _printPeer(oapp, dstEid);
    }

    function _printEnforcedOptions(address oapp, uint32 dstEid) internal view {
        // msgType 1 = SEND, msgType 2 = SEND_AND_CALL
        for (uint16 msgType = 1; msgType <= 2; msgType++) {
            string memory label = msgType == 1 ? "SEND" : "SEND_AND_CALL";
            (bool ok, bytes memory data) =
                oapp.staticcall(abi.encodeWithSignature("enforcedOptions(uint32,uint16)", dstEid, msgType));
            if (!ok) {
                // Call reverted — contract may not expose enforcedOptions or it panicked
                console.log(
                    "    EnforcedOpts [%s]: (call reverted - raw revert: %s)",
                    label,
                    data.length > 0 ? vm.toString(data) : "0x"
                );
                continue;
            }
            if (data.length < 64) {
                // ABI-encoded bytes needs at least 64 bytes (offset + length)
                console.log(
                    "    EnforcedOpts [%s]: (unexpected return length %s - raw: %s)",
                    label,
                    vm.toString(data.length),
                    data.length > 0 ? vm.toString(data) : "0x"
                );
                continue;
            }
            bytes memory opts = abi.decode(data, (bytes));
            if (opts.length == 0) {
                console.log("    EnforcedOpts [%s]: (not set)", label);
            } else {
                console.log("    EnforcedOpts [%s] raw: %s", label, vm.toString(opts));
                _decodeOptions(opts);
            }
        }
    }

    // ── Options decoder ───────────────────────────────────────────────────────
    // Encoding reference: LayerZero-v2 OptionsBuilder / ExecutorOptions.sol
    //   Type 1 (legacy): [u16 type=1][u128 gas]
    //   Type 2 (legacy): [u16 type=2][u128 gas][u128 nativeDrop][bytes32 receiver]
    //   Type 3 (new):    [u16 type=3] then repeated: [u16 workerId][u16 size][size bytes data]
    //     Executor (workerId=1) option types:
    //       1 = lzReceiveGas:    [u8 type=1][u128 gas] or [u8 type=1][u128 gas][u128 value]
    //       2 = nativeDrop:      [u8 type=2][u128 amount][bytes32 receiver]
    //       3 = lzCompose:       [u8 type=3][u16 index][u128 gas]
    //       4 = orderedExecution:[u8 type=4]

    function _decodeOptions(bytes memory opts) internal pure {
        if (opts.length < 2) {
            console.log("      (empty)");
            return;
        }
        uint16 optType;
        assembly { optType := shr(240, mload(add(opts, 32))) }

        if (optType == 1) {
            if (opts.length < 18) {
                console.log("      [TYPE 1] malformed");
                return;
            }
            uint128 lzGas;
            assembly { lzGas := shr(128, mload(add(opts, 34))) } // offset 2
            console.log("      [TYPE 1] lzReceiveGas: %s", vm.toString(uint256(lzGas)));
        } else if (optType == 2) {
            if (opts.length < 66) {
                console.log("      [TYPE 2] malformed");
                return;
            }
            uint128 lzGas;
            uint128 drop;
            bytes32 recv;
            assembly {
                lzGas := shr(128, mload(add(opts, 34))) // offset 2
                drop := shr(128, mload(add(opts, 50))) // offset 18
                recv := mload(add(opts, 66)) // offset 34
            }
            console.log(
                "      [TYPE 2] lzReceiveGas: %s | nativeDrop: %s | receiver: %s",
                vm.toString(uint256(lzGas)),
                vm.toString(uint256(drop)),
                vm.toString(recv)
            );
        } else if (optType == 3) {
            _decodeType3(opts);
        } else {
            console.log("      (unknown optionsType %s - raw: %s)", vm.toString(uint256(optType)), vm.toString(opts));
        }
    }

    function _decodeType3(bytes memory opts) internal pure {
        uint256 cursor = 2; // skip 2-byte type prefix
        while (cursor + 3 <= opts.length) {
            uint8 workerId;
            uint16 optSize;
            assembly {
                let ptr := add(add(opts, 32), cursor)
                workerId := shr(248, mload(ptr)) // 1 byte workerId
                optSize := shr(240, mload(add(ptr, 1))) // 2 bytes optSize
            }
            cursor += 3;
            if (cursor + optSize > opts.length) break;

            if (workerId == 1) {
                _decodeExecutorOption(opts, cursor, optSize);
            } else {
                console.log(
                    "      [WORKER %s] %s bytes (raw)", vm.toString(uint256(workerId)), vm.toString(uint256(optSize))
                );
            }
            cursor += optSize;
        }
    }

    function _decodeExecutorOption(bytes memory opts, uint256 cursor, uint16 size) internal pure {
        if (size == 0) return;
        uint8 execType;
        assembly { execType := shr(248, mload(add(add(opts, 32), cursor))) }

        if (execType == 1) {
            // lzReceiveGas: [u128 gas] or [u128 gas][u128 value]
            if (size < 17) {
                console.log("      [EXEC] lzReceiveGas: malformed");
                return;
            }
            uint128 lzGas;
            assembly { lzGas := shr(128, mload(add(add(opts, 33), cursor))) } // cursor+1
            if (size >= 33) {
                uint128 value;
                assembly { value := shr(128, mload(add(add(opts, 49), cursor))) } // cursor+17
                console.log(
                    "      [EXEC] lzReceiveGas: %s  value: %s", vm.toString(uint256(lzGas)), vm.toString(uint256(value))
                );
            } else {
                console.log("      [EXEC] lzReceiveGas: %s", vm.toString(uint256(lzGas)));
            }
        } else if (execType == 2) {
            // nativeDrop: [u128 amount][bytes32 receiver]
            if (size < 49) {
                console.log("      [EXEC] nativeDrop: malformed");
                return;
            }
            uint128 amount;
            bytes32 receiver;
            assembly {
                amount := shr(128, mload(add(add(opts, 33), cursor))) // cursor+1
                receiver := mload(add(add(opts, 49), cursor)) // cursor+17
            }
            console.log(
                "      [EXEC] nativeDrop: %s  receiver: %s", vm.toString(uint256(amount)), vm.toString(receiver)
            );
        } else if (execType == 3) {
            // lzCompose: [u16 index][u128 gas]
            if (size < 19) {
                console.log("      [EXEC] lzCompose: malformed");
                return;
            }
            uint16 index;
            uint128 lzGas;
            assembly {
                index := shr(240, mload(add(add(opts, 33), cursor))) // cursor+1
                lzGas := shr(128, mload(add(add(opts, 35), cursor))) // cursor+3
            }
            console.log(
                "      [EXEC] lzCompose: index=%s  gas=%s", vm.toString(uint256(index)), vm.toString(uint256(lzGas))
            );
        } else if (execType == 4) {
            console.log("      [EXEC] orderedExecution: true");
        } else {
            console.log("      [EXEC] unknown execType=%s", vm.toString(uint256(execType)));
        }
    }

    function _checkSendConfig(
        ILayerZeroEndpointV2 ep,
        address oapp,
        address sendLib,
        uint32 dstEid,
        uint32 srcEid,
        string memory lzChainName
    ) internal view {
        bytes memory execBytes = ep.getConfig(oapp, sendLib, dstEid, CONFIG_TYPE_EXECUTOR);
        if (execBytes.length > 0) {
            ExecutorConfig memory exec = abi.decode(execBytes, (ExecutorConfig));
            console.log("    [SEND] Executor    : %s", exec.executor);
            console.log("    [SEND] MaxMsgSize  : %s", vm.toString(uint256(exec.maxMessageSize)));
        } else {
            console.log("    [SEND] Executor config: empty (using default)");
        }

        bytes memory sendUlnBytes = ep.getConfig(oapp, sendLib, dstEid, CONFIG_TYPE_ULN);
        if (sendUlnBytes.length > 0) {
            UlnConfig memory uln = abi.decode(sendUlnBytes, (UlnConfig));
            _printUlnConfig("[SEND]", uln, lzChainName);
            _verifyDVNs("[SEND]", uln, srcEid);
        } else {
            console.log("    [SEND] ULN config: empty (using default)");
        }
    }

    function _printUlnConfig(string memory tag, UlnConfig memory uln, string memory lzChain) internal view {
        console.log("    %s Confirmations : %s", tag, vm.toString(uint256(uln.confirmations)));
        console.log("    %s RequiredDVNs  : %s", tag, vm.toString(uint256(uln.requiredDVNCount)));
        for (uint256 d = 0; d < uln.requiredDVNs.length; d++) {
            string memory lbl = _dvnLabel(uln.requiredDVNs[d], lzChain);
            if (bytes(lbl).length > 0) {
                console.log("           required[%s]: %s (%s)", vm.toString(d), uln.requiredDVNs[d], lbl);
            } else {
                console.log("           required[%s]: %s", vm.toString(d), uln.requiredDVNs[d]);
            }
        }
        if (uln.optionalDVNCount > 0) {
            console.log(
                "    %s OptionalDVNs  : %s (threshold: %s)",
                tag,
                vm.toString(uint256(uln.optionalDVNCount)),
                vm.toString(uint256(uln.optionalDVNThreshold))
            );
            for (uint256 d = 0; d < uln.optionalDVNs.length; d++) {
                string memory lbl = _dvnLabel(uln.optionalDVNs[d], lzChain);
                if (bytes(lbl).length > 0) {
                    console.log("           optional[%s]: %s (%s)", vm.toString(d), uln.optionalDVNs[d], lbl);
                } else {
                    console.log("           optional[%s]: %s", vm.toString(d), uln.optionalDVNs[d]);
                }
            }
        }
    }

    /// @dev Converts a checksummed address to lowercase hex (for metadata JSON key lookup)
    function _addrToLower(address addr) internal pure returns (string memory) {
        bytes memory b = bytes(vm.toString(addr));
        for (uint256 i = 2; i < b.length; i++) {
            if (b[i] >= 0x41 && b[i] <= 0x5A) b[i] = bytes1(uint8(b[i]) + 32);
        }
        return string(b);
    }

    /// @dev Looks up the canonical DVN name from the layerzero metadata API JSON
    function _dvnLabel(address dvn, string memory lzChain) internal view returns (string memory) {
        if (bytes(_dvnMetaJson).length == 0 || bytes(lzChain).length == 0) return "";
        string memory key = string.concat("$['", lzChain, "']['dvns']['", _addrToLower(dvn), "']['canonicalName']");
        try vm.parseJsonString(_dvnMetaJson, key) returns (string memory name) {
            return name;
        } catch {
            return "";
        }
    }

    function _printPeer(address oapp, uint32 dstEid) internal view {
        (bool ok, bytes memory data) = oapp.staticcall(abi.encodeWithSignature("peers(uint32)", dstEid));
        if (ok && data.length >= 32) {
            bytes32 peer = abi.decode(data, (bytes32));
            if (peer == bytes32(0)) {
                console.log("    Peer       : NOT SET (0x0000...0000)");
            } else {
                console.log("    Peer       : %s", vm.toString(peer));
            }
        } else {
            console.log("    Peer       : (could not read - check contract ABI)");
        }
    }

    function _getSendLib(ILayerZeroEndpointV2 ep, address oapp, uint32 dstEid) internal view returns (address lib) {
        try ep.getSendLibrary(oapp, dstEid) returns (address l) {
            lib = l;
        } catch {
            lib = address(0);
        }
    }

    // ── Chain registry ────────────────────────────────────────────────────────

    /// @dev Each entry supplies either:
    ///       - a known chainId (endpoint + eid read from layerzero-v2-deployments.json), OR
    ///       - a hardcoded endpoint/eid for chains not yet in that JSON.
    ///      Set eid = 0 and endpoint = address(0) to mark a chain as TODO.
    function _buildChains() internal pure returns (ChainEntry[] memory chains) {
        chains = new ChainEntry[](5);

        chains[0] = ChainEntry({
            name: "Ethereum",
            rpcEnvVar: "ETH_RPC_URL",
            lzChainName: "ethereum",
            chainId: 1,
            eid: 30101,
            endpoint: 0x1a44076050125825900e736c501f859c50fE728c
        });

        chains[1] = ChainEntry({
            name: "Monad", rpcEnvVar: "MONAD_RPC_URL", lzChainName: "monad", chainId: 143, eid: 0, endpoint: address(0)
        });

        chains[2] = ChainEntry({
            name: "Tempo", rpcEnvVar: "TEMPO_RPC_URL", lzChainName: "tempo", chainId: 4217, eid: 0, endpoint: address(0)
        });

        chains[3] = ChainEntry({
            name: "MegaETH",
            rpcEnvVar: "MEGAETH_RPC_URL",
            lzChainName: "megaeth",
            chainId: 4326,
            eid: 0,
            endpoint: address(0)
        });

        chains[4] = ChainEntry({
            name: "Katana",
            rpcEnvVar: "KATANA_RPC_URL",
            lzChainName: "katana",
            chainId: 747474,
            eid: 0,
            endpoint: address(0)
        });
    }

    // ── DVN verification ──────────────────────────────────────────────────────

    /// @notice Checks actual DVNs against the expected LZ Labs / Nethermind / Canary set.
    ///         Addresses sourced from LayerZero-Labs/lz-address-book (LZWorkers.sol).
    function _verifyDVNs(string memory tag, UlnConfig memory uln, uint32 srcEid) internal pure {
        TrustedDVNs memory t = _trustedDVNs(srcEid);
        if (t.lzLabs == address(0) && t.nethermind == address(0) && t.canary == address(0)) return;

        if (t.lzLabs != address(0) && !_dvnPresent(uln, t.lzLabs)) {
            console.log("    [WARN] %s MISSING LayerZero Labs DVN  expected: %s", tag, t.lzLabs);
        }
        if (t.nethermind != address(0) && !_dvnPresent(uln, t.nethermind)) {
            console.log("    [WARN] %s MISSING Nethermind DVN       expected: %s", tag, t.nethermind);
        }
        if (t.canary != address(0) && !_dvnPresent(uln, t.canary)) {
            console.log("    [WARN] %s MISSING Canary DVN           expected: %s", tag, t.canary);
        }

        // Flag any DVN that is not in the trusted set
        for (uint256 d = 0; d < uln.requiredDVNs.length; d++) {
            if (!_isTrusted(uln.requiredDVNs[d], t)) {
                console.log("    [WARN] %s UNKNOWN required DVN: %s", tag, uln.requiredDVNs[d]);
            }
        }
        for (uint256 d = 0; d < uln.optionalDVNs.length; d++) {
            if (!_isTrusted(uln.optionalDVNs[d], t)) {
                console.log("    [WARN] %s UNKNOWN optional DVN: %s", tag, uln.optionalDVNs[d]);
            }
        }
    }

    function _dvnPresent(UlnConfig memory uln, address dvn) internal pure returns (bool) {
        for (uint256 d = 0; d < uln.requiredDVNs.length; d++) {
            if (uln.requiredDVNs[d] == dvn) return true;
        }
        for (uint256 d = 0; d < uln.optionalDVNs.length; d++) {
            if (uln.optionalDVNs[d] == dvn) return true;
        }
        return false;
    }

    function _isTrusted(address dvn, TrustedDVNs memory t) internal pure returns (bool) {
        return dvn == t.lzLabs || dvn == t.nethermind || dvn == t.canary;
    }

    /// @notice Returns the trusted DVN addresses for a given source chain EID.
    ///         address(0) means that DVN is not deployed on that chain.
    ///         Source: LayerZero-Labs/lz-address-book LZWorkers.sol
    function _trustedDVNs(uint32 eid) internal pure returns (TrustedDVNs memory) {
        // Ethereum mainnet
        if (eid == 30101) {
            return TrustedDVNs({
                lzLabs: 0x589dEDbD617e0CBcB916A9223F4d1300c294236b,
                nethermind: 0xa59BA433ac34D2927232918Ef5B2eaAfcF130BA5,
                canary: 0xa4fE5A5B9A846458a70Cd0748228aED3bF65c2cd
            });
        }
        // Monad mainnet
        if (eid == 30390) {
            return TrustedDVNs({
                lzLabs: 0x282b3386571f7f794450d5789911a9804FA346b4,
                nethermind: 0xaCDe1f22EEAb249d3ca6Ba8805C8fEe9f52a16e7,
                canary: 0x493626C5D852B9B187a9eb709D0b0978a3877238
            });
        }
        // Monad testnet
        if (eid == 40204) {
            return TrustedDVNs({
                lzLabs: 0x88B27057A9e00c5F05DDa29241027afF63f9e6e0,
                nethermind: 0xB365Da66084D135E9bfaef73EB8be06029271681,
                canary: address(0)
            });
        }
        // MegaETH mainnet
        if (eid == 30398) {
            return TrustedDVNs({
                lzLabs: 0x282b3386571f7f794450d5789911a9804FA346b4,
                nethermind: 0xeEdE111103535e473451311e26C3E6660b0F77e1,
                canary: 0x7DEcC6Df3aF9CFc275E25d2f9703eCF7ad800D5D
            });
        }
        // MegaETH testnet — only LZ Labs deployed
        if (eid == 40370) {
            return TrustedDVNs({
                lzLabs: 0x88B27057A9e00c5F05DDa29241027afF63f9e6e0, nethermind: address(0), canary: address(0)
            });
        }
        // Tempo mainnet
        if (eid == 30410) {
            return TrustedDVNs({
                lzLabs: 0x76FaFF60799021B301B45dC1BbEDE53F261F9961,
                nethermind: 0x0D875bD6c833cEDef7Fca4FE154d023cDB8eb1cb,
                canary: 0xB30B5B27Cb23356DE1D3100E0e120D481Da97b1f
            });
        }
        // Katana mainnet
        if (eid == 30375) {
            return TrustedDVNs({
                lzLabs: 0x282b3386571f7f794450d5789911a9804FA346b4,
                nethermind: 0xaCDe1f22EEAb249d3ca6Ba8805C8fEe9f52a16e7,
                canary: 0x53fF818a1c492e667E2cD0b5AFe0FC82c66d33c7
            });
        }
        return TrustedDVNs({ lzLabs: address(0), nethermind: address(0), canary: address(0) });
    }

    // ── JSON helpers ─────────────────────────────────────────────────────────

    function _readEndpoint(string memory json, uint256 chainId) internal pure returns (address) {
        string memory key = string.concat("$['", vm.toString(chainId), "'].endpointV2");
        try vm.parseJsonAddress(json, key) returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    function _readEid(string memory json, uint256 chainId) internal pure returns (uint32) {
        string memory key = string.concat("$['", vm.toString(chainId), "'].eid");
        try vm.parseJsonUint(json, key) returns (uint256 v) {
            return uint32(v);
        } catch {
            return 0;
        }
    }

    function _loadOFTs(string memory json, uint32 eid) internal pure returns (OFTInfo[] memory ofts) {
        ofts = new OFTInfo[](2);

        string memory base = string.concat("$['", vm.toString(uint256(eid)), "'].");

        address cusd;
        address stcusd;
        try vm.parseJsonAddress(json, string.concat(base, "cusd")) returns (address a) {
            cusd = a;
        } catch { }
        try vm.parseJsonAddress(json, string.concat(base, "stcusd")) returns (address a) {
            stcusd = a;
        } catch { }

        ofts[0] = OFTInfo({ symbol: "cUSD", addr: cusd });
        ofts[1] = OFTInfo({ symbol: "stcUSD", addr: stcusd });
    }
}
