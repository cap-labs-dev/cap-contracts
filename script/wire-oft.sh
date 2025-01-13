#!/bin/sh

#set -x #echo on

ACCOUNT=cap-dev

SOURCE_CHAIN=sepolia
TARGET_CHAIN=arbitrum-sepolia

# scUSD
#SOURCE_LOCKBOX=0xE2be24Ea84ff4935561910682a6D598a3B8Ea520
#TARGET_TOKEN=0x939Ee9Df270aa428149eBE2277B024aE096759fC

# cUSD
SOURCE_LOCKBOX=0x8c170da3f52cB59b4b51FA1cadBE0d4a6bFf996e
TARGET_TOKEN=0x3E47E3003338023C96286f524AD4bB84FA82a3C4

# ------------------

get_chain_id() {
    local chain=$1
    cast cid --rpc-url $chain
}

get_lz_config() {
    local chain=$1
    local chain_id=$(get_chain_id $chain)
    local key=$2
    cat script/config/layerzero-v2-deployments.json | jq -r "to_entries | map(select(.value.nativeChainId == $chain_id)) | .[0].value.$key"
}

# ------------------

SOURCE_EID=$(get_lz_config $SOURCE_CHAIN "eid")
TARGET_EID=$(get_lz_config $TARGET_CHAIN "eid")
SOURCE_LZ_ENDPOINT=$(get_lz_config $SOURCE_CHAIN "endpointV2")
TARGET_LZ_ENDPOINT=$(get_lz_config $TARGET_CHAIN "endpointV2")

# ------------------

echo "cast send --rpc-url $SOURCE_CHAIN --account $ACCOUNT $SOURCE_LOCKBOX 'setPeer(uint32,bytes32)' $TARGET_EID $(cast to-bytes32 $TARGET_TOKEN)"
echo "cast send --rpc-url $TARGET_CHAIN --account $ACCOUNT $TARGET_TOKEN 'setPeer(uint32,bytes32)' $SOURCE_EID $(cast to-bytes32 $SOURCE_LOCKBOX)"
