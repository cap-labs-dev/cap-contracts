#!/usr/bin/env node
// Format config/cap-v2.json. Forge's `vm.writeFile` saves it as a single line with sorted keys,
// so `save()` is followed by this to restore the checked-in layout: chain ids ascending, keys in
// the order of the deploy config structs, four-space indent and a trailing newline.
// Pass --check to fail without writing when the file is not formatted.
import fs from "node:fs";

const CONFIG = new URL("../../config/cap-v2.json", import.meta.url);

const CHAIN_KEYS = ["deployer", "timelock", "multisig", "stablecoinUnderlying", "reserveVault", "implems", "infra"];
const IMPLEMS_KEYS = [
    "vault",
    "stablecoin",
    "irm",
    "oracle",
    "registry",
    "floatingMarket",
    "fixedMarket",
    "tranche",
    "underwriter",
    "wrapper",
];
const INFRA_KEYS = [
    "accessManager",
    "vault",
    "stablecoin",
    "irm",
    "oracle",
    "chainlinkAdapter",
    "registry",
    "factory",
    "floatingMarketBeacon",
    "fixedMarketBeacon",
    "trancheBeacon",
    "underwriterBeacon",
    "wrapper",
];

// Known keys first, in order; anything unexpected is kept after them rather than dropped
function ordered(object, keys) {
    const result = {};
    for (const key of keys) if (key in object) result[key] = object[key];
    for (const key of Object.keys(object)) if (!(key in result)) result[key] = object[key];
    return result;
}

function format(source) {
    const config = JSON.parse(source);
    const chains = {};
    for (const chainId of Object.keys(config).sort((a, b) => Number(a) - Number(b))) {
        const chain = ordered(config[chainId], CHAIN_KEYS);
        if (chain.implems) chain.implems = ordered(chain.implems, IMPLEMS_KEYS);
        if (chain.infra) chain.infra = ordered(chain.infra, INFRA_KEYS);
        chains[chainId] = chain;
    }
    return JSON.stringify(chains, null, 4) + "\n";
}

const source = fs.readFileSync(CONFIG, "utf8");
const formatted = format(source);

if (process.argv.includes("--check")) {
    if (source !== formatted) {
        console.error("config/cap-v2.json is not formatted. Run `yarn format:config`.");
        process.exit(1);
    }
} else if (source !== formatted) {
    fs.writeFileSync(CONFIG, formatted);
}
