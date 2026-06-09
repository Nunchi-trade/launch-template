# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Agent Expertise

You are an expert Solidity / Foundry developer with deep knowledge of Hyperliquid
(HyperCore + HyperEVM, HIP-1 / HIP-3, CoreWriter actions, L1Read precompiles). You
write deployment scripts and deployer-facing tooling here — not protocol contracts.

## Project Overview

**Kinetiq Launch Template** is a deployer-facing repo. Foundry scripts here let a
deployer deploy and operate an HIP-3 perpetual futures market via the Kinetiq
Launch protocol in **one or two bash commands**.

The Launch protocol itself — contracts, audits, internal architecture — lives in
a separate repository. This repo contains only:

- Foundry scripts driving `EXFactory.deployMarket → activateMarket → bondMarket`
  (and `cancelMarket` as a pre-bond exit)
- Vendored interface ABIs under `src/interfaces/` so the scripts compile
- A trimmed protocol reference (`SPECIFICATION.md`) covering only what a
  deployer / market operator / exLST depositor needs to understand the contracts
  they actually call
- Deployer onboarding: `WALKTHROUGH.md` (forwarded by Kinetiq), `TEMPLATE.json`
  (deployer intake form), `README.md` (quickstart)

This repo is **not** the place for protocol implementation, audit findings,
Kinetiq-internal operational details, threat models, or anything that exposes
infrastructure a deployer doesn't directly call.

## Repo Layout

```
README.md             Quickstart — the bash commands a deployer runs
SPECIFICATION.md      Trimmed protocol reference for deployer / operator / depositor scope
WALKTHROUGH.md        Deployer onboarding doc
TEMPLATE.json         Deployer intake template (MarketParams + HC config)
script/
  DeployFirstMarket.s.sol   deployMarket / activate / bondMarket / cancelMarket entries
  VerifyFirstMarket.s.sol   Read-only post-deploy sanity checks
  lib/DeployHelpers.sol     JSON config IO + address resolution
  lib/PrecompileStubs.sol   HC precompile stubs for local / fork
  deployment/               Bash drivers wrapping forge script with env-var fast-fail
src/
  interfaces/         Vendored protocol interfaces (compile-only)
  lib/                LST interface vendor
foundry.toml, remappings.txt
```

No `test/` content — this repo is scripts + docs only.

## Build & Run

```bash
forge build --sizes      # Compile; surfaces EIP-170 drift on touched contracts
```

Run a phase via the shell drivers (recommended):

```bash
./script/deployment/deploy-first-market.sh deployMarket
./script/deployment/deploy-first-market.sh activateMarket
./script/deployment/deploy-first-market.sh bondMarket
```

Read-only verifiers — one per phase, run after the corresponding deploy step:

```bash
./script/deployment/verify-first-market.sh verifyDeployMarket
./script/deployment/verify-first-market.sh verifyActivateMarket
./script/deployment/verify-first-market.sh verifyBondMarket
```

Each phase reads `$CONFIG_JSON`, broadcasts, and writes the new addresses back
under `.markets.<label>.deployed.*` so the next phase + the verifier can pick
them up automatically.

## Script Workflow

The three-phase split exists because HyperCore must confirm the activation token
bridge between phases, and that confirmation is off-chain. Each phase is its own
forge entry; the deployer runs them sequentially with a wait between.

**Scripts must pre-flight assert before broadcasting.** Every `MarketParams` field,
the `opBond` floor, the caller's HYPE balance, activation token registration,
validator activation, and per-contract `.activated()` checks are verified locally
before `vm.startBroadcast()`. Deployers shouldn't lose gas to an avoidable revert.
If anything is malformed, `require()` out at JSON read time.

Mark internal helpers `virtual` where deployers might reasonably override (e.g.
`_buildMarketParams` is virtual so end-clients forking the script can constrain
inputs without re-templating the whole file).

## Documentation Conventions

**Scope discipline — three audiences only:**

- **Deployer** — calls `EXFactory.deployMarket` / `activateMarket` / `bondMarket` /
  `cancelMarket`; provides `MarketParams`; chooses operator + admin + enclaver.
