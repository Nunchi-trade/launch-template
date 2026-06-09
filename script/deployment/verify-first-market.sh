#!/usr/bin/env bash
# verify-first-market.sh — read-only per-phase verification of a markets[<label>] entry.
#                          Mirrors smoke-test.sh + deploy-first-market.sh's phase+label pattern.
#                          No broadcast — view calls only.
#
# Required environment variables:
#   RPC_URL      — target network RPC endpoint
#   CONFIG_JSON  — path to per-network JSON
#
# Usage:
#   ./script/deployment/verify-first-market.sh verifyDeployMarket [<label>]
#   ./script/deployment/verify-first-market.sh verifyActivateMarket [<label>]
#   ./script/deployment/verify-first-market.sh verifyBondMarket [<label>]
#   ./script/deployment/verify-first-market.sh verifyCancelMarket [<label>]
#
# `label` defaults to "firstMarket" if omitted.

set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
: "${CONFIG_JSON:?CONFIG_JSON is required}"

if [[ ! -f "$CONFIG_JSON" ]]; then
    echo "ERROR: CONFIG_JSON not found at $CONFIG_JSON" >&2
    exit 1
fi

PHASE="${1:-}"
LABEL="${2:-firstMarket}"
case "$PHASE" in
    verifyDeployMarket | verifyActivateMarket | verifyBondMarket | verifyCancelMarket) ;;
    *)
        echo "ERROR: phase must be one of: verifyDeployMarket | verifyActivateMarket | verifyBondMarket | verifyCancelMarket" >&2
        echo "Usage: $0 <phase> [<label>]   (default label: firstMarket)" >&2
        exit 1
        ;;
esac

echo "=== VerifyFirstMarket :: $PHASE ($LABEL) ==="
echo "RPC_URL:     $RPC_URL"
echo "CONFIG_JSON: $CONFIG_JSON"
echo

forge script script/VerifyFirstMarket.s.sol:VerifyFirstMarket \
    --sig "${PHASE}(string,string)" "$CONFIG_JSON" "$LABEL" \
    --rpc-url "$RPC_URL" \
    -vvvv
