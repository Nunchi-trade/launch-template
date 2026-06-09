#!/usr/bin/env bash
# deploy-first-market.sh — per-market lifecycle phases against a `markets[label]` entry
#                          in the JSON config.
#
# Phases (run separately, one tx per phase, with off-chain HC confirmation between activate + bond):
#   deployMarket     — escrow opBond + deploy 13-contract per-market suite
#   activateMarket   — bridge activation token (USDC/USDH) to HC for Router + Splitter + Throttle
#   bondMarket       — stake opBond → Router → HC (transitions market UNBONDED → FUNDING)
#   cancelMarket     — abort a pre-bond market + refund opBond (requires cancelEligibleAt elapsed)
#
# Pass the phase as the first positional arg. The second positional arg selects the markets[] entry
# by its `label` field; defaults to "firstMarket".
#
# Required environment variables:
#   RPC_URL              — target network RPC endpoint
#   PRIVATE_KEY          — deployer EOA (must hold opBond HYPE for the deployMarket phase)
#   CONFIG_JSON          — path to per-network JSON (.markets[] populated for the target label)
#
# Optional environment variables (verification — deployMarket phase only):
#   VERIFY=1             — enable inline Etherscan verification on deployMarket phase
#                          (no impact on other phases — those don't deploy contracts)
#   ETHERSCAN_API_KEY    — required when VERIFY=1
#   VERIFIER_URL         — override chain-id-derived Etherscan API URL
#   BROADCAST=1          — REQUIRED to send real on-chain txs. Default is BROADCAST=0
#                          (fork-only simulation, no on-chain effect). `vm.writeJson` still
#                          mutates the config file even when BROADCAST=0; copy it first if
#                          you want the original clean.
#
# Usage:
#   # Default label "firstMarket"
#   ./script/deployment/deploy-first-market.sh deployMarket
#   ./script/deployment/deploy-first-market.sh activateMarket
#   ./script/deployment/deploy-first-market.sh bondMarket
#
#   # Explicit label (e.g., a separate cancel-test market in the same config)
#   ./script/deployment/deploy-first-market.sh deployMarket cancelTest
#   # wait at least globalConfig.unwindDelay seconds (snapshotted at deploy time)
#   ./script/deployment/deploy-first-market.sh cancelMarket cancelTest

set -euo pipefail

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${CONFIG_JSON:?CONFIG_JSON is required}"

if [[ ! -f "$CONFIG_JSON" ]]; then
    echo "ERROR: CONFIG_JSON not found at $CONFIG_JSON" >&2
    exit 1
fi

PHASE="${1:-}"
LABEL="${2:-firstMarket}"
case "$PHASE" in
    deployMarket | activateMarket | bondMarket | cancelMarket) ;;
    *)
        echo "ERROR: phase must be one of: deployMarket | activateMarket | bondMarket | cancelMarket" >&2
        echo "Usage: $0 <phase> [<label>]   (default label: firstMarket)" >&2
        exit 1
        ;;
esac

CHAIN_ID=$(python3 -c "import json,sys; print(json.load(open('$CONFIG_JSON'))['network']['chainId'])")

# Etherscan API v2: single unified endpoint; chain selected via the `chainid` query param.
# Verification only fires on deployMarket phase (activateMarket/bondMarket/cancelMarket
# don't deploy new code).
case "$CHAIN_ID" in
    999)   VERIFIER_URL_DEFAULT="https://api.etherscan.io/v2/api?chainid=999" ;;
    998)   VERIFIER_URL_DEFAULT="https://api.etherscan.io/v2/api?chainid=998" ;;
    31337) VERIFIER_URL_DEFAULT="" ;;
    *)     VERIFIER_URL_DEFAULT="" ;;
esac
VERIFIER_URL="${VERIFIER_URL:-$VERIFIER_URL_DEFAULT}"

VERIFY_ARGS=()
if [[ "${VERIFY:-0}" == "1" && "$PHASE" == "deployMarket" ]]; then
    : "${ETHERSCAN_API_KEY:?VERIFY=1 requires ETHERSCAN_API_KEY}"
    if [[ -z "$VERIFIER_URL" ]]; then
        echo "ERROR: VERIFY=1 requires VERIFIER_URL (no built-in default for chain $CHAIN_ID)" >&2
        exit 1
    fi
    VERIFY_ARGS+=(
        --verify
        --verifier etherscan
        --verifier-url "$VERIFIER_URL"
        --etherscan-api-key "$ETHERSCAN_API_KEY"
    )
fi

# Phase 1 precompile reverts handled by `PrecompileStubs.etchAll()` inside each script
# entry; Phase 2 (forge's on-chain re-simulation) does NOT carry the etch state so the
# same precompile addresses are empty in its EVM — skip Phase 2 by default. Set
# SKIP_SIMULATION=0 only when you've separately patched Phase 2.
SKIP_SIM_ARG="--skip-simulation"
if [[ "${SKIP_SIMULATION:-1}" == "0" ]]; then
    SKIP_SIM_ARG=""
fi

# BROADCAST is opt-in: default 0 (fork-only sim). Operator must set BROADCAST=1 explicitly.
BROADCAST_ARG=""
if [[ "${BROADCAST:-0}" == "1" ]]; then
    BROADCAST_ARG="--broadcast"
    echo "BROADCAST=1 — sending REAL on-chain transactions to $RPC_URL"
else
    VERIFY_ARGS=()
    echo "BROADCAST=0 (default) — fork simulation only (no on-chain txs, no verification)"
    echo "WARNING: vm.writeJson still mutates $CONFIG_JSON — point at a throwaway copy if needed."
    echo "         Set BROADCAST=1 to deploy for real."
fi

echo "=== DeployFirstMarket :: $PHASE ($LABEL) ==="
echo "RPC_URL:     $RPC_URL"
echo "CONFIG_JSON: $CONFIG_JSON"
echo "label:       $LABEL"
echo "chainId:     $CHAIN_ID"
echo "verify:      ${VERIFY:-0}${VERIFY:+ ($VERIFIER_URL)}"
echo "skip-sim:    ${SKIP_SIMULATION:-1}"
echo "broadcast:   ${BROADCAST:-0}"
echo

forge script script/DeployFirstMarket.s.sol:DeployFirstMarket \
    --sig "${PHASE}(string,string)" "$CONFIG_JSON" "$LABEL" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    $BROADCAST_ARG \
    $SKIP_SIM_ARG \
    ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"} \
    -vvvv
