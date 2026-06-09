# Kinetiq Launch Template

Foundry scripts for deploying HIP-3 perp markets on Hyperliquid via the Kinetiq Launch protocol.

For a reference of the protocol these scripts interact with, see [`SPECIFICATION.md`](./SPECIFICATION.md).

For deployer onboarding — configuration field reference, operator lifecycle calls, and Kinetiq-managed enclave + sub deployer scope — see [`WALKTHROUGH.md`](./WALKTHROUGH.md).

## Configure your market

1. Copy `TEMPLATE.json` to your own per-market file (e.g. `my-market.json`) — that's what `$MARKET_CONFIG_JSON` will point at.
2. Set `network.name` to one of: `mainnet`, `testnet`, `mainnet-dryrun`. The deploy script auto-resolves the matching `script/config/globals/<network>.json` and asserts your declared `chainId` lines up with the RPC.
3. Fill in `evm.marketParams` (admin / operator / validator / opBond / lstName / lstSymbol / hyperCoreDeployer / deployerTreasury / buybackBps / gate). Per-field guidance + recommended values in [`WALKTHROUGH.md`](./WALKTHROUGH.md#deployment-configuration).
4. Fill in `core.registerAsset` (HC perp dex registration — coin, decimals, oracle, collateral token). The deploy scripts read `collateralToken` as the activation token. See [`WALKTHROUGH.md`](./WALKTHROUGH.md) for the HC-side schema.

Optionally set `evm.cancelRecipient` if you want a pre-bond `cancelMarket` refund to land somewhere other than the deploy EOA.

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

The script writes deployed marketId / exManager / bonded / cancelled flags back to `$MARKET_CONFIG_JSON` between phases — run them in order, no need to manually thread state.
