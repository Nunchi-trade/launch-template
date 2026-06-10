#!/usr/bin/env bash
# user-flow.sh — broadcast user-facing actions (deposit / withdraw / confirmWithdraw) against
# a deployed market via EXRouter. Each phase runs `PrecompileStubs.etchAll()` then performs
# inline pre-broadcast snapshot + post-broadcast delta verification.
#
# Required env vars:
#   RPC_URL              — target network RPC endpoint
#   PRIVATE_KEY          — broadcasting EOA (the depositor / withdrawor)
#   MARKET_CONFIG_JSON   — deployer's market config with `.deployed.*` populated
#
# Optional env vars:
#   GLOBAL_CONFIG_JSON   — explicit path to per-network global config. Empty defaults to
#                          auto-resolve via `network.name`.
#   SKIP_SIMULATION=0    — re-enable Phase 2 forge re-simulation (default = skip).
#                          Phase 1 precompile reverts are handled by `PrecompileStubs.etchAll()`
#                          inside the script entry; Phase 2 does NOT carry that etch state.
#   BROADCAST=1          — REQUIRED to send a real on-chain tx. Default 0 = fork-only sim.
#
# Usage:
#   ./script/deployment/user-flow.sh deposit         <amountWei>     [<recipient>] [<dataHex>]
#   ./script/deployment/user-flow.sh withdraw        <sharesWei>     [<recipient>] [<maxBlockedShares>] [<dataHex>]
#   ./script/deployment/user-flow.sh confirmWithdraw <withdrawalId>  [<recipient>]
#
# Defaults:
#   recipient        — 0x0000…0 (Solidity script resolves to msg.sender)
#   dataHex          — 0x (empty bytes; works for NoOp gates — pass explicit hex for active gates)
#   maxBlockedShares — type(uint256).max (accept any BWQ blocking — relevant only in LIVE phase)

set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${MARKET_CONFIG_JSON:?MARKET_CONFIG_JSON is required}"

if [[ ! -f "$MARKET_CONFIG_JSON" ]]; then
    echo "ERROR: MARKET_CONFIG_JSON not found at $MARKET_CONFIG_JSON" >&2
    exit 1
fi

GLOBAL_CONFIG_JSON="${GLOBAL_CONFIG_JSON:-}"
if [[ -n "$GLOBAL_CONFIG_JSON" && ! -f "$GLOBAL_CONFIG_JSON" ]]; then
    echo "ERROR: GLOBAL_CONFIG_JSON set but not found at $GLOBAL_CONFIG_JSON" >&2
    exit 1
fi

PHASE="${1:-}"
case "$PHASE" in
    deposit)
        AMOUNT="${2:?deposit: amountWei is required}"
        RECIPIENT="${3:-0x0000000000000000000000000000000000000000}"
        DATA="${4:-0x}"
        SIG='deposit(string,string,uint256,address,bytes)'
        ARGS=("$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" "$AMOUNT" "$RECIPIENT" "$DATA")
        ;;
    withdraw)
        SHARES="${2:?withdraw: sharesWei is required}"
        RECIPIENT="${3:-0x0000000000000000000000000000000000000000}"
        MAX_BLOCKED="${4:-115792089237316195423570985008687907853269984665640564039457584007913129639935}"
        DATA="${5:-0x}"
        SIG='withdraw(string,string,uint256,address,uint256,bytes)'
        ARGS=("$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" "$SHARES" "$RECIPIENT" "$MAX_BLOCKED" "$DATA")
        ;;
    confirmWithdraw)
        WITHDRAWAL_ID="${2:?confirmWithdraw: withdrawalId is required}"
        RECIPIENT="${3:-0x0000000000000000000000000000000000000000}"
        SIG='confirmWithdraw(string,string,uint256,address)'
        ARGS=("$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" "$WITHDRAWAL_ID" "$RECIPIENT")
        ;;
    *)
        echo "ERROR: phase must be one of: deposit | withdraw | confirmWithdraw" >&2
        echo "Usage:" >&2
        echo "  $0 deposit         <amountWei>     [<recipient>] [<dataHex>]" >&2
        echo "  $0 withdraw        <sharesWei>     [<recipient>] [<maxBlockedShares>] [<dataHex>]" >&2
        echo "  $0 confirmWithdraw <withdrawalId>  [<recipient>]" >&2
        exit 1
        ;;
esac

SKIP_SIM_ARG="--skip-simulation"
[[ "${SKIP_SIMULATION:-1}" == "0" ]] && SKIP_SIM_ARG=""

BROADCAST_ARG=""
if [[ "${BROADCAST:-0}" == "1" ]]; then
    BROADCAST_ARG="--broadcast"
    echo "BROADCAST=1 — sending REAL on-chain transaction to $RPC_URL"
else
    echo "BROADCAST=0 (default) — fork simulation only (no on-chain tx)"
    echo "         Set BROADCAST=1 to send for real."
fi

echo "=== UserFlow :: $PHASE ==="
echo "RPC_URL:            $RPC_URL"
echo "MARKET_CONFIG_JSON: $MARKET_CONFIG_JSON"
echo "GLOBAL_CONFIG_JSON: ${GLOBAL_CONFIG_JSON:-<auto-resolve from market config network.name>}"
echo "broadcast:          ${BROADCAST:-0}"
echo

forge script script/UserFlow.s.sol:UserFlow \
    --sig "$SIG" "${ARGS[@]}" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    $BROADCAST_ARG \
    $SKIP_SIM_ARG \
    -vvvv
