# Kinetiq Launch Template

Foundry scripts for deploying HIP-3 perp markets on Hyperliquid via the Kinetiq Launch protocol.

For a reference of the protocol these scripts interact with, see [`SPECIFICATION.md`](./SPECIFICATION.md).

For deployer onboarding — configuration field reference, operator lifecycle calls, and Kinetiq-managed enclave + sub deployer scope — see [`WALKTHROUGH.md`](./WALKTHROUGH.md).

## Configure your market

1. Copy `TEMPLATE.json` to your own per-market file (e.g. `my-market.json`) — that's what `$MARKET_CONFIG_JSON` will point at. See `script/config/example-{testnet,mainnet-dryrun}.json` for filled-in examples.
2. Set `network.name` to one of: `mainnet`, `testnet`, `mainnet-dryrun`. The deploy script auto-resolves the matching `script/config/globals/<network>.json` and asserts your declared `chainId` lines up with the RPC.
3. Fill in `evm.marketParams`:
   - `admin` — multisig that controls operator/admin/enclaver role transfers via the factory
   - `operator` — receives `OPERATOR_ROLE`; drives the lifecycle (`fund`/`launch`/`unwind`/tier upgrades)
   - `opBond` — wei (1e10-aligned); locked for the life of the market, returned to the deployer EOA when wind-down is finalized via `unwind()`
   - `validator` — your chosen L1 validator (must be active in Kinetiq's approved set)
   - `gate` — `IEXGate` contract address, or `0x0` for no gate (the typical initial market setup)
   - `lstName` / `lstSymbol` — ERC20 metadata for your per-market `EXLST` shares
   - `hyperCoreDeployer` — HC spot address responsible for deploying (or having deployed) the HC asset paired with your `EXLST` EVM contract
   - `deployerTreasury` — your HC spot treasury for the deployer fee share (must already be activated on HC)
   - `buybackBps` — basis points of the post-protocol-fee remainder routed to the LST buyback loop (typical `1000` = 10%)
4. Fill in `core.registerAsset` (HC perp dex registration — coin, decimals, oracle, collateral token). The deploy scripts read `collateralToken` as the activation token. See [`WALKTHROUGH.md`](./WALKTHROUGH.md#core-hypercore-configuration) for the HC-side schema.

`enclaver` + `marketTier` are pinned by Kinetiq in `script/config/globals/<network>.json` — no action needed. Optionally set `evm.cancelRecipient` if you want a pre-bond `cancelMarket` refund to land somewhere other than the deploy EOA. Full per-field detail in [`WALKTHROUGH.md`](./WALKTHROUGH.md#deployment-configuration).

## Deployment

Per-market lifecycle is three on-chain phases. HyperCore must confirm the activation token bridge
between phases, so each phase is its own command. Set the env vars once per shell session, then run
the phases in order.

**Capital required on the deployer EOA (per phase):**
- `deployMarket` — `opBond` HYPE (whatever you set in `evm.marketParams.opBond`), sent as `msg.value` and escrowed by the factory.
- `activateMarket` — 6 of your `core.registerAsset.schema.collateralToken` token (e.g. 6 USDC at 6 decimals). The script pulls + bridges this to HyperCore so the per-market contracts have HC accounts.
- `bondMarket` — no additional capital. The factory forwards the escrowed `opBond` into the per-market reserve, mints `EXLST` shares 1:1 to the deployer, and transitions the market to FUNDING (depositors can now stake).

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
