#!/bin/bash

# This script runs inside the Docker container and tests a single mutant
# It expects mutations to be present in the /mutant directory and merges them with /app/contracts
# Additional arguments will be passed to the forge test command

# Check if the mutant directory exists and is not empty
if [ -d "/mutant" ] && [ "$(ls -A /mutant)" ]; then
    # Copy all files from /mutant to their respective locations in /app/contracts
    cp -r /mutant/* /app/contracts/
else
    echo "No mutations found in /mutant directory"
    exit 1
fi

# Run the test with any additional arguments
# Invariants are too slow to run on every mutant
exec forge test --no-match-path 'test/**/*.invariants.t.sol' --root /app --fail-fast "$@"
