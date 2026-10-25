#!/usr/bin/env bash
# Mainnet deploy wrapper for script/DeployV2.s.sol (one chain per invocation).
#
#   DEPLOYER_PRIVATE_KEY=... script/deploy-mainnet.sh <ethereum|base|bnb|arbitrum|polygon|hyperevm|world|arc|celo> [--broadcast]
#
# - The private key is read ONLY from the DEPLOYER_PRIVATE_KEY environment variable (the Solidity
#   script reads it with vm.envUint). It is never placed in argv, echoed or written to disk.
# - Broadcast is allowed only for the chain named on the command line: the wrapper reads eth_chainId
#   from the RPC, checks it against the expected id, and exports it as MAINNET_CHAIN_ID; the Solidity
#   script re-reads eth_chainId and refuses to broadcast unless it equals MAINNET_CHAIN_ID.
# - Fee mode is never mixed: Arc uses legacy (gasPrice only) with a floor of 25 gwei and >= 1.2x the
#   live base fee; every other chain uses plain EIP-1559 estimation.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY must be set in the environment (never pass it as an argument)}"
export DEPLOYER_PRIVATE_KEY

FORGE=${FORGE:-arc-forge}
CAST=${CAST:-arc-cast}
NET=${1:?network: ethereum | base | bnb | arbitrum | polygon | hyperevm | world | arc | celo}
MODE=${2:-}

case "$NET" in
  ethereum) URL=${RPC_URL:-https://ethereum-rpc.publicnode.com};              WANT=1;     FAMILY=ethereum ;;
  base)     URL=${RPC_URL:-https://base-rpc.publicnode.com};                  WANT=8453;  FAMILY=ethereum ;;
  bnb)      URL=${RPC_URL:-https://bsc-dataseed.bnbchain.org};                WANT=56;    FAMILY=legacy ;;
  arbitrum) URL=${RPC_URL:-https://arb1.arbitrum.io/rpc};                     WANT=42161; FAMILY=ethereum ;;
  polygon)  URL=${RPC_URL:-https://polygon-bor-rpc.publicnode.com};           WANT=137;   FAMILY=ethereum ;;
  hyperevm) URL=${RPC_URL:-https://rpc.hyperliquid.xyz/evm};                  WANT=999;   FAMILY=ethereum ;;
  world)    URL=${RPC_URL:-https://worldchain-mainnet.g.alchemy.com/public};  WANT=480;   FAMILY=ethereum ;;
  arc)      URL=${RPC_URL:-https://rpc.mainnet.arc.io};                       WANT=5042;  FAMILY=arc ;;
  celo)     URL=${RPC_URL:-https://forno.celo.org};                           WANT=42220; FAMILY=ethereum ;;
  *) echo "unknown network $NET" >&2; exit 2 ;;
esac

GOT=$("$CAST" chain-id --rpc-url "$URL")
if [[ "$GOT" != "$WANT" ]]; then
  echo "refusing: RPC $URL reports chainId $GOT, expected $WANT" >&2; exit 3
fi
case "$GOT" in 1|8453|56|42161|137|999|480|5042|42220) ;; *) echo "refusing: chainId $GOT not in mainnet allowlist" >&2; exit 3 ;; esac

ARGS=(script script/DeployV2.s.sol --rpc-url "$URL" -vvvv)
if [[ "$FAMILY" == "arc" ]]; then
  BASEFEE=$("$CAST" base-fee --rpc-url "$URL")
  FLOOR=25000000000
  GP=$(( BASEFEE * 12 / 10 )); (( GP < FLOOR )) && GP=$FLOOR
  echo "arc: basefee=$BASEFEE wei, using legacy gasPrice=$GP wei"
  ARGS+=(--network arc --legacy --with-gas-price "$GP")
elif [[ "$FAMILY" == "legacy" ]]; then
  # BNB Chain: legacy fee market (gasPrice only).
  ARGS+=(--legacy)
fi
if [[ "$MODE" == "--broadcast" ]]; then
  export MAINNET_CHAIN_ID="$GOT"
  ARGS+=(--broadcast --slow)
else
  unset MAINNET_CHAIN_ID
fi

echo "network=$NET chainId=$GOT rpc=$URL mode=${MODE:-dry-run}"
exec "$FORGE" "${ARGS[@]}"
