#!/usr/bin/env bash
# operator-flow.sh — broadcast operator lifecycle calls on the per-market EXManager:
#   fund            FUNDING -> LAUNCHING (locks in stake once reserves >= tier floor)
#   launch          LAUNCHING -> LIVE (submits Kinetiq-signed EIP712 wallet payload;
#                   registers the HC API wallet via CoreWriter)
#   setUnwindPhase  queue (true) or cancel (false) voluntary wind-down
#   unwind          finalize wind-down (post-delay; opBond sweeps to deployer)
#
# Required env vars:
#   RPC_URL              — target network RPC endpoint
#   PRIVATE_KEY          — broadcasting EOA (must hold OPERATOR_ROLE on the market's EXManager)
#   MARKET_CONFIG_JSON   — deployer's market config with `.deployed.marketId` populated
#
# Optional env vars:
#   GLOBAL_CONFIG_JSON   — explicit path to per-network global config. Empty defaults to
#                          auto-resolve via `network.name` in the market config.
#   SKIP_SIMULATION=0    — re-enable Phase 2 forge re-simulation (default = skip; Phase 1
#                          precompile reverts are handled by PrecompileStubs.etchAll() inside
#                          the script entry).
#   BROADCAST=1          — REQUIRED to send a real on-chain tx. Default 0 = fork-only sim.
#
# Usage:
#   ./script/deployment/operator-flow.sh fund
#   ./script/deployment/operator-flow.sh launch         <walletDataHex> <walletSignatureHex>
#   ./script/deployment/operator-flow.sh setUnwindPhase <true|false>
#   ./script/deployment/operator-flow.sh unwind

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
    fund)
        SIG='fund(string,string)'
        ARGS=("$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON")
        ;;
    launch)
        WALLET_DATA="${2:?launch: walletDataHex is required}"
        WALLET_SIG="${3:?launch: walletSignatureHex is required}"
        SIG='launch(string,string,bytes,bytes)'
        ARGS=("$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" "$WALLET_DATA" "$WALLET_SIG")
        ;;
    setUnwindPhase)
        WINDING_DOWN="${2:?setUnwindPhase: <true|false> is required}"
        case "$WINDING_DOWN" in
            true|false) ;;
            *) echo "ERROR: setUnwindPhase arg must be 'true' or 'false', got '$WINDING_DOWN'" >&2; exit 1 ;;
        esac
        SIG='setUnwindPhase(string,string,bool)'
        ARGS=("$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" "$WINDING_DOWN")
        ;;
    unwind)
        SIG='unwind(string,string)'
        ARGS=("$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON")
        ;;
    *)
        echo "ERROR: phase must be one of: fund | launch | setUnwindPhase | unwind" >&2
        echo "Usage:" >&2
        echo "  $0 fund" >&2
        echo "  $0 launch         <walletDataHex> <walletSignatureHex>" >&2
        echo "  $0 setUnwindPhase <true|false>" >&2
        echo "  $0 unwind" >&2
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

echo "=== OperatorFlow :: $PHASE ==="
echo "RPC_URL:            $RPC_URL"
echo "MARKET_CONFIG_JSON: $MARKET_CONFIG_JSON"
echo "GLOBAL_CONFIG_JSON: ${GLOBAL_CONFIG_JSON:-<auto-resolve from market config network.name>}"
echo "broadcast:          ${BROADCAST:-0}"
echo

forge script script/OperatorFlow.s.sol:OperatorFlow \
    --sig "$SIG" "${ARGS[@]}" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    $BROADCAST_ARG \
    $SKIP_SIM_ARG \
    -vvvv
