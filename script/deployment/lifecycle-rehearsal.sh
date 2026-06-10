#!/usr/bin/env bash
# lifecycle-rehearsal.sh — Fork-based rehearsal of the per-market lifecycle against the
# live-deployed protocol singletons. Two phase entrypoints:
#   e2e     — full success lifecycle (deployMarket → activateMarket → bondMarket →
#             deposit/withdraw cycle → oracle update → reward distribution → confirms)
#   cancel  — pre-bond exit (deployMarket → wait → cancelMarket)
#
# The Solidity script internally `vm.createFork`s; no real on-chain effect (always invoked
# without `--broadcast`). Useful as a pre-flight before each real mainnet operator action.
#
# Required environment variables:
#   RPC_URL              — target network RPC endpoint
#   MARKET_CONFIG_JSON   — deployer's market config (TEMPLATE.json is the seed to copy + fill).
#   At least ONE of:
#     SENDER             — explicit msg.sender for the rehearsal (no signing). Use this to
#                          rehearse against your actual production deploy address's live state
#                          while signing with a throwaway dev key.
#     PRIVATE_KEY        — signing key. forge derives msg.sender from it when SENDER is unset.
#
# Optional environment variables:
#   GLOBAL_CONFIG_JSON   — explicit path to per-network global config. Defaults to empty,
#                          which lets the Solidity entrypoint auto-resolve
#                          `script/config/globals/<network.name>.json` from the marketConfig.
#
# Notes:
#   - The rehearsal SNAPSHOTS `.deployed.*` from MARKET_CONFIG_JSON at entry and RESTORES it
#     at exit, so the file is left untouched after a successful run. If the rehearsal reverts
#     mid-flight, restore does not fire — run `git checkout $MARKET_CONFIG_JSON` to recover.
#   - Always runs without `--broadcast`. The Solidity script's `vm.createFork` provides the
#     rehearsal environment.

set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
: "${MARKET_CONFIG_JSON:?MARKET_CONFIG_JSON is required}"

if [[ -z "${SENDER:-}" && -z "${PRIVATE_KEY:-}" ]]; then
    echo "ERROR: at least one of SENDER or PRIVATE_KEY must be set" >&2
    echo "  SENDER      — explicit msg.sender address (no signing)" >&2
    echo "  PRIVATE_KEY — signing key (forge derives sender from it if SENDER unset)" >&2
    exit 1
fi

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
    e2e)    SIG_FN="runE2E" ;;
    cancel) SIG_FN="runCancel" ;;
    *)
        echo "ERROR: phase must be 'e2e' or 'cancel'" >&2
        echo "Usage: $0 <e2e|cancel>" >&2
        exit 1
        ;;
esac

FORGE_AUTH_ARGS=()
[[ -n "${SENDER:-}" ]] && FORGE_AUTH_ARGS+=(--sender "$SENDER")
[[ -n "${PRIVATE_KEY:-}" ]] && FORGE_AUTH_ARGS+=(--private-key "$PRIVATE_KEY")

echo "=== LifecycleRehearsal :: $PHASE (fork mode, no broadcast) ==="
echo "RPC_URL:            $RPC_URL"
echo "MARKET_CONFIG_JSON: $MARKET_CONFIG_JSON"
echo "GLOBAL_CONFIG_JSON: ${GLOBAL_CONFIG_JSON:-<auto-resolve from market config network.name>}"
echo "SENDER:             ${SENDER:-<derived from PRIVATE_KEY>}"
if [[ "$PHASE" == "e2e" ]]; then
    echo "expected wall-clock: ~5-10 min (15 phases against a live fork)"
fi
echo

START_TIME=$SECONDS

forge script script/LifecycleRehearsal.s.sol:LifecycleRehearsal \
    --sig "${SIG_FN}(string,string)" "$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" \
    --rpc-url "$RPC_URL" \
    "${FORGE_AUTH_ARGS[@]}" \
    --skip-simulation \
    -vvvv

echo
echo "=== LifecycleRehearsal :: $PHASE done in $((SECONDS - START_TIME))s ==="
