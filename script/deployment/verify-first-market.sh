#!/usr/bin/env bash
# verify-first-market.sh — read-only per-phase verification driven by the deployer's market config.
#                          Mirrors deploy-first-market.sh's phase pattern. No broadcast — view calls only.
#
# Required environment variables:
#   RPC_URL              — target network RPC endpoint
#   MARKET_CONFIG_JSON   — path to the deployer's market config JSON (the same one used by
#                          deploy-first-market.sh)
#
# Optional environment variables:
#   GLOBAL_CONFIG_JSON   — explicit path to the per-network global config. Defaults to empty,
#                          which lets the Solidity entrypoint auto-resolve
#                          `script/config/globals/<network.name>.json` from the marketConfig's
#                          network block.
#
# Usage:
#   export RPC_URL=https://...
#   export MARKET_CONFIG_JSON=path/to/market.json
#
#   ./script/deployment/verify-first-market.sh verifyDeployMarket
#   ./script/deployment/verify-first-market.sh verifyActivateMarket
#   ./script/deployment/verify-first-market.sh verifyBondMarket
#   ./script/deployment/verify-first-market.sh verifyCancelMarket

set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
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
    verifyDeployMarket | verifyActivateMarket | verifyBondMarket | verifyCancelMarket) ;;
    *)
        echo "ERROR: phase must be one of: verifyDeployMarket | verifyActivateMarket | verifyBondMarket | verifyCancelMarket" >&2
        echo "Usage: $0 <phase>" >&2
        exit 1
        ;;
esac

echo "=== VerifyFirstMarket :: $PHASE ==="
echo "RPC_URL:            $RPC_URL"
echo "MARKET_CONFIG_JSON: $MARKET_CONFIG_JSON"
echo "GLOBAL_CONFIG_JSON: ${GLOBAL_CONFIG_JSON:-<auto-resolve from market config network.name>}"
echo

forge script script/VerifyFirstMarket.s.sol:VerifyFirstMarket \
    --sig "${PHASE}(string,string)" "$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" \
    --rpc-url "$RPC_URL" \
    -vvvv
