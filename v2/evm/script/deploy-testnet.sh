#!/usr/bin/env bash
# Testnet deploy wrapper for script/DeployV2.s.sol.
#
#   DEPLOYER_PRIVATE_KEY=... script/deploy-testnet.sh <base_sepolia|arc_testnet|celo_sepolia> [--broadcast]
#   SCRIPT=script/TestnetFlushDrill.s.sol DRILL_NATIVE_WEI=... script/deploy-testnet.sh <net> [--broadcast]
#
# - The private key is read ONLY from the DEPLOYER_PRIVATE_KEY environment variable (the Solidity
#   script reads it with vm.envUint). It is never placed in argv, echoed or written to disk.
# - Chain allowlist is enforced twice: here (eth_chainId from the RPC) and inside the script.
# - Fee mode is never mixed: Arc uses legacy (gasPrice only) with a floor of 25 gwei and >= 1.2x the
#   live base fee; Base Sepolia / Celo Sepolia use plain EIP-1559 estimation.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY must be set in the environment (never pass it as an argument)}"
export DEPLOYER_PRIVATE_KEY

FORGE=${FORGE:-arc-forge}
CAST=${CAST:-arc-cast}
NET=${1:?network: base_sepolia | arc_testnet | celo_sepolia}
MODE=${2:-}

case "$NET" in
  base_sepolia) URL=https://sepolia.base.org;                      WANT=84532;    FAMILY=ethereum ;;
  arc_testnet)  URL=https://rpc.testnet.arc.io;                     WANT=5042002;  FAMILY=arc ;;
  celo_sepolia) URL=https://forno.celo-sepolia.celo-testnet.org;    WANT=11142220; FAMILY=ethereum ;;
  *) echo "unknown network $NET" >&2; exit 2 ;;
esac

GOT=$("$CAST" chain-id --rpc-url "$URL")
if [[ "$GOT" != "$WANT" ]]; then
  echo "refusing: RPC $URL reports chainId $GOT, expected $WANT" >&2; exit 3
fi
case "$GOT" in 84532|5042002|11142220) ;; *) echo "refusing: chainId $GOT not in testnet allowlist" >&2; exit 3 ;; esac

ARGS=(script "${SCRIPT:-script/DeployV2.s.sol}" --rpc-url "$URL" -vvvv)
if [[ "$FAMILY" == "arc" ]]; then
  BASEFEE=$("$CAST" base-fee --rpc-url "$URL")
  FLOOR=25000000000
  GP=$(( BASEFEE * 12 / 10 )); (( GP < FLOOR )) && GP=$FLOOR
  echo "arc: basefee=$BASEFEE wei, using legacy gasPrice=$GP wei"
  ARGS+=(--network arc --legacy --with-gas-price "$GP")
fi
if [[ "$MODE" == "--broadcast" ]]; then
  ARGS+=(--broadcast --slow)
fi

exec "$FORGE" "${ARGS[@]}"
