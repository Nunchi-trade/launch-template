# Kinetiq Launch Template

Foundry scripts for deploying HIP-3 perp markets on Hyperliquid via the Kinetiq Launch protocol.

For a reference of the protocol these scripts interact with, see [`SPECIFICATION.md`](./SPECIFICATION.md).

For deployer onboarding — configuration field reference, operator lifecycle calls, and Kinetiq-managed enclave + sub deployer scope — see [`WALKTHROUGH.md`](./WALKTHROUGH.md).

## Configure your market

1. Copy `TEMPLATE.json` to your own per-market file (e.g. `my-market.json`) — that's what `$MARKET_CONFIG_JSON` will point at. See `script/config/example-{mainnet,mainnet-dryrun,testnet}.json` for filled-in examples.
2. Set `network.name` to one of: `mainnet`, `testnet`, `mainnet-dryrun`. The deploy script auto-resolves the matching `script/config/globals/<network>.json` and asserts your declared `chainId` lines up with the RPC.
3. Fill in `evm.marketParams`:

   | Field | What to fill | Side |
   |---|---|---|
   | `admin` | multisig that controls role transfers via the factory | EVM |
   | `operator` | receives `OPERATOR_ROLE`; drives the lifecycle (`fund` / `launch` / `setUnwindPhase` / `unwind`) | EVM |
   | `opBond` | wei, 1e10-aligned; locked for the life of the market, returned to deployer on `unwind()` finalize | EVM |
   | `validator` | L1 validator (must be in Kinetiq's approved set) | EVM ↔ HC |
   | `gate` | `IEXGate` address, or `0x0` for no gate (typical initial setup) | EVM |
   | `lstName` / `lstSymbol` | ERC20 metadata for your per-market `EXLST` shares | EVM |
   | `hyperCoreDeployer` | HC spot address that deploys (or has deployed) the HC asset paired with your `EXLST` | HC |
   | `deployerTreasury` | HC spot treasury for your fee share (must already be activated on HC) | HC |
   | `buybackBps` | basis points of post-protocol-fee remainder routed to the LST buyback loop (typical `1000` = 10%) | EVM ↔ HC |
4. Fill in `core.registerAsset` (HC perp dex registration — coin, decimals, oracle, collateral token). The deploy scripts read `collateralToken` as the activation token. See [`WALKTHROUGH.md`](./WALKTHROUGH.md#core-hypercore-configuration) for the HC-side schema.

`enclaver` + `marketTier` are pinned by Kinetiq in `script/config/globals/<network>.json` — no action needed. Optionally set `evm.cancelRecipient` if you want a pre-bond `cancelMarket` refund to land somewhere other than the deploy EOA. Full per-field detail in [`WALKTHROUGH.md`](./WALKTHROUGH.md#deployment-configuration).

## Deployment

Per-market lifecycle is three on-chain phases. HyperCore must confirm the activation token bridge
between phases, so each phase is its own command. Set the env vars once per shell session, then run
the phases in order.

**Capital required on the deployer EOA:**

| Phase | Capital | Notes |
|---|---|---|
| `deployMarket` | `opBond` HYPE [EVM] | Must satisfy `globalConfig.minOperatorBond()` — see [Network parameters](#network-parameters). Sent as `msg.value`, escrowed by the factory. |
| `activateMarket` | 6 × `core.registerAsset.schema.collateralToken` (e.g. 6 USDC at 6 decimals) | Script pulls + bridges to HyperCore so the per-market contracts have HC accounts [Core after bridge]. |
| `bondMarket` | none | Factory forwards escrowed `opBond` into the per-market reserve, mints `EXLST` 1:1 to the deployer, transitions to FUNDING [EVM]. |

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

## Network parameters

`globalConfig` floors and delays the deploy + post-bond flows depend on, per network:

| Param | mainnet | dryrun / testnet | Binds |
|---|---|---|---|
| `minOperatorBond` | **1000 HYPE** | 1 HYPE | `deployMarket{msg.value}` floor |
| `unwindDelay` | **7 days** | 1 day | `cancelMarket` pre-bond + `setUnwindPhase` → `unwind` finalize |
| `minLinkAgeForUnwind` | **183 days** | 1 day | LIVE-phase `unwind()` cliff (clock starts when Kinetiq attests the HC perp deploy is live) |

Live values: `cast call <GlobalConfig> <param>()(uint256)` against the address in `script/config/globals/<network>.json`.

## After `bondMarket`

The per-market suite is in FUNDING. Three actors take over — the deployer should understand each surface even if the roles are delegated to different addresses.

| Actor | Held by | Surface |
|---|---|---|
| **Admin** | deployer multisig | `EXFactory.transferOperator` / `transferAdmin` / `transferEnclaver` — meta-authority, rotates roles only (no lifecycle power) |
| **Operator** | deployer EOA or multisig | `EXManager.fund` → `launch` → `setUnwindPhase` → `unwind` |
| **Enclaver** | Kinetiq-pinned in globals | passive identifier; off-chain enclave reads `WALLET_ROLE` to authenticate HC API-wallet requests for this market |

### Operator responsibilities

The operator drives the per-market lifecycle on `EXManager`:

- **Phase transitions:**
  - `fund()` — FUNDING → LAUNCHING when reserves ≥ tier `minHypeStake` [EVM]
  - `launch(walletSignedData)` — LAUNCHING → LIVE; registers the HC API wallet via CoreWriter [EVM + Core trigger]
  - `setUnwindPhase(true)` → `unwind()` — voluntary wind-down; LIVE finalize additionally requires Kinetiq's HC attestation + the `minLinkAgeForUnwind` cliff
- **API wallet rotations.** `updateWallet(walletSignedData)` in LIVE / WOUND_DOWN, same Kinetiq-signed-payload path as `launch`.
- **Coordination with Kinetiq.** Request the `WalletData` payload from Kinetiq's enclave (off-chain, signed with `globalConfig.exWalletAdmin`) for `launch` and any future `updateWallet` rotation. On-chain submission is the operator's.

Full per-call inventory + Wallet Admin Flow detail in [`WALKTHROUGH.md`](./WALKTHROUGH.md#post-bond-operations).
