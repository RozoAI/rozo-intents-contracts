#!/usr/bin/env bash
# Read Nick's deterministic deployment proxy runtime on every target chain and compare it
# byte-for-byte with the Ethereum mainnet copy. Read-only (eth_chainId + eth_getCode).
# Usage: script/check-nick-factory.sh   (needs curl + jq + arc-cast)
set -euo pipefail

NICK=0x4e59b44847b379578588920cA78FbF26c0B4956C
EXPECTED=0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3

declare -a CHAINS=(
  "1|Ethereum|https://ethereum-rpc.publicnode.com"
  "8453|Base|https://mainnet.base.org"
  "56|BNB Chain|https://bsc-dataseed.bnbchain.org"
  "42161|Arbitrum One|https://arb1.arbitrum.io/rpc"
  "137|Polygon|https://polygon-bor-rpc.publicnode.com"
  "999|HyperEVM|https://rpc.hyperliquid.xyz/evm"
  "480|World Chain|https://worldchain-mainnet.g.alchemy.com/public"
  "5042|Arc|https://rpc.mainnet.arc.io"
  "42220|Celo|https://forno.celo.org"
  "84532|Base Sepolia|https://sepolia.base.org"
  "5042002|Arc testnet|https://rpc.testnet.arc.io"
  "11142220|Celo Sepolia|https://forno.celo-sepolia.celo-testnet.org"
)

rpc() { curl -s -m 20 -X POST -H 'content-type: application/json' --data "$2" "$1" | jq -r .result; }

printf '| chainId | chain | rpc chainId | code bytes | keccak256(runtime) | byte-identical to Ethereum |\n'
printf '| --- | --- | --- | --- | --- | --- |\n'
for row in "${CHAINS[@]}"; do
  IFS='|' read -r id name url <<<"$row"
  cid_hex=$(rpc "$url" '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' || echo null)
  code=$(rpc "$url" "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$NICK\",\"latest\"]}" || echo null)
  if [[ "$cid_hex" == "null" || -z "$cid_hex" ]]; then
    printf '| %s | %s | unreachable | - | - | - |\n' "$id" "$name"; continue
  fi
  cid=$((cid_hex))
  bytes=$(( (${#code} - 2) / 2 ))
  hash=$(arc-cast keccak "$code")
  same=no; [[ "$(printf %s "$code" | tr A-Z a-z)" == "$(printf %s "$EXPECTED" | tr A-Z a-z)" && "$cid" == "$id" ]] && same=yes
  printf '| %s | %s | %s | %s | `%s` | %s |\n' "$id" "$name" "$cid" "$bytes" "$hash" "$same"
done
