#!/bin/sh

#set -x #echo on

ACCOUNT=cap-dev

SOURCE_CHAIN=sepolia
TARGET_CHAIN=arbitrum-sepolia

SOURCE_LOCKBOX=0x75279C6Dd77bFF08DcE9E4CD4EAc7162c4f38039
TARGET_TOKEN=0xB196Add2013311ad29755A537369F74978Fb7477

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