- **Market operator** — runs lifecycle on `EXManager`: `fund`, `launch`,
  `updateWallet`, tier upgrade flow, `setUnwindPhase`, `unwind`.
- **exLST depositor / withdrawor** — deposits HYPE via `EXRouter`, withdraws
  shares, confirms withdrawals (including blocked).

Anything Kinetiq-internal — `ProtocolRolesController`, the internal LST stack
(Router / Accountant / ValidatorManager / OracleManager / RewardShareTracker /
GhostLST), fee distribution internals (`LaunchFeeSplitter` / `StakeFeesThrottle`),
beacon / facet / pauser registries, bot operations, recovery roles, audit-fix
annotations (`Z-M-*`, `H-01 closure`, etc.), runbooks, threat models — belongs
in the protocol repo, not here.

**When trimming `SPECIFICATION.md`:** keep lifecycle, gates, tier system,
contract docs for `EXFactory` / `EXManager` / `EXLST` / `EXRouter` /
`BlockedWithdrawalQueue`, the slashing-aware behavior summary, share-math
primitives, decimal alignment, fee model. Drop everything else.

**When extending `WALKTHROUGH.md` or `TEMPLATE.json`:** every field a deployer
provides must be a real input the scripts read or a real HC-side config. Don't
add Kinetiq-internal fields a deployer can't observe.

**No comments unless the WHY is non-obvious.** Default to no comments in `.sol`
and `.sh`. Add one only when there's a hidden constraint, an HC-side quirk
worth flagging, or a deliberate divergence from the protocol's defaults. Don't
narrate WHAT the code does. Don't reference PR numbers or "the recent fix" —
those rot.

## Patterns to Follow

- **Scripts default to safe.** Mirror the pre-flight pattern in
  `DeployFirstMarket._preFlightAssertsForDeploy`: every `require` either rejects
  a malformed JSON input or rejects a state the protocol will reject anyway.
- **Config writeback is automatic.** Use `DeployHelpers.writeJsonAddress` /
  `writeJsonBytes32` / `writeJsonBool` after each phase.
- **One config, many markets.** Markets are keyed by `label` under
  `.markets.<label>` so a single config file can track several markets in
  flight (e.g. `firstMarket`, `cancelTest`, `secondMarket`).
- **`virtual` for deployer extensibility.** Mark internal helpers `virtual` where
  deployers might reasonably override.
- **The value proposition is `bash` + `forge` + JSON.** Anything that requires
  a custom UI moves into Kinetiq's whitegloving scope, not this repo.

## What Not to Add

- Protocol-internal contract addresses, ABIs beyond the vendored interfaces,
  role allowlists, or selector pins
- Threat models, audit findings, trust-root analysis, compromised-key scenarios
- Test runners, test-style content, or `forge test/snapshot/coverage`
  references in user-facing docs
- Kinetiq operational runbooks (oracle reporting cadences, bot schedules,
  recovery procedures)
- References to internal Kinetiq directories (`audit/`,
  `doc/permissionless/procedures/`, etc.) — they don't exist in this repo

## Working Defaults

- When trimming docs, cut aggressively from Kinetiq-internal scope but preserve
  every deployer / operator / depositor touchpoint.
- When the user says "be conservative," prefer fewer surgical edits over broad
  rewrites. Ask before reorganizing sections.
- When the user adds new deployer-facing content (`WALKTHROUGH.md`,
  `TEMPLATE.json`, etc.), cross-check it against the actual `MarketParams`
  reader in `DeployFirstMarket.s.sol` and the script's config schema before
  assuming consistency.
- Some `MarketParams` fields (`enclaver`, `marketTier`, others) are planned to
  be pinned inside the scripts in future commits to simplify the deployer-facing
  template. When that lands, keep `WALKTHROUGH.md` / `TEMPLATE.json` in sync.
- **Commit messages stay succinct.** This repo is public-facing — keep messages
  to `type: one-line description`, with bullets only when essential. Don't
  enumerate what was removed, don't reference protocol-repo internals, don't
  describe roadmap or "future work" in commit bodies. The diff already shows
  what changed; messages describe intent, not history.
