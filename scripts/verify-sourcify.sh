#!/usr/bin/env bash
# Verify the vault and its three constructor-created children. Never signs or broadcasts.
set -euo pipefail

if (( $# < 2 || $# > 3 )); then
    echo 'Usage: bash scripts/verify-sourcify.sh <Robinhood RPC URL> <deployed SIMDVault address> [creation transaction hash]' >&2
    exit 2
fi

rpc="$1"
vault="$2"
if [[ ! "$vault" =~ ^0x[0-9a-fA-F]{40}$ || "$vault" == 0x0000000000000000000000000000000000000000 ]]; then
    echo 'Supply the confirmed SIMDVault address from the deployment receipt.' >&2
    exit 2
fi
if [[ "$(cast chain-id --rpc-url "$rpc")" != 4663 ]]; then
    echo 'RPC must serve Robinhood Chain, chain ID 4663.' >&2
    exit 1
fi

staking=$(cast call "$vault" 'stakeRewards()(address)' --rpc-url "$rpc")
jobs=$(cast call "$vault" 'jobsVault()(address)' --rpc-url "$rpc")
airdrop=$(cast call "$vault" 'airdrop()(address)' --rpc-url "$rpc")
notice='"TEST ONLY. SIMD TEST 3 vault set. Not the real SIMD. Do not buy."'
for contract in "$vault" "$staking" "$jobs" "$airdrop"; do
    if [[ "$(cast call "$contract" 'NOTICE()(string)' --rpc-url "$rpc")" != "$notice" ]]; then
        echo "Unexpected NOTICE at $contract" >&2
        exit 1
    fi
done
for child in "$staking" "$jobs" "$airdrop"; do
    linked_vault=$(cast call "$child" 'vault()(address)' --rpc-url "$rpc")
    if [[ "${linked_vault,,}" != "${vault,,}" ]]; then
        echo "Incorrect vault link at $child" >&2
        exit 1
    fi
done
linked_jobs=$(cast call "$staking" 'jobsVault()(address)' --rpc-url "$rpc")
linked_staking=$(cast call "$jobs" 'stakeRewards()(address)' --rpc-url "$rpc")
if [[ "${linked_jobs,,}" != "${jobs,,}" || "${linked_staking,,}" != "${staking,,}" ]]; then
    echo 'The staking/jobs links do not match the vault children.' >&2
    exit 1
fi

creation_args=()
if (( $# == 3 )); then
    if [[ ! "$3" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
        echo 'Creation transaction hash must be 32 bytes.' >&2
        exit 2
    fi
    creation_args=(--creation-transaction-hash "$3")
fi

addresses=("$vault" "$staking" "$jobs" "$airdrop")
sources=('src/SIMDVault.sol:SIMDVault' 'src/StakeRewards.sol:StakeRewards' 'src/JobsVault.sol:JobsVault' 'src/SimdAirdrop.sol:SimdAirdrop')
for i in 0 1 2 3; do
    forge verify-contract "${addresses[$i]}" "${sources[$i]}" \
        --chain 4663 --rpc-url "$rpc" --verifier sourcify --watch \
        "${creation_args[@]}"
    echo "https://repo.sourcify.dev/4663/${addresses[$i]}"
done
