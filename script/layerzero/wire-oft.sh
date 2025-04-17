#!/bin/sh

#set -x #echo on

ACCOUNT=cap-dev

SOURCE_CHAIN=$1
SOURCE_LOCKBOX=$2

TARGET_CHAIN=$3
TARGET_TOKEN=$4

# Define allowed chains
ALLOWED_CHAINS=("sepolia" "holesky" "arbitrum-sepolia" "megaeth-testnet")

# Validate chain names
if ! printf '%s\n' "${ALLOWED_CHAINS[@]}" | grep -q "^$SOURCE_CHAIN$"; then
    echo "Error: Source chain must be one of: ${ALLOWED_CHAINS[*]}"
    exit 1
fi

if ! printf '%s\n' "${ALLOWED_CHAINS[@]}" | grep -q "^$TARGET_CHAIN$"; then
    echo "Error: Target chain must be one of: ${ALLOWED_CHAINS[*]}"
    exit 1
fi

# Validate addresses are hex
if ! [[ $SOURCE_LOCKBOX =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Error: Source lockbox must be a valid hex address"
    exit 1
fi

if ! [[ $TARGET_TOKEN =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Error: Target token must be a valid hex address"
    exit 1
fi



# ------------------

get_chain_id() {
    local chain=$1
    cast cid --rpc-url $chain
}

get_lz_config() {
    local chain=$1
    local chain_id=$(get_chain_id $chain)
    local key=$2
    cat config/layerzero-v2-deployments.json | jq -r "to_entries | map(select(.value.nativeChainId == $chain_id)) | .[0].value.$key"
}

# ------------------

SOURCE_EID=$(get_lz_config $SOURCE_CHAIN "eid")
TARGET_EID=$(get_lz_config $TARGET_CHAIN "eid")
SOURCE_LZ_ENDPOINT=$(get_lz_config $SOURCE_CHAIN "endpointV2")
TARGET_LZ_ENDPOINT=$(get_lz_config $TARGET_CHAIN "endpointV2")

# ------------------

echo "cast send --rpc-url $SOURCE_CHAIN --account $ACCOUNT $SOURCE_LOCKBOX 'setPeer(uint32,bytes32)' $TARGET_EID $(cast to-uint256 $TARGET_TOKEN)"
echo "cast send --rpc-url $TARGET_CHAIN --account $ACCOUNT $TARGET_TOKEN 'setPeer(uint32,bytes32)' $SOURCE_EID $(cast to-uint256 $SOURCE_LOCKBOX)"
