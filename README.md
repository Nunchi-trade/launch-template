# Kinetiq Launch Template

Foundry scripts for deploying HIP-3 perp markets on Hyperliquid via the Kinetiq Launch protocol.

For a reference of the protocol these scripts interact with, see [`SPECIFICATION.md`](./SPECIFICATION.md).

## Deployment

Per-market lifecycle is three on-chain phases. HyperCore must confirm the activation token bridge
between phases, so each phase is its own command. Set the env vars once per shell session, then run
the phases in order.

```shell
export RPC_URL=https://...
export PRIVATE_KEY=0x...
export MARKET_CONFIG_JSON=path/to/market.json   # your filled-in copy of TEMPLATE.json

./script/deployment/deploy-first-market.sh deployMarket
./script/deployment/deploy-first-market.sh activateMarket
./script/deployment/deploy-first-market.sh bondMarket
```

A pre-bond `cancelMarket` exit is also available (time-locked):

```shell
./script/deployment/deploy-first-market.sh cancelMarket
```

Read-only verifiers — one per phase, run after the corresponding deploy step (no `PRIVATE_KEY`
needed):

```shell
./script/deployment/verify-first-market.sh verifyDeployMarket
./script/deployment/verify-first-market.sh verifyActivateMarket
./script/deployment/verify-first-market.sh verifyBondMarket
```

The shell drivers wrap `forge script` with env-var fast-fail. Configuration (market params, core
config) is read from `$MARKET_CONFIG_JSON`; per-network protocol singleton addresses + pinned
defaults come from `script/config/globals/<networkName>.json` (auto-resolved from your market
config's `network.name`, or override via `GLOBAL_CONFIG_JSON`). Deployed marketId / exManager /
bonded / cancelled flags are written back to `$MARKET_CONFIG_JSON` between phases.
