// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";
import {IGlobalConfig} from "@kinetiq/launch/src/interfaces/IGlobalConfig.sol";
import {IProtocolRolesController} from "@kinetiq/launch/src/interfaces/IProtocolRolesController.sol";
import {ILSTSelectors} from "@kinetiq/launch/src/interfaces/ILSTSelectors.sol";

import {IRewardShareTracker} from "@kinetiq/lst/src/interfaces/IRewardShareTracker.sol";
import {IStakingManager} from "@kinetiq/lst/src/interfaces/IStakingManager.sol";
import {IValidatorManager} from "@kinetiq/lst/src/interfaces/IValidatorManager.sol";

import {DeployFirstMarket} from "./DeployFirstMarket.s.sol";
import {UserFlow} from "./UserFlow.s.sol";
import {DeployHelpers} from "./lib/DeployHelpers.sol";

/// @title LifecycleRehearsal
/// @notice Fork-based rehearsal of the per-market lifecycle against the live-deployed
///         protocol singletons. Inherits both `DeployFirstMarket` and `UserFlow` and calls
///         their existing entrypoints sequentially under a `vm.createFork` boundary. Each
///         inherited entrypoint brackets its own `vm.startBroadcast`/`vm.stopBroadcast` pair,
///         so each public `run*` entrypoint produces **multiple transactions** against the
///         fork (one per phase), all sequenced against the same fork state. **No mainnet
///         contact** — invoke without `--broadcast` so the fork's tx record stays local.
///
/// @dev    Two independently-invokable entrypoints:
///           - `runE2E(marketConfigPath, globalConfigPath)` — full success lifecycle
///             (deployMarket → activateMarket → bondMarket → processL1Operations →
///             deposit #1 (pre-reward 1:1) → withdraw #1 → oracle update (rate appreciates)
///             → deposit #2 (post-reward) → withdraw #2 → vm.warp(36h) → processL1Operations
///             → vm.warp(7d+1) → simulate Router arrival → confirmWithdraw ×2 → simulate
///             rewardShare arrival → completeRewardDistribution).
///           - `runCancel(marketConfigPath, globalConfigPath)` — pre-bond exit
///             (deployMarket → vm.warp(cancelEligibleAt+1) → cancelMarket).
///
/// @dev    The inherited deploy entrypoints write back to `.deployed.*` per their normal
///         behavior. Since rehearsal addresses are fork-only, each public `run*` entrypoint
///         **snapshots `.deployed.*` at entry and restores it at exit** so the marketConfig
///         file is left unchanged after a successful run. If the rehearsal reverts mid-flight
///         the restore does not fire — `git checkout $MARKET_CONFIG_JSON` to recover.
///
/// @dev    Usage (pass `""` for `globalConfigPath` to auto-resolve from `network.name`):
///         export RPC_URL=https://rpc.hyperliquid.xyz/evm
///         export MARKET_CONFIG_JSON=script/config/example-mainnet.json
///         export SENDER=0xYourProductionDeployer
///         ./script/deployment/lifecycle-rehearsal.sh e2e
///         ./script/deployment/lifecycle-rehearsal.sh cancel
contract LifecycleRehearsal is DeployFirstMarket, UserFlow, StdCheats {
    using stdJson for string;
    using DeployHelpers for string;

    /// @notice 0.0001 HYPE synthetic cumulative reward — small enough to be obviously synthetic,
    ///         large enough that the 90/10 split lands on clean wei boundaries (90% = 9e13,
    ///         10% = 1e13). Static across networks; the contracts don't validate this against
    ///         HC reality.
    uint256 internal constant SYNTHETIC_REWARD_18DEC = 1e14;

    /// @notice Withdraw fraction of the deposit during the rehearsal (1/5 = 20%). Leaves
    ///         enough exLST in the depositor's balance to satisfy the withdraw pre-flight
    ///         (`exLST.balanceOf(msg.sender) >= sharesIn`) while still exercising the
    ///         partial-withdraw path.
    uint256 internal constant WITHDRAW_DIVISOR = 5;

    /// @notice HYPE buffer above (opBond + 2× depositAmount) made available to the deployer
    ///         for gas. Only `vm.deal`'d if the current balance is short.
    uint256 internal constant HYPE_GAS_BUFFER = 10 ether;

    /// @notice Activation token over-provision: 1000 units in the token's EVM decimals.
    ///         The factory's activation floor is ~6 units (3 contracts × ~2 each); 1000
    ///         is comfortably over.
    uint256 internal constant ACTIVATION_TOKEN_OVERPROVISION_UNITS = 1000;

    struct DeployedSnapshot {
        bytes32 marketId;
        address exManager;
        bool bonded;
        bool cancelled;
    }

    /* ========== PUBLIC ENTRYPOINTS ========== */

    /// @notice Full E2E success-flow rehearsal. See contract NatSpec for the call sequence.
    function runE2E(string memory marketConfigPath, string memory globalConfigPath) external {
        _createFork();
        DeployedSnapshot memory snap = _snapshotDeployed(marketConfigPath);

        (string memory marketConfig, string memory globalConfig,) =
            DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        DeployHelpers.labelDeployed(globalConfig);

        // Deposit + withdraw amounts are network-derived: deposit exactly the live
        // `globalConfig.minStakeAmount()` (the floor), withdraw a clean fraction. Reading
        // from the proxy ensures we always match the live network state.
        IGlobalConfig gc = IGlobalConfig(globalConfig.readDeployedAddress("GlobalConfig"));
        uint256 depositAmount = gc.minStakeAmount();
        uint256 withdrawShares = depositAmount / WITHDRAW_DIVISOR;
        require(depositAmount > 0, "rehearsal: globalConfig.minStakeAmount() == 0");
        require(withdrawShares > 0, "rehearsal: withdrawShares underflowed (minStake too small)");

        _provisionForkBalances(
            marketConfigPath,
            globalConfigPath,
            depositAmount,
            /*needsActivationToken*/
            true
        );

        console.log("=== [E2E.1] deployMarket ===");
        deployMarket(marketConfigPath, globalConfigPath);

        console.log("=== [E2E.2] activateMarket ===");
        activateMarket(marketConfigPath, globalConfigPath);

        console.log("=== [E2E.3] bondMarket ===");
        bondMarket(marketConfigPath, globalConfigPath);

        console.log("=== [E2E.4] processL1Operations ===");
        _processL1Ops(marketConfigPath, globalConfigPath);

        console.log("=== [E2E.5] deposit #1 (minStakeAmount) ===");
        console.log("  depositAmount (HYPE wei):", depositAmount);
        deposit(marketConfigPath, globalConfigPath, depositAmount, address(0), "");

        console.log("=== [E2E.6] withdraw #1 (1/N of deposit) ===");
        console.log("  withdrawShares (exLST wei):", withdrawShares);
        withdraw(marketConfigPath, globalConfigPath, withdrawShares, address(0), type(uint256).max, "");

        console.log("=== [E2E.7] oracle update (DefaultOracle + OracleManager via PRC) ===");
        // NOTE: operator-bot cadence is 24h between oracle updates (per OracleManager runbook),
        // even though MIN_UPDATE_INTERVAL is 1h. The rehearsal does only one update.
        _doOracleUpdate(marketConfigPath, globalConfigPath, SYNTHETIC_REWARD_18DEC);

        // ---- Post-reward deposit + withdraw — same call shape, appreciated rate. The
        // inherited deposit/withdraw assert `sharesOut == EXRouter.hypeToExLst(...)` against
        // the live rate; calling them again re-runs the assertion at the post-reward rate.
        console.log("=== [E2E.8] deposit #2 (post-reward rate; sharesOut < depositAmount) ===");
        deposit(marketConfigPath, globalConfigPath, depositAmount, address(0), "");

        console.log("=== [E2E.9] withdraw #2 (post-reward rate; amountOut > withdrawShares) ===");
        withdraw(marketConfigPath, globalConfigPath, withdrawShares, address(0), type(uint256).max, "");

        console.log("=== [E2E.10] vm.warp(36h) - simulate operator's processL1Operations cadence ===");
        vm.warp(block.timestamp + 36 hours);

        console.log("=== [E2E.11] processL1Ops (flush both user withdraws + rewardShare extraction) ===");
        _processL1Ops(marketConfigPath, globalConfigPath);

        console.log("=== [E2E.12] vm.warp(7d+1) - elapses withdrawalDelay AND REWARD_DISTRIBUTION_DELAY ===");
        // Earliest user withdraw (E2E.6) is 36h + 7d + 1 ≈ 8.5d old; second (E2E.9) is
        // similarly old (both queued before E2E.10's warp). Both clear the 7d
        // withdrawalDelay. RewardShare distribution maturity (REWARD_DISTRIBUTION_DELAY = 7d)
        // also clears since E2E.7.
        vm.warp(block.timestamp + 7 days + 1);

        // Simulate the user's HC unbond HYPE arriving back at the Router via L1→EVM bridge.
        // Sums hypeAmount across BOTH pending user withdrawals (smid=0 + smid=1).
        _simulateUserWithdrawArrival(marketConfigPath, globalConfigPath);

        console.log("=== [E2E.13] confirmWithdraw #1 (pre-reward; per-user id=1, smid=0) ===");
        confirmWithdraw(marketConfigPath, globalConfigPath, 1, address(0));

        console.log("=== [E2E.14] confirmWithdraw #2 (post-reward; per-user id=2, smid=1) ===");
        confirmWithdraw(marketConfigPath, globalConfigPath, 2, address(0));

        console.log("=== [E2E.15] completeRewardDistribution (reward share side) ===");
        // Simulate the rewardShare HC unbond HYPE arrival, then drain via PRC.execute.
        _simulateRewardShareArrival(marketConfigPath, globalConfigPath, SYNTHETIC_REWARD_18DEC / 10);
        _doCompleteRewardDistribution(marketConfigPath, globalConfigPath);

        _logRehearsalDeployed(marketConfigPath);
        _restoreDeployed(marketConfigPath, snap);

        console.log("=== E2E rehearsal passed ===");
    }

    /// @notice Cancel-only flow: deployMarket → wait `unwindDelay` → cancelMarket.
    function runCancel(string memory marketConfigPath, string memory globalConfigPath) external {
        _createFork();
        DeployedSnapshot memory snap = _snapshotDeployed(marketConfigPath);

        _provisionForkBalances(
            marketConfigPath,
            globalConfigPath,
            0,
            /*needsActivationToken*/
            false
        );

        console.log("=== [CANCEL.1] deployMarket ===");
        deployMarket(marketConfigPath, globalConfigPath);

        console.log("=== [CANCEL.2] vm.warp to cancelEligibleAt + cancelMarket ===");
        _warpToCancelEligible(marketConfigPath, globalConfigPath);
        cancelMarket(marketConfigPath, globalConfigPath);

        _logRehearsalDeployed(marketConfigPath);
        _restoreDeployed(marketConfigPath, snap);

        console.log("=== Cancel rehearsal passed ===");
    }

    /* ========== FORK SETUP ========== */

    /// @notice Create + select a fork off the RPC env var.
    function _createFork() internal {
        string memory rpcUrl = vm.envOr("RPC_URL", string("https://rpc.hyperliquid.xyz/evm"));
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);
    }

    /* ========== SNAPSHOT + RESTORE ========== */

    /// @notice Read `marketConfig.deployed.*` so we can restore it after the rehearsal
    ///         mutates it with fork-only addresses.
    function _snapshotDeployed(string memory marketConfigPath) internal view returns (DeployedSnapshot memory s) {
        string memory marketConfig = vm.readFile(marketConfigPath);
        s.marketId = marketConfig.readBytes32(".deployed.marketId");
        s.exManager = marketConfig.readAddress(".deployed.exManager");
        s.bonded = marketConfig.readBool(".deployed.bonded");
        s.cancelled = marketConfig.readBool(".deployed.cancelled");
    }

    /// @notice Write the snapshot back to the marketConfig file, undoing the inherited
    ///         deploy entrypoints' fork-only writes.
    function _restoreDeployed(string memory marketConfigPath, DeployedSnapshot memory s) internal {
        DeployHelpers.writeJsonBytes32(marketConfigPath, ".deployed.marketId", s.marketId);
        DeployHelpers.writeJsonAddress(marketConfigPath, ".deployed.exManager", s.exManager);
        DeployHelpers.writeJsonBool(marketConfigPath, ".deployed.bonded", s.bonded);
        DeployHelpers.writeJsonBool(marketConfigPath, ".deployed.cancelled", s.cancelled);
        console.log("[restore] marketConfig .deployed.* restored to pre-rehearsal snapshot");
    }

    /// @notice Surface the rehearsal-produced (fork-only) `.deployed.*` values before restore
    ///         so they're correlatable with the `-vvvv` trace.
    function _logRehearsalDeployed(string memory marketConfigPath) internal view {
        string memory marketConfig = vm.readFile(marketConfigPath);
        console.log("[rehearsal] fork-only deployed.marketId :");
        console.logBytes32(marketConfig.readBytes32(".deployed.marketId"));
        console.log("[rehearsal] fork-only deployed.exManager:", marketConfig.readAddress(".deployed.exManager"));
        console.log("[rehearsal] fork-only deployed.bonded   :", marketConfig.readBool(".deployed.bonded"));
        console.log("[rehearsal] fork-only deployed.cancelled:", marketConfig.readBool(".deployed.cancelled"));
    }

    /* ========== BALANCE PROVISIONING ========== */

    /// @notice Check the deployer's current balances and only `vm.deal` / `deal` the gap.
    ///         On insufficient balance, emits a loud console warning before topping up so the
    ///         deployer sees that their real on-chain address would have reverted unaided.
    /// @dev    On a fork the deployer EOA inherits its real mainnet balance, so the warning
    ///         surfaces exactly when a real-balance run would have failed.
    function _provisionForkBalances(
        string memory marketConfigPath,
        string memory globalConfigPath,
        uint256 depositAmount,
        bool needsActivationToken
    ) internal {
        address deployer = msg.sender;
        (string memory marketConfig, string memory globalConfig,) =
            DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);

        // ----- HYPE -----
        IEXFactory.MarketParams memory params = _buildMarketParams(marketConfig, globalConfig);
        uint256 hypeRequired = params.opBond + (depositAmount * 2) + HYPE_GAS_BUFFER;
        uint256 hypeHave = deployer.balance;
        console.log("[provision] HYPE required (wei):", hypeRequired);
        console.log("[provision] HYPE balance  (wei):", hypeHave);
        if (hypeHave < hypeRequired) {
            _warnInsufficientBalance("HYPE", hypeRequired, hypeHave);
            vm.deal(deployer, hypeRequired);
            console.log("[provision] HYPE topped up via vm.deal to (wei):", hypeRequired);
        } else {
            console.log("[provision] HYPE balance sufficient (no top-up needed)");
        }
        require(deployer.balance >= hypeRequired, "rehearsal: HYPE provisioning failed");

        // ----- activation token (skip for cancel-only flow) -----
        if (needsActivationToken) {
            uint32 tokenId = uint32(marketConfig.readUint(".core.registerAsset.schema.collateralToken"));
            IGlobalConfig gc = IGlobalConfig(globalConfig.readDeployedAddress("GlobalConfig"));
            (,, uint8 evmDecimals, address token,,,) = gc.activationTokens(tokenId);
            uint256 tokenRequired = ACTIVATION_TOKEN_OVERPROVISION_UNITS * (10 ** evmDecimals);
            uint256 tokenHave = IERC20(token).balanceOf(deployer);
            console.log("[provision] activation token required (wei):", tokenRequired);
            console.log("[provision] activation token balance  (wei):", tokenHave);
            if (tokenHave < tokenRequired) {
                _warnInsufficientBalance("ACTIVATION TOKEN", tokenRequired, tokenHave);
                deal(token, deployer, tokenRequired);
                console.log("[provision] activation token topped up via deal to (wei):", tokenRequired);
            } else {
                console.log("[provision] activation token balance sufficient (no top-up needed)");
            }
            require(
                IERC20(token).balanceOf(deployer) >= tokenRequired, "rehearsal: activation token provisioning failed"
            );
        }
    }

    /// @notice Console warning surfaced when the rehearsal sender's real on-chain balance is
    ///         short. The fork continues via cheatcode top-up; the deployer should see this
    ///         and fund the address before broadcasting a real deploy.
    function _warnInsufficientBalance(string memory token, uint256 required, uint256 have) internal pure {
        console.log("[warn] insufficient", token, "balance for rehearsal");
        console.log("       short by (wei):", required - have);
        console.log("       continuing via cheatcode top-up; a real broadcast would revert.");
    }

    /* ========== L1 OPS FLUSH (via PRC) ========== */

    /// @notice Calls `processL1Operations(0)` on the per-market Router via `PRC.execute`,
    ///         pranked as the live PROTOCOL_OPERATOR_ROLE holder so the controller's selector
    ///         allowlist check passes.
    function _processL1Ops(string memory marketConfigPath, string memory globalConfigPath) internal {
        (, string memory globalConfig,) = DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        IProtocolRolesController prc =
            IProtocolRolesController(globalConfig.readDeployedAddress("ProtocolRolesController"));
        bytes32 mid = _readMarketId(marketConfigPath);
        bytes memory call = abi.encodeCall(ILSTSelectors.processL1Operations, (0));
        _executeAsOperator(prc, mid, uint8(IProtocolRolesController.Component.Router), call);
    }

    /* ========== ORACLE UPDATE ========== */

    /// @notice Two-call ritual via PRC: `DefaultOracle.updateValidatorMetrics(...)` then
    ///         `OracleManager.generatePerformance(validator)` within the 1h staleness window.
    /// @dev    Submits a synthetic cumulative reward — the contracts don't verify against HC
    ///         reality, they just consume the operator's submission. KIP-2 90/10 split lands
    ///         in `ValidatorManager.totalRewards` (90% net) +
    ///         `RewardShareTracker.validatorRewardShareDiverted` (10%) + queues a pending
    ///         distribution on RewardShareTracker.
    function _doOracleUpdate(string memory marketConfigPath, string memory globalConfigPath, uint256 syntheticReward)
        internal
    {
        (, string memory globalConfig,) = DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        IProtocolRolesController prc =
            IProtocolRolesController(globalConfig.readDeployedAddress("ProtocolRolesController"));
        bytes32 mid = _readMarketId(marketConfigPath);
        IEXFactory.MarketContracts memory mc = prc.factory().getMarketContracts(mid);
        // The validator we delegated to lives on ValidatorManager. Read via getDelegation(router).
        address validator = IValidatorManager(mc.validatorManager).getDelegation(mc.router);

        // Balance in 18-dec: read HC delegations (8-dec) × 1e10. For the rehearsal we use the
        // Router's totalStaked (18-dec) as a proxy since on a fork the HC delegation is 0 until
        // processL1Operations runs against the real HC (which doesn't happen here). totalStaked
        // is the EVM-side view of what the Router believes is delegated — close enough for
        // sanity checks that exercise the oracle path.
        uint256 balance18 = IStakingManager(mc.router).totalStaked();

        // --- Call 1: DefaultOracle.updateValidatorMetrics ---
        bytes memory call1 = abi.encodeCall(
            ILSTSelectors.updateValidatorMetrics,
            (validator, balance18, 10_000, /* perfScore 100% BPS */ syntheticReward, 0, /* slashing */ block.number)
        );
        _executeAsOperator(prc, mid, uint8(IProtocolRolesController.Component.DefaultOracle), call1);

        // --- Snapshot before generatePerformance for split asserts ---
        uint256 totalRewardsBefore = IValidatorManager(mc.validatorManager).totalRewards();
        uint256 divertedBefore = IRewardShareTracker(mc.rewardShareTracker).validatorRewardShareDiverted(validator);
        uint256 pendingBefore = IRewardShareTracker(mc.rewardShareTracker).getPendingDistributionCount();

        // --- Call 2: OracleManager.generatePerformance ---
        bytes memory call2 = abi.encodeCall(ILSTSelectors.generatePerformance, (validator));
        _executeAsOperator(prc, mid, uint8(IProtocolRolesController.Component.OracleManager), call2);

        // --- Verify KIP-2 90/10 split landed ---
        uint256 expectedNet = (syntheticReward * 9000) / 10_000;
        uint256 expectedShare = syntheticReward - expectedNet; // residual = 10% (handles rounding cleanly)
        require(
            IValidatorManager(mc.validatorManager).totalRewards() == totalRewardsBefore + expectedNet,
            "rehearsal: ValidatorManager.totalRewards delta != 90% of synthetic reward"
        );
        require(
            IRewardShareTracker(mc.rewardShareTracker).validatorRewardShareDiverted(validator)
                == divertedBefore + expectedShare,
            "rehearsal: RewardShareTracker.validatorRewardShareDiverted delta != 10% of synthetic reward"
        );
        require(
            IRewardShareTracker(mc.rewardShareTracker).getPendingDistributionCount() == pendingBefore + 1,
            "rehearsal: RewardShareTracker pending distribution count didn't advance by 1"
        );
        console.log("[oracle] gross reward:    ", syntheticReward);
        console.log("[oracle] net (90%):       ", expectedNet);
        console.log("[oracle] rewardShare(10%):", expectedShare);
        console.log("[oracle] verify PASSED");
    }

    /* ========== USER WITHDRAW HYPE ARRIVAL ========== */

    /// @notice vm.deal the Router with the sum of all pending user-withdrawal `hypeAmount`s
    ///         to simulate the L1 unbond → bridge → EVM credit. The actual bridge credit
    ///         doesn't happen on a fork (CoreWriter calls are `vm.etch`'d stubs, no real
    ///         HC-side undelegation), so without this the Router has no HYPE and
    ///         `confirmWithdraw` reverts with `InsufficientNativeBalance`.
    /// @dev    Loops over all `WithdrawalRequest` entries from `smid=0` up to
    ///         `nextWithdrawalId[exMgr]`. Already-confirmed withdrawals have `hypeAmount = 0`
    ///         (cleared on confirm) so they're skipped naturally.
    function _simulateUserWithdrawArrival(string memory marketConfigPath, string memory globalConfigPath) internal {
        bytes32 mid = _readMarketId(marketConfigPath);
        (, string memory globalConfig,) = DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
        IEXFactory.MarketContracts memory mc = f.getMarketContracts(mid);
        IStakingManager router = IStakingManager(mc.router);
        uint256 nextSmid = router.nextWithdrawalId(mc.exManager);
        uint256 totalHype = 0;
        for (uint256 smid = 0; smid < nextSmid; smid++) {
            IStakingManager.WithdrawalRequest memory wr = router.withdrawalRequests(mc.exManager, smid);
            if (wr.hypeAmount > 0) {
                totalHype += wr.hypeAmount;
            }
        }
        require(totalHype > 0, "rehearsal: no pending user WithdrawalRequests to simulate");
        vm.deal(mc.router, mc.router.balance + totalHype);
        console.log("[simulateUserWithdrawArrival] HYPE dealt to Router (sum across pending smids):", totalHype);
    }

    /* ========== REWARD SHARE COMPLETION ========== */

    /// @notice Deposits HYPE into the Router to simulate the L1 unbond bridge credit.
    ///         `RewardShareFacet.completeRewardDistribution` requires
    ///         `address(this).balance >= amount` (the Router holds the HYPE before forwarding
    ///         to RewardShareTracker).
    function _simulateRewardShareArrival(string memory marketConfigPath, string memory globalConfigPath, uint256 amount)
        internal
    {
        bytes32 mid = _readMarketId(marketConfigPath);
        (, string memory globalConfig,) = DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
        IEXFactory.MarketContracts memory mc = f.getMarketContracts(mid);
        vm.deal(mc.router, mc.router.balance + amount);
    }

    /// @notice Calls `Router.completeRewardDistribution()` via `PRC.execute`. RewardShareFacet
    ///         queries the first matured distribution, transfers `rewardShare` HYPE to the
    ///         RewardShareTracker (which then splits 70/30 deployer/treasury).
    function _doCompleteRewardDistribution(string memory marketConfigPath, string memory globalConfigPath) internal {
        (, string memory globalConfig,) = DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        IProtocolRolesController prc =
            IProtocolRolesController(globalConfig.readDeployedAddress("ProtocolRolesController"));
        bytes32 mid = _readMarketId(marketConfigPath);
        IEXFactory.MarketContracts memory mc = prc.factory().getMarketContracts(mid);
        IRewardShareTracker rst = IRewardShareTracker(mc.rewardShareTracker);

        // Snapshot before for split asserts.
        (IRewardShareTracker.PendingRewardDistribution memory dist,) = rst.getFirstMaturedDistribution();
        address deployerWallet = rst.deployerWallet();
        address treasuryWallet = rst.treasuryWallet();
        uint256 totalShareBefore = rst.totalRewardShareDistributed();
        uint256 deployerBalBefore = deployerWallet.balance;
        uint256 treasuryBalBefore = (treasuryWallet == deployerWallet) ? 0 : treasuryWallet.balance;

        bytes memory call = abi.encodeCall(ILSTSelectors.completeRewardDistribution, ());
        _executeAsOperator(prc, mid, uint8(IProtocolRolesController.Component.Router), call);

        // Verify: cumulative tracker, deployer/treasury balance deltas.
        require(
            rst.totalRewardShareDistributed() == totalShareBefore + dist.rewardShare,
            "rehearsal: RewardShareTracker.totalRewardShareDistributed delta != rewardShare"
        );
        if (treasuryWallet == deployerWallet) {
            // Same EOA on dry-run; combined balance check.
            require(
                deployerWallet.balance == deployerBalBefore + dist.rewardShare,
                "rehearsal: deployerWallet balance delta != rewardShare (shared with treasury)"
            );
        } else {
            require(
                deployerWallet.balance == deployerBalBefore + dist.deployerAmount,
                "rehearsal: deployerWallet balance delta != deployerAmount (70%)"
            );
            require(
                treasuryWallet.balance == treasuryBalBefore + dist.treasuryAmount,
                "rehearsal: treasuryWallet balance delta != treasuryAmount (30%)"
            );
        }
        console.log("[rewardComplete] rewardShare:   ", dist.rewardShare);
        console.log("[rewardComplete] deployerAmt:   ", dist.deployerAmount);
        console.log("[rewardComplete] treasuryAmt:   ", dist.treasuryAmount);
        console.log("[rewardComplete] verify PASSED");
    }

    /* ========== CANCEL TIMER ========== */

    /// @notice Warp chain time to just past the market's `cancelEligibleAt` snapshot.
    function _warpToCancelEligible(string memory marketConfigPath, string memory globalConfigPath) internal {
        bytes32 mid = _readMarketId(marketConfigPath);
        (, string memory globalConfig,) = DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
        IEXFactory.MarketInfo memory info = f.getMarket(mid);
        if (block.timestamp < info.cancelEligibleAt + 1) {
            vm.warp(info.cancelEligibleAt + 1);
        }
    }

    /* ========== PRC.execute WRAPPER ========== */

    /// @notice Resolves the live `PROTOCOL_OPERATOR_ROLE` holder from PRC AccessControl, pranks
    ///         to that address, and forwards the call via `PRC.execute(marketId, component, calldata)`.
    function _executeAsOperator(IProtocolRolesController prc, bytes32 marketId, uint8 component, bytes memory call)
        internal
    {
        bytes32 role = prc.PROTOCOL_OPERATOR_ROLE();
        address operator = IAccessControlEnumerable(address(prc)).getRoleMember(role, 0);
        require(operator != address(0), "rehearsal: no PROTOCOL_OPERATOR_ROLE member on PRC");
        vm.startPrank(operator);
        prc.execute(marketId, component, call);
        vm.stopPrank();
    }

    /* ========== JSON HELPERS ========== */

    function _readMarketId(string memory marketConfigPath) internal view returns (bytes32) {
        return vm.readFile(marketConfigPath).readBytes32(".deployed.marketId");
    }
}
