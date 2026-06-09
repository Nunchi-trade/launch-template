#!/usr/bin/env bash
# deploy-first-market.sh — per-market lifecycle phases driven by the deployer's market config.
#
# Phases (run separately, one tx per phase, with off-chain HC confirmation between activate + bond):
#   deployMarket     — escrow opBond + deploy per-market suite
#   activateMarket   — bridge activation token (USDC) to HC for Router + Splitter + Throttle
#   bondMarket       — stake opBond → Router → HC (transitions market UNBONDED → FUNDING)
#   cancelMarket     — abort a pre-bond market + refund opBond (requires cancelEligibleAt elapsed)
#
# Pass the phase as the only positional arg. The deployer's market config + the per-network
# global config are picked up from env vars.
#
# Required environment variables:
#   RPC_URL              — target network RPC endpoint
#   PRIVATE_KEY          — deployer EOA (must hold opBond HYPE for the deployMarket phase)
#   MARKET_CONFIG_JSON   — path to the deployer's market config JSON (TEMPLATE.json is the seed
#                          to copy + fill in). Per-network protocol singletons come from the
#                          global config below.
#
# Optional environment variables:
#   GLOBAL_CONFIG_JSON   — explicit path to the per-network global config. Defaults to empty,
#                          which lets the Solidity entrypoint auto-resolve
#                          `script/config/globals/<network.name>.json` from the marketConfig's
#                          network block. Set explicitly to override (custom global config for
#                          forks, alternate deployments, etc.).
#   VERIFY=1             — enable inline Etherscan verification on deployMarket phase
#                          (no impact on other phases — those don't deploy contracts)
#   ETHERSCAN_API_KEY    — required when VERIFY=1
#   VERIFIER_URL         — override chain-id-derived Etherscan API URL
#   BROADCAST=1          — REQUIRED to send real on-chain txs. Default is BROADCAST=0
#                          (fork-only simulation, no on-chain effect). `vm.writeJson` still
#                          mutates the market config file even when BROADCAST=0; copy it first
#                          if you want the original clean.
#
# Usage:
#   export RPC_URL=https://...
#   export PRIVATE_KEY=0x...
#   export MARKET_CONFIG_JSON=path/to/market.json
#
#   ./script/deployment/deploy-first-market.sh deployMarket
#   ./script/deployment/deploy-first-market.sh activateMarket
#   ./script/deployment/deploy-first-market.sh bondMarket
#
#   # Override the auto-resolved global config:
#   export GLOBAL_CONFIG_JSON=path/to/custom-globals.json
#   ./script/deployment/deploy-first-market.sh deployMarket

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
    deployMarket | activateMarket | bondMarket | cancelMarket) ;;
    *)
        echo "ERROR: phase must be one of: deployMarket | activateMarket | bondMarket | cancelMarket" >&2
        echo "Usage: $0 <phase>" >&2
        exit 1
        ;;
esac

CHAIN_ID=$(python3 -c "import json,sys; print(json.load(open('$MARKET_CONFIG_JSON'))['network']['chainId'])")

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
    echo "WARNING: vm.writeJson still mutates $MARKET_CONFIG_JSON — point at a throwaway copy if needed."
    echo "         Set BROADCAST=1 to deploy for real."
fi

echo "=== DeployFirstMarket :: $PHASE ==="
echo "RPC_URL:            $RPC_URL"
echo "MARKET_CONFIG_JSON: $MARKET_CONFIG_JSON"
echo "GLOBAL_CONFIG_JSON: ${GLOBAL_CONFIG_JSON:-<auto-resolve from market config network.name>}"
echo "chainId:            $CHAIN_ID"
echo "verify:             ${VERIFY:-0}${VERIFY:+ ($VERIFIER_URL)}"
echo "skip-sim:           ${SKIP_SIMULATION:-1}"
echo "broadcast:          ${BROADCAST:-0}"
echo

forge script script/DeployFirstMarket.s.sol:DeployFirstMarket \
    --sig "${PHASE}(string,string)" "$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    $BROADCAST_ARG \
    $SKIP_SIM_ARG \
    ${VERIFY_ARGS[@]+"${VERIFY_ARGS[@]}"} \
    -vvvv
