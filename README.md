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

## Fork rehearsal (optional, recommended)

Before risking capital on a real deploy, fork-test the lifecycle against the live protocol singletons. The rehearsal creates a mainnet fork inside the script and runs either the full success path (`e2e`) or the pre-bond cancel (`cancel`) — no `--broadcast`, no on-chain effect.

Set `SENDER` to your production deployer address (the one that will eventually call `deployMarket` for real). The rehearsal reads its live balance + state from the fork; if your address already holds enough HYPE + activation token, the run is fully realistic. If not, the script logs the gap and tops up via cheatcodes. `PRIVATE_KEY` can be a throwaway dev key — the rehearsal never broadcasts. Set at least one of `SENDER` or `PRIVATE_KEY` (if only `PRIVATE_KEY` is set, msg.sender derives from it).

```shell
export RPC_URL=https://rpc.hyperliquid.xyz/evm
export MARKET_CONFIG_JSON=script/config/example-mainnet.json
export SENDER=0xYourProductionDeployer       # your real deploy address

./script/deployment/lifecycle-rehearsal.sh e2e
./script/deployment/lifecycle-rehearsal.sh cancel
```

The rehearsal snapshots `marketConfig.deployed.*` at entry and restores it at exit, so the file is unchanged after a successful run. If the rehearsal reverts mid-flight, run `git checkout $MARKET_CONFIG_JSON` to recover.

## Deployment

Per-market lifecycle is three on-chain phases. HyperCore must confirm the activation token bridge
between phases, so each phase is its own command. Set the env vars once per shell session, then run
the phases in order.

**Capital required on the deployer EOA:**

