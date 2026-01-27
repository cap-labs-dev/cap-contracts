import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import fs from "fs";

// Get address from command line argument
const address = process.argv[2];

if (!address) {
  console.error('Error: Please provide an address as an argument');
  console.error('Usage: node MerkleProof.js <address>');
  process.exit(1);
}

// Validate address format
if (!address.startsWith('0x') || address.length !== 42) {
  console.error('Error: Invalid address format. Address must start with 0x and be 42 characters long.');
  process.exit(1);
}

// (1)
const treeData = JSON.parse(fs.readFileSync("tree.json", "utf8"));
const tree = StandardMerkleTree.load(treeData.dump);

// (2)
const searchAddress = address.toLowerCase();
let found = false;

for (const [i, v] of tree.entries()) {
  const entryAddress = v[0].toLowerCase();
  if (entryAddress === searchAddress) {
    // (3)
    const proof = tree.getProof(i);
    console.log('Found entry!');
    console.log('Value:', v);
    console.log('Proof:', proof);
    found = true;
    break;
  }
}

if (!found) {
  console.error(`Address ${address} not found in merkle tree.`);
  process.exit(1);
}