#!/usr/bin/env node
// Summarize invariant handler outcomes, excluding bootstrap and duplicate final replays.
import assert from 'node:assert/strict';
import { globSync, readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { parseArgs } from 'node:util';

const { values: args } = parseArgs({
  options: {
    profile: { type: 'string' },
    seed: { type: 'string' },
    help: { type: 'boolean', short: 'h' },
  },
});
if (args.help) {
  console.log('Usage: node script/summarize-invariant-metrics.js --profile <profile> --seed <seed>');
  process.exit(0);
}
if (!args.profile || !args.seed) {
  console.error('Both --profile and --seed are required. Run with --help for usage.');
  process.exit(2);
}

const artifact = JSON.parse(readFileSync('out/ProtocolHandler.sol/ProtocolHandler.json', 'utf8'));
const names = new Map(Object.entries(artifact.methodIdentifiers).map(([name, selector]) => [`0x${selector}`, name]));
const summary = {};
for (const path of globSync('artifacts/fuzz-and-invariant-tests/*-metrics.jsonl').sort()) {
  const seen = new Set();
  const outcomes = {};
  const content = readFileSync(path, 'utf8');
  const lines = content === '' ? [] : content.replace(/\r?\n$/, '').split(/\r?\n/);
  for (const line of lines) {
    const row = JSON.parse(line);
    if (row.profile !== args.profile || row.seed !== args.seed || !Object.hasOwn(row, 'sequence')) continue;
    if (seen.has(row.sequence)) continue;
    seen.add(row.sequence);
    for (const [selector, values] of Object.entries(row.operations)) {
      assert(Array.isArray(values) && values.length === 4 && values.every(value => Number.isSafeInteger(value) && value >= 0),
        `Invalid counters for ${selector}: ${JSON.stringify(values)}`);
      assert.equal(values[0], values[1] + values[2] + values[3], `Outcome counts do not match attempts for ${selector}`);
      assert(names.has(selector), `Unknown handler selector: ${selector}`);
      const name = names.get(selector);
      outcomes[name] = values.map((value, index) => (outcomes[name]?.[index] ?? 0) + value);
    }
  }
  summary[basename(path, '.jsonl')] = {
    unique_completed_sequences: seen.size,
    columns: ['attempted', 'succeeded', 'skipped', 'expected_reverts'],
    totals: [0, 1, 2, 3].map(index => Object.values(outcomes).reduce((total, values) => total + values[index], 0)),
    operations: outcomes,
  };
}

// Keep the report deterministic, including operation names and nested metadata.
function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map(key => [key, sortKeys(value[key])]));
  }
  return value;
}

console.log(JSON.stringify(sortKeys(summary), null, 2));