| Phase | Capital | Notes |
|---|---|---|
| `deployMarket` | `opBond` HYPE **on HyperEVM** [EVM] | Must satisfy `globalConfig.minOperatorBond()` — see [Network parameters](#network-parameters). Sent as `msg.value`, escrowed by the factory. Bridge HYPE from HyperCore spot first if your balance lives there. |
| `activateMarket` | 6 × `core.registerAsset.schema.collateralToken` **on HyperEVM** (e.g. 6 USDC at 6 decimals) | Script pulls from the deployer's HyperEVM balance and bridges per-contract shares to HyperCore so the per-market contracts have HC accounts [Core after bridge]. Bridge USDC from HyperCore spot first if needed. |
| `bondMarket` | none | Factory forwards escrowed `opBond` to be staked in the per-market reserve (earns validator delegation rewards alongside depositor stake). The 1:1 `EXLST` shares minted against the bonded stake are **escrowed in `EXManager`** as the deployer's skin-in-the-game — locked for the life of the market and swept back to the deployer only at `unwind()` finalize. Transitions to FUNDING [EVM]. |

**Before broadcasting:**

- **Enable HyperEVM big blocks** on your deployer address before `deployMarket`. The factory deploys a full per-market contract suite (~13 contracts) in one tx; HyperEVM's small-block gas limit is too low to fit it. Toggle big blocks via the Hyperliquid UI/API for the deployer address before running `deployMarket`.
- **Set `BROADCAST=1`** to actually send the transactions. The default (`BROADCAST=0`) runs as fork simulation only — **no on-chain effect**. `vm.writeJson` still mutates `$MARKET_CONFIG_JSON` either way, so point at a throwaway copy if you want the original clean.

```shell
export RPC_URL=https://...
export PRIVATE_KEY=0x...
export MARKET_CONFIG_JSON=path/to/market.json   # your filled-in copy of TEMPLATE.json
export BROADCAST=1                              # REQUIRED to actually send tx on-chain

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

## Operator flows

After `bondMarket` the market is in FUNDING. The **operator** (the address set as `operator` in `MarketParams` at deploy time, or whoever the admin most recently rotated to via `EXFactory.transferOperator`) drives the rest of the lifecycle on `EXManager` via `./script/deployment/operator-flow.sh`. Same env-var preamble as the deploy driver.

```shell
export RPC_URL=https://...
export PRIVATE_KEY=0x...                          # operator EOA (must hold OPERATOR_ROLE)
export MARKET_CONFIG_JSON=path/to/market.json
export BROADCAST=1                                # REQUIRED to send tx on-chain

# FUNDING -> LAUNCHING (once reserves >= tier minHypeStake)
./script/deployment/operator-flow.sh fund

# LAUNCHING -> LIVE (walletDataHex + walletSignatureHex come from Kinetiq's enclave)
./script/deployment/operator-flow.sh launch <walletDataHex> <walletSignatureHex>

# Queue voluntary unwind (true) or cancel a queued one (false)
./script/deployment/operator-flow.sh setUnwindPhase true
./script/deployment/operator-flow.sh setUnwindPhase false

# Finalize wind-down after unwindDelay (LIVE-phase additionally needs Kinetiq HC attestation + minLinkAgeForUnwind cliff)
./script/deployment/operator-flow.sh unwind
```

Each phase pre-flights its on-chain prerequisites (phase guard, unwind state, ghost-LST reserve floor for `fund`, payload-length sanity for `launch`) and inline-verifies post-broadcast deltas with operator-readable revert messages. Default is fork-only simulation; set `BROADCAST=1` to actually send.

## Depositor flows (testing)

The depositor surface (`./script/deployment/user-flow.sh`) is most useful as a testing tool — primarily for **bringing reserves up to the tier floor on testnet or mainnet-dryrun** so the operator can call `fund()`. Same env-var preamble as above.

```shell
export RPC_URL=https://...
export PRIVATE_KEY=0x...                          # depositor EOA (must hold the HYPE)
export MARKET_CONFIG_JSON=path/to/market.json
export BROADCAST=1

# Stake HYPE -> mint EXLST shares (amount must be >= globalConfig.minStakeAmount and 1e10-aligned)
./script/deployment/user-flow.sh deposit <amountWei> [<recipient>] [<dataHex>]

# Burn EXLST -> queue HYPE withdrawal (paid out via confirm after the protocol's withdrawalDelay)
./script/deployment/user-flow.sh withdraw <sharesWei> [<recipient>] [<maxBlockedShares>] [<dataHex>]

# Confirm a queued withdrawal -> HYPE settles to recipient
./script/deployment/user-flow.sh confirmWithdraw <withdrawalId> [<recipient>]
```

Defaults: `recipient = 0x0…0` (resolves to `msg.sender`), `dataHex = 0x` (NoOp gate — correct for example markets), `maxBlockedShares = type(uint256).max`. The per-network `globalConfig.minStakeAmount` is **0.1 HYPE** (`1e17` wei) on every network, and every payable entrypoint enforces `amount % 1e10 == 0` (HC 8-decimal bridge alignment).

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

## Deployed protocol contracts

Per-network singleton addresses for the Launch protocol's deployer-facing contracts. Implementation, facet, and beacon impl addresses are intentionally omitted — these are the contracts your scripts and contract calls interact with directly. The deploy + verify scripts pick these up automatically from `script/config/globals/<network>.json` based on the `network.name` in your market config.

### Mainnet (chainId 999)

| Contract | Address |
|---|---|
| `GlobalConfig` | `0x23CcD0f1926E4f97d9292683B45fAdBDb066AE50` |
| `PauserRegistry` | `0xC2b4350D952550ce4d2A4023a7935931fD2Bd6dA` |
| `FacetRegistry` | `0xB6509D615553DCba03D1208BC4F103109537294C` |
| `UpgradeableBeaconRegistry` | `0x804A50082A394C65672Cb6A8Bd31EBe2CEb22bA1` |
| `EXDeployer` | `0x5f06F2B0A5ABDa058A2771107b15b374E82361ea` |
| `EXFactory` | `0x188a8CFa039C049c6B076C52164E5d51ee207a98` |
| `ProtocolRolesController` | `0x9f4Ea6E461759E5D920B5e294f10870ef0949A4E` |
| `EXRouter` | `0x06629c64AAF1639A7CDE24DFe0D1E1eD3E56BF3d` |

### Mainnet-dryrun (chainId 999)

Separate deployment on the same HyperEVM mainnet chain — for testing the deploy flow against real mainnet state without touching production singletons.

| Contract | Address |
|---|---|
| `GlobalConfig` | `0x0CD8bd124CB0B610CEC8EA35311ac2FEE6167269` |
| `PauserRegistry` | `0x5609700347B35F39Ee82E23d77f71F6Bb9758168` |
| `FacetRegistry` | `0x6420589a7C7d85c0D887eE61ea0a8ad42861224A` |
| `UpgradeableBeaconRegistry` | `0x85e91F54DE98F2B7c4A59A3EC5933Ffa93C3e1bf` |
| `EXDeployer` | `0xf9176658db4259aFF43699D7d6A5FAfb300959BB` |
| `EXFactory` | `0xde9913e6A081F25b36e7ADd224D13d20FD3940B2` |
| `ProtocolRolesController` | `0xae0b43ccb16423fE16B7A9D7392Fa6a907DD28D4` |
| `EXRouter` | `0x7a5d01e345f28A6F2fb974808CA93F50a473C426` |

### Testnet (chainId 998)

| Contract | Address |
|---|---|
| `GlobalConfig` | `0xeCE7dfc7825d33B8C33BAB5CaB6B0178Aa0371a6` |
| `PauserRegistry` | `0x343B88f27bb9553000C215aE9F146ee6421B2aA0` |
| `FacetRegistry` | `0xAb9b5eaCD8bcBA443414958cDAA9d621Aa66ad64` |
| `UpgradeableBeaconRegistry` | `0x6D446056920855afCB560f42916B0f0f996fC356` |
| `EXDeployer` | `0x3B6192AF370D29c3F7baC7A12334a9BF26CA49cB` |
| `EXFactory` | `0xba9DBf3C09F50F301531Eb60440c14151632F9d5` |
| `ProtocolRolesController` | `0x9a43406488dc72b3c6b76B5462A466F8AAdb7d24` |
| `EXRouter` | `0xbE1882e3De9250e875d6ecbBf30D924f4e38036E` |
