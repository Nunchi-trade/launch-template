// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";
import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";
import {IEXRouter} from "@kinetiq/launch/src/interfaces/IEXRouter.sol";
import {IBlockedWithdrawalQueue} from "@kinetiq/launch/src/interfaces/IBlockedWithdrawalQueue.sol";

import {IStakingManager} from "@kinetiq/lst/src/interfaces/IStakingManager.sol";
import {IStakingAccountant} from "@kinetiq/lst/src/interfaces/IStakingAccountant.sol";

import {DeployHelpers} from "./lib/DeployHelpers.sol";
import {PrecompileStubs} from "./lib/PrecompileStubs.sol";

/// @title UserFlow
/// @notice Three user-facing action phases against a deployed market via EXRouter:
///         `deposit | withdraw | confirmWithdraw`. Each phase takes runtime params via
///         positional CLI args (amount/shares/withdrawalId/recipient/data). The deployed
///         market is resolved from `marketConfig.deployed.marketId` + the EXRouter / EXFactory
///         addresses pinned in the network's globalConfig.
///
/// @dev    Pattern mirrors DeployFirstMarket.s.sol: PrecompileStubs.etchAll() at every entry,
///         vm.startBroadcast/vm.stopBroadcast around the EXRouter call, console.log of broadcast
///         output. Each phase also performs **inline before/after delta verification** —
///         snapshots state pre-broadcast and asserts exact post-broadcast deltas (no separate
///         verify script). Inline is preferable here because the delta checks are tight and
///         hard to reconstruct after the fact without snapshotting.
///
/// @dev    Usage (pass `""` for `globalConfigPath` to auto-resolve from the marketConfig's
///         `network.name`):
///         forge script script/UserFlow.s.sol:UserFlow \
///           --sig 'deposit(string,string,uint256,address,bytes)' \
///           $MARKET_CONFIG_JSON "" 100000000000000000 0x0000000000000000000000000000000000000000 0x \
///           --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract UserFlow is Script {
    using stdJson for string;
    using DeployHelpers for string;

    /// @notice HyperEVM native HYPE bridge system address. The bridge truncates sub-1e10 wei,
    ///         which is why every payable entrypoint enforces `amount % 1e10 == 0`.
    address constant L1_HYPE_BRIDGE = 0x2222222222222222222222222222222222222222;

    /// @dev Arg packs let helpers take fewer stack slots — combining (recipient, amount, data)
    ///      into one memory pointer lets the via_ir Yul codegen schedule the external call
    ///      under the 16-slot stack limit.
    struct DepositArgs {
        address recipient;
        uint256 amount;
        bytes data;
    }

    struct WithdrawArgs {
        address recipient;
        uint256 sharesIn;
        uint256 maxBlockedShares;
        bytes data;
    }

    /// @dev Snapshot structs let the verify section read pre-broadcast state via a single
    ///      memory pointer instead of holding ~10 individual locals on the stack — keeps the
    ///      via_ir Yul codegen under the 16-slot stack limit.
    struct DepositSnap {
        IERC20 exLST;
        IStakingManager routerLst;
        IStakingAccountant accountant;
        IERC20 ghostLST;
        uint256 expectedShares;
        uint256 recipientSharesBefore;
        uint256 exLstTotalSupplyBefore;
        uint256 ghostExMgrBefore;
        uint256 ghostTotalSupplyBefore;
        uint256 routerTotalStakedBefore;
        uint256 accountantTotalStakedBefore;
        uint256 l1BridgeBalanceBefore;
    }

    struct WithdrawSnap {
        IERC20 exLST;
        IStakingManager routerLst;
        IERC20 ghostLST;
        IBlockedWithdrawalQueue bwq;
        uint256 availableShares;
        uint256 expectedSharesWithdrawn;
        uint256 expectedSharesToBwq;
        uint256 expectedHypeFromSharesWithdrawn;
        uint256 senderSharesBefore;
        uint256 exLstTotalSupplyBefore;
        uint256 ghostExMgrBefore;
        uint256 ghostRouterBefore;
        uint256 ghostBwqBefore;
        uint256 bwqTotalBefore;
        uint256 ghostTotalSupplyBefore;
        uint256 nextWithdrawalIdBefore;
    }

    struct ConfirmArgs {
        uint256 withdrawalId;
        address recipient;
    }

    struct WithdrawReturn {
        uint256 amountOut;
        uint256 fee;
        uint256 withdrawalId;
        uint256 blockedShares;
        uint256 blockedWithdrawalId;
    }

    struct ConfirmSnap {
        IStakingManager routerLst;
        IStakingAccountant accountant;
        IERC20 ghostLST;
        uint256 recipientHypeBefore;
        uint256 routerHypeBefore;
        uint256 ghostRouterBefore;
        uint256 ghostTotalSupplyBefore;
        uint256 routerClaimedBefore;
        uint256 accountantClaimedBefore;
    }

    /* ========== PHASE 1: deposit ========== */

    /// @notice Deposit HYPE → mint exLST shares to `recipient`.
    /// @param recipient `address(0)` resolves to msg.sender.
    /// @param data       Gate calldata. Pass `""` for NoOp gate (current dry-run markets).
    function deposit(
        string memory marketConfigPath,
        string memory globalConfigPath,
        uint256 amount,
        address recipient,
        bytes memory data
    ) public payable {
        PrecompileStubs.etchAll();
        // Scope the JSON strings + factory off the stack — only `router` and `exMgr` need to
        // live through the function body. Keeps the via_ir Yul codegen under 16 slots.
        IEXRouter router;
        IEXManager exMgr;
        {
            (string memory marketConfig, string memory globalConfig,) =
                DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
            DeployHelpers.labelDeployed(globalConfig);
            router = IEXRouter(globalConfig.readDeployedAddress("EXRouter"));
            exMgr = _getExManager(marketConfig, IEXFactory(globalConfig.readDeployedAddress("EXFactory")));
        }
        if (recipient == address(0)) recipient = msg.sender;
        _depositPreflight(exMgr, amount);

        DepositArgs memory args = DepositArgs({recipient: recipient, amount: amount, data: data});
        DepositSnap memory snap = _depositSnap(router, exMgr, args);
        uint256 sharesOut = _doDepositBroadcast(router, exMgr, args);
        _depositVerify(snap, sharesOut, args, exMgr);
    }

    /// @dev Broadcast the EXRouter.deposit{value:...} call from its own stack frame; the
    ///      `args` pointer keeps the call site to 3 stack slots so the via_ir Yul codegen
    ///      can schedule the {value:...} call's expression temporaries.
    function _doDepositBroadcast(IEXRouter router, IEXManager exMgr, DepositArgs memory args)
        internal
        returns (uint256 sharesOut)
    {
        vm.startBroadcast();
        sharesOut = router.deposit{value: args.amount}(exMgr, args.recipient, args.data);
        vm.stopBroadcast();
    }

    /// @dev Pre-broadcast intrinsic + phase + balance checks for `deposit`. Mirrors the
    ///      reverts in `EXManager.deposit` (src/EXManager.sol:553-579) so failures surface
    ///      with operator-readable messages before any tx fires.
    function _depositPreflight(IEXManager exMgr, uint256 amount) internal view {
        require(amount > 0, "userflow: amount must be > 0");
        require(amount % 1e10 == 0, "userflow: amount not 1e10-aligned (HC 8-decimal precision)");
        require(amount >= exMgr.globalConfig().minStakeAmount(), "userflow: amount < globalConfig.minStakeAmount");
        IEXManager.EXPhase phase = exMgr.exPhase();
        require(
            phase == IEXManager.EXPhase.FUNDING || phase == IEXManager.EXPhase.LAUNCHING
                || phase == IEXManager.EXPhase.LIVE,
            "userflow: market not in FUNDING/LAUNCHING/LIVE phase"
        );
        require(msg.sender.balance >= amount, "userflow: deployer HYPE balance < amount");
    }

    /// @dev Build the pre-broadcast DepositSnap into a single memory struct.
    function _depositSnap(IEXRouter router, IEXManager exMgr, DepositArgs memory args)
        internal
        view
        returns (DepositSnap memory snap)
    {
        snap.exLST = IERC20(router.exLST(exMgr));
        snap.routerLst = IStakingManager(address(exMgr.exStakingManager()));
        snap.accountant = IStakingAccountant(address(exMgr.exStakingAccountant()));
        snap.ghostLST = IERC20(_ghostLST(snap.routerLst));
        // Preview expected EXLST sharesOut via EXRouter view (matches EXManager.HYPEToEXLST).
        snap.expectedShares = router.hypeToExLst(exMgr, args.amount);
        snap.recipientSharesBefore = snap.exLST.balanceOf(args.recipient);
        snap.exLstTotalSupplyBefore = snap.exLST.totalSupply();
        snap.ghostExMgrBefore = snap.ghostLST.balanceOf(address(exMgr));
        snap.ghostTotalSupplyBefore = snap.ghostLST.totalSupply();
        snap.routerTotalStakedBefore = snap.routerLst.totalStaked();
        snap.accountantTotalStakedBefore = snap.accountant.totalStaked();
        snap.l1BridgeBalanceBefore = L1_HYPE_BRIDGE.balance;
    }

    /// @dev Inline post-broadcast verification for `deposit`. Reads pre-broadcast state via
    ///      the snapshot struct so the main function's stack stays under the via_ir limit.
    function _depositVerify(DepositSnap memory snap, uint256 sharesOut, DepositArgs memory args, IEXManager exMgr)
        internal
        view
    {
        // ---- Inline verify — exact deltas against snapshot ----
        // EXLST shares match the EXRouter preview exactly.
        require(sharesOut > 0, "verify: deposit returned 0 sharesOut");
        require(sharesOut == snap.expectedShares, "verify: sharesOut != EXRouter.hypeToExLst preview");

        // EXLST mint to recipient
        require(
            snap.exLST.balanceOf(args.recipient) == snap.recipientSharesBefore + sharesOut,
            "verify: recipient exLST balance delta != sharesOut"
        );
        require(
            snap.exLST.totalSupply() == snap.exLstTotalSupplyBefore + sharesOut,
            "verify: exLST.totalSupply delta != sharesOut"
        );

        // Ghost LST minted to EXManager (escrowed as the underlying LST representation).
        // ghostAmount = StakingAccountant.HYPEToKHYPE(amount) per StakingFacet:106.
        uint256 expectedGhost = snap.accountant.HYPEToKHYPE(args.amount);
        require(
            snap.ghostLST.balanceOf(address(exMgr)) == snap.ghostExMgrBefore + expectedGhost,
            "verify: ghostLST.balanceOf(EXManager) delta != HYPEToKHYPE(amount)"
        );
        require(
            snap.ghostLST.totalSupply() == snap.ghostTotalSupplyBefore + expectedGhost,
            "verify: ghostLST.totalSupply delta != HYPEToKHYPE(amount) (all-mint went to EXManager)"
        );

        // Router + StakingAccountant totals: both must mirror the new stake.
        require(
            snap.routerLst.totalStaked() == snap.routerTotalStakedBefore + args.amount,
            "verify: Router.totalStaked delta != amount"
        );
        require(
            snap.accountant.totalStaked() == snap.accountantTotalStakedBefore + args.amount,
            "verify: StakingAccountant.totalStaked delta != amount"
        );

        // L1 HYPE bridge received the HYPE — Router.stake forwards the staked amount via
        // `payable(L1_HYPE_BRIDGE).call{value: amount}("")` in StakingFacet:166.
        require(
            L1_HYPE_BRIDGE.balance == snap.l1BridgeBalanceBefore + args.amount,
            "verify: L1_HYPE_BRIDGE balance delta != amount"
        );

        // NOTE: Router queue length is NOT a reliable signal — `_queueL1Operation` aggregates
        // pending ops by (validator, operationType). Router.totalStaked + StakingAccountant.totalStaked
        // deltas (above) are the canonical proof.

        console.log("[deposit] amount HYPE wei:      ", args.amount);
        console.log("[deposit] recipient:            ", args.recipient);
        console.log("[deposit] sharesOut (exLST):    ", sharesOut);
        console.log("[deposit] expectedGhost (kHYPE):", expectedGhost);
        console.log("[deposit] verify PASSED");
    }

    /* ========== PHASE 2: withdraw ========== */

    /// @notice Burn exLST shares → queue HYPE withdrawal. Logs withdrawalId for the confirm phase.
    /// @param maxBlockedShares Safety cap — reverts if BWQ-routed shares > this. Use
    ///                         type(uint256).max for "accept any" (FUNDING markets don't block).
    /// @param data             Gate calldata. Pass `""` for NoOp gate (current dry-run markets).
    function withdraw(
        string memory marketConfigPath,
        string memory globalConfigPath,
        uint256 sharesIn,
        address recipient,
        uint256 maxBlockedShares,
        bytes memory data
    ) public {
        PrecompileStubs.etchAll();
        // Scope the JSON strings + factory off the stack — only `router` and `exMgr` need to
        // live through the function body. Keeps the via_ir Yul codegen under 16 slots.
        IEXRouter router;
        IEXManager exMgr;
        {
            (string memory marketConfig, string memory globalConfig,) =
                DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
            DeployHelpers.labelDeployed(globalConfig);
            router = IEXRouter(globalConfig.readDeployedAddress("EXRouter"));
            exMgr = _getExManager(marketConfig, IEXFactory(globalConfig.readDeployedAddress("EXFactory")));
        }
        if (recipient == address(0)) recipient = msg.sender;

        WithdrawArgs memory args =
            WithdrawArgs({recipient: recipient, sharesIn: sharesIn, maxBlockedShares: maxBlockedShares, data: data});
        WithdrawSnap memory snap = _withdrawPreflightAndSnap(router, exMgr, args);
        WithdrawReturn memory ret = _doWithdrawBroadcast(router, exMgr, args, snap);
        _withdrawVerify(snap, exMgr, args, ret);
    }

    /// @dev Pre-broadcast preflight + snapshot for `withdraw`. Combined into one helper to
    ///      keep `withdraw`'s main stack frame thin enough for via_ir.
    function _withdrawPreflightAndSnap(IEXRouter router, IEXManager exMgr, WithdrawArgs memory args)
        internal
        view
        returns (WithdrawSnap memory snap)
    {
        require(args.sharesIn > 0, "userflow: sharesIn must be > 0");
        require(args.recipient != address(exMgr), "userflow: recipient cannot be EXManager");

        IEXManager.EXPhase phase = exMgr.exPhase();
        require(
            phase == IEXManager.EXPhase.FUNDING || phase == IEXManager.EXPhase.LIVE
                || phase == IEXManager.EXPhase.WOUND_DOWN,
            "userflow: market not in FUNDING/LIVE/WOUND_DOWN phase"
        );

        snap.exLST = IERC20(router.exLST(exMgr));
        snap.routerLst = IStakingManager(address(exMgr.exStakingManager()));
        snap.ghostLST = IERC20(_ghostLST(snap.routerLst));
        snap.bwq = exMgr.blockedWithdrawalQueue();

        require(snap.exLST.totalSupply() > 0, "userflow: exLST.totalSupply == 0");
        require(snap.exLST.balanceOf(msg.sender) >= args.sharesIn, "userflow: msg.sender exLST balance < sharesIn");

        if (phase == IEXManager.EXPhase.LIVE) {
            require(
                args.sharesIn >= exMgr.globalConfig().minimumWithdrawWhenLive(),
                "userflow: LIVE phase shares < globalConfig.minimumWithdrawWhenLive"
            );
        }

        // Pre-flight direct vs queued split. `availableWithdrawals()` is the contract's
        // authoritative LIVE-floor cap on directly-payable exLST (mirrors
        // EXManager._queueAvailableWithdrawals).
        snap.availableShares = exMgr.availableWithdrawals();
        snap.expectedSharesWithdrawn = args.sharesIn < snap.availableShares ? args.sharesIn : snap.availableShares;
        snap.expectedSharesToBwq = args.sharesIn - snap.expectedSharesWithdrawn;
        snap.expectedHypeFromSharesWithdrawn = router.exLstToHype(exMgr, snap.expectedSharesWithdrawn);

        snap.senderSharesBefore = snap.exLST.balanceOf(msg.sender);
        snap.exLstTotalSupplyBefore = snap.exLST.totalSupply();
        snap.ghostExMgrBefore = snap.ghostLST.balanceOf(address(exMgr));
        snap.ghostRouterBefore = snap.ghostLST.balanceOf(address(snap.routerLst));
        snap.ghostBwqBefore = snap.ghostLST.balanceOf(address(snap.bwq));
        snap.bwqTotalBefore = snap.bwq.totalBlockedQueue();
        snap.ghostTotalSupplyBefore = snap.ghostLST.totalSupply();
        snap.nextWithdrawalIdBefore = exMgr.nextRecipientWithdrawalId(args.recipient);
    }

    /// @dev Broadcast the approve + EXRouter.withdraw pair from a dedicated stack frame.
    function _doWithdrawBroadcast(
        IEXRouter router,
        IEXManager exMgr,
        WithdrawArgs memory args,
        WithdrawSnap memory snap
    ) internal returns (WithdrawReturn memory ret) {
        vm.startBroadcast();
        // Approve router to pull exLST from msg.sender (Router._pay does transferFrom).
        snap.exLST.approve(address(router), args.sharesIn);
        (ret.amountOut, ret.fee, ret.withdrawalId, ret.blockedShares, ret.blockedWithdrawalId) =
            router.withdraw(exMgr, args.sharesIn, args.recipient, args.maxBlockedShares, args.data);
        vm.stopBroadcast();
    }

    /// @dev Inline post-broadcast verification for `withdraw`. Reads pre-broadcast state via
    ///      the snapshot struct so the main function's stack stays under the via_ir limit.
    function _withdrawVerify(
        WithdrawSnap memory snap,
        IEXManager exMgr,
        WithdrawArgs memory args,
        WithdrawReturn memory ret
    ) internal view {
        // ---- EXLST burn ----
        require(
            snap.exLST.balanceOf(msg.sender) == snap.senderSharesBefore - args.sharesIn,
            "verify: msg.sender exLST balance delta != -sharesIn"
        );
        require(
            snap.exLST.totalSupply() == snap.exLstTotalSupplyBefore - args.sharesIn,
            "verify: exLST.totalSupply delta != -sharesIn"
        );

        // Return-value asserts: blockedShares matches the pre-flight predict + ID consistency.
        require(
            ret.blockedShares == snap.expectedSharesToBwq,
            "verify: blockedShares != predicted (sharesIn - availableWithdrawals)"
        );
        require(
            (ret.blockedShares == 0) == (ret.blockedWithdrawalId == 0),
            "verify: blockedWithdrawalId / blockedShares inconsistency"
        );

        // HYPE-out preview match for the DIRECT portion only. amountOut is post-fee.
        require(
            ret.amountOut + ret.fee == snap.expectedHypeFromSharesWithdrawn,
            "verify: amountOut + fee != exLstToHype(sharesIn - blockedShares) (direct-portion HYPE)"
        );

        // Ghost LST escrow conservation: ALL ghost leaving EXManager splits between Router (direct)
        // and BWQ (queued). NOT burned — burn happens on confirm / processBlockedWithdrawals.
        uint256 ghostExMgrDelta = snap.ghostExMgrBefore - snap.ghostLST.balanceOf(address(exMgr));
        uint256 ghostRouterDelta = snap.ghostLST.balanceOf(address(snap.routerLst)) - snap.ghostRouterBefore;
        uint256 ghostBwqDelta = snap.ghostLST.balanceOf(address(snap.bwq)) - snap.ghostBwqBefore;
        require(ghostExMgrDelta > 0, "verify: ghostLST didn't leave EXManager");
        require(
            ghostExMgrDelta == ghostRouterDelta + ghostBwqDelta,
            "verify: ghost conservation broken (EXManager out != Router in + BWQ in)"
        );
        require(
            (ghostRouterDelta > 0) == (snap.expectedSharesWithdrawn > 0),
            "verify: Router ghost delta inconsistent with direct portion"
        );
        require(
            (ghostBwqDelta > 0) == (ret.blockedShares > 0), "verify: BWQ ghost delta inconsistent with blockedShares"
        );
        require(
            snap.bwq.totalBlockedQueue() - snap.bwqTotalBefore == ghostBwqDelta,
            "verify: BWQ.totalBlockedQueue delta != ghostBwqDelta (queue accounting drift)"
        );
        require(
            snap.ghostLST.totalSupply() == snap.ghostTotalSupplyBefore,
            "verify: ghostLST.totalSupply changed (should be unchanged on withdraw escrow)"
        );

        _withdrawVerifyRouterSlot(snap, exMgr, args, ret, ghostRouterDelta);

        console.log("[withdraw] sharesIn (exLST):            ", args.sharesIn);
        console.log("[withdraw] recipient:                   ", args.recipient);
        console.log("[withdraw] expectedSharesWithdrawn:     ", snap.expectedSharesWithdrawn);
        console.log("[withdraw] expectedSharesToBwq:         ", snap.expectedSharesToBwq);
        console.log("[withdraw] expectedHypeForWithdrawn wei:", snap.expectedHypeFromSharesWithdrawn);
        console.log("[withdraw] amountOut HYPE wei:          ", ret.amountOut);
        console.log("[withdraw] withdrawalFee:               ", ret.fee);
        console.log("[withdraw] withdrawalId:                ", ret.withdrawalId);
        console.log("[withdraw] ghostLST -> Router:          ", ghostRouterDelta);
        console.log("[withdraw] ghostLST -> BWQ:             ", ghostBwqDelta);
        console.log("[withdraw] blockedShares:               ", ret.blockedShares);
        console.log("[withdraw] blockedWithdrawalId:         ", ret.blockedWithdrawalId);
        console.log("[withdraw] verify PASSED");
    }

    /// @dev Router-side withdrawal slot verification, split out so `_withdrawVerify`'s frame
    ///      stays under via_ir's 16-slot stack limit.
    function _withdrawVerifyRouterSlot(
        WithdrawSnap memory snap,
        IEXManager exMgr,
        WithdrawArgs memory args,
        WithdrawReturn memory ret,
        uint256 ghostRouterDelta
    ) internal view {
        if (snap.expectedSharesWithdrawn > 0) {
            require(ret.withdrawalId > 0, "verify: withdrawalId is zero despite direct portion");
            require(
                ret.withdrawalId == snap.nextWithdrawalIdBefore,
                "verify: withdrawalId mismatch vs nextRecipientWithdrawalId"
            );

            IEXManager.UserWithdrawal memory uw = exMgr.userWithdrawals(args.recipient, ret.withdrawalId);
            require(address(uw.stakingManager) != address(0), "verify: userWithdrawals entry not populated");
            require(
                address(uw.stakingManager) == address(snap.routerLst),
                "verify: userWithdrawals.stakingManager != Router"
            );

            // Router-side WithdrawalRequest must be fully populated. `kHYPEAmount` equals the
            // direct ghostLST escrow.
            IStakingManager.WithdrawalRequest memory wr = snap.routerLst.withdrawalRequests(address(exMgr), uw.smid);
            require(wr.timestamp > 0, "verify: Router WithdrawalRequest not stored");
            require(wr.timestamp == block.timestamp, "verify: Router WithdrawalRequest timestamp != current block");
            require(
                wr.kHYPEAmount == ghostRouterDelta,
                "verify: Router WithdrawalRequest.kHYPEAmount != direct ghostLST escrowed"
            );
            require(wr.kHYPEFee == 0, "verify: Router WithdrawalRequest.kHYPEFee != 0 (unstakeFeeRate = 0)");
            require(wr.hypeAmount > 0, "verify: Router WithdrawalRequest.hypeAmount is zero");
        } else {
            // Pure-BWQ path — Router-side slot must not have been allocated.
            require(ret.withdrawalId == 0, "verify: withdrawalId non-zero on pure-BWQ path");
            require(ret.amountOut == 0 && ret.fee == 0, "verify: amountOut/fee non-zero on pure-BWQ path");
        }
    }

    /* ========== PHASE 3: confirmWithdraw ========== */

    /// @notice Confirm a previously-queued withdrawal. Must be after `withdrawalDelay` has elapsed
    ///         (per-market `withdrawalDelay = 7 days` set at StakingManagerRouter.initialize).
    function confirmWithdraw(
        string memory marketConfigPath,
        string memory globalConfigPath,
        uint256 withdrawalId,
        address recipient
    ) public {
        PrecompileStubs.etchAll();
        // Scope the JSON strings + factory off the stack — only `router` and `exMgr` need to
        // live through the function body. Keeps the via_ir Yul codegen under 16 slots.
        IEXRouter router;
        IEXManager exMgr;
        {
            (string memory marketConfig, string memory globalConfig,) =
                DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
            DeployHelpers.labelDeployed(globalConfig);
            router = IEXRouter(globalConfig.readDeployedAddress("EXRouter"));
            exMgr = _getExManager(marketConfig, IEXFactory(globalConfig.readDeployedAddress("EXFactory")));
        }
        if (recipient == address(0)) recipient = msg.sender;
        require(withdrawalId > 0, "userflow: withdrawalId must be > 0");

        // Pre-flight: withdrawal must be queued (stakingManager != 0)
        require(
            address(exMgr.userWithdrawals(recipient, withdrawalId).stakingManager) != address(0),
            "userflow: withdrawalId not queued (already confirmed or never existed)"
        );

        ConfirmArgs memory args = ConfirmArgs({withdrawalId: withdrawalId, recipient: recipient});
        ConfirmSnap memory snap = _confirmSnap(exMgr, args);
        (uint256 amountOut, uint256 fee) = _doConfirmBroadcast(router, exMgr, args);
        _confirmVerify(snap, exMgr, args, amountOut, fee);
    }

    /// @dev Build the pre-broadcast ConfirmSnap into a single memory struct.
    function _confirmSnap(IEXManager exMgr, ConfirmArgs memory args) internal view returns (ConfirmSnap memory snap) {
        snap.routerLst = IStakingManager(address(exMgr.exStakingManager()));
        snap.accountant = IStakingAccountant(address(exMgr.exStakingAccountant()));
        snap.ghostLST = IERC20(_ghostLST(snap.routerLst));
        snap.recipientHypeBefore = args.recipient.balance;
        snap.routerHypeBefore = address(snap.routerLst).balance;
        snap.ghostRouterBefore = snap.ghostLST.balanceOf(address(snap.routerLst));
        snap.ghostTotalSupplyBefore = snap.ghostLST.totalSupply();
        snap.routerClaimedBefore = snap.routerLst.totalClaimed();
        snap.accountantClaimedBefore = snap.accountant.totalClaimed();
    }

    /// @dev Broadcast the EXRouter.confirm call from a dedicated stack frame; args struct
    ///      reduces the call site to 3 stack slots.
    function _doConfirmBroadcast(IEXRouter router, IEXManager exMgr, ConfirmArgs memory args)
        internal
        returns (uint256 amountOut, uint256 fee)
    {
        vm.startBroadcast();
        (amountOut, fee) = router.confirm(exMgr, args.withdrawalId, args.recipient);
        vm.stopBroadcast();
    }

    /// @dev Inline post-broadcast verification for `confirmWithdraw`.
    function _confirmVerify(
        ConfirmSnap memory snap,
        IEXManager exMgr,
        ConfirmArgs memory args,
        uint256 amountOut,
        uint256 fee
    ) internal view {
        // userWithdrawals entry cleared (signals successful confirm in EXManager).
        require(
            address(exMgr.userWithdrawals(args.recipient, args.withdrawalId).stakingManager) == address(0),
            "verify: userWithdrawals entry not cleared (confirm didn't process)"
        );

        uint256 totalHype = amountOut + fee;

        // Recipient HYPE delta: upper bound exact (overpayment caught), lower bound exact when
        // recipient != msg.sender; 0.01 HYPE tolerance when recipient == msg.sender to absorb
        // worst-case self-pay gas (~200k × 50 gwei ≈ 0.01 HYPE).
        uint256 expectedRecipientBal = snap.recipientHypeBefore + amountOut;
        require(
            args.recipient.balance <= expectedRecipientBal,
            "verify: recipient HYPE balance exceeded expected (overpayment)"
        );
        uint256 selfPayGasTolerance = (args.recipient == msg.sender) ? 0.01 ether : 0;
        require(
            args.recipient.balance + selfPayGasTolerance >= expectedRecipientBal,
            "verify: recipient HYPE balance below expected (even allowing self-pay gas tolerance)"
        );

        // Router HYPE balance: dropped by totalHype (Router paid recipient + treasury).
        require(
            address(snap.routerLst).balance == snap.routerHypeBefore - totalHype,
            "verify: Router HYPE delta != -(amountOut+fee)"
        );

        // Ghost LST burn: Router burned the escrowed ghost LST.
        uint256 ghostBurned = snap.ghostRouterBefore - snap.ghostLST.balanceOf(address(snap.routerLst));
        require(ghostBurned > 0, "verify: Router didn't burn escrowed ghostLST");
        require(
            snap.ghostLST.totalSupply() == snap.ghostTotalSupplyBefore - ghostBurned,
            "verify: ghostLST.totalSupply delta != ghost burned (burn must reduce supply)"
        );

        // totalClaimed bookkeeping: Router and Accountant track the same total HYPE claimed.
        require(
            snap.routerLst.totalClaimed() == snap.routerClaimedBefore + totalHype,
            "verify: Router.totalClaimed delta != amountOut+fee"
        );
        require(
            snap.accountant.totalClaimed() == snap.accountantClaimedBefore + totalHype,
            "verify: StakingAccountant.totalClaimed delta != amountOut+fee (mirror Router)"
        );

        console.log("[confirmWithdraw] withdrawalId:         ", args.withdrawalId);
        console.log("[confirmWithdraw] recipient:            ", args.recipient);
        console.log("[confirmWithdraw] amountOut HYPE wei:   ", amountOut);
        console.log("[confirmWithdraw] withdrawalFee:        ", fee);
        console.log("[confirmWithdraw] ghostLST burned:      ", ghostBurned);
        console.log("[confirmWithdraw] verify PASSED");
    }

    /* ========== HELPERS ========== */

    /// @dev Resolves the per-market ghost LST address by reading the auto-generated `tokenAddress()`
    ///      public getter on `StakingManagerStorage` (exposed via Router's interface inheritance).
    function _ghostLST(IStakingManager routerLst) internal view returns (address) {
        (bool ok, bytes memory ret) = address(routerLst).staticcall(abi.encodeWithSignature("tokenAddress()"));
        require(ok && ret.length == 32, "userflow: Router.tokenAddress() reverted");
        return abi.decode(ret, (address));
    }

    function _getExManager(string memory marketConfig, IEXFactory f) internal view returns (IEXManager) {
        bytes32 marketId = marketConfig.readBytes32(".deployed.marketId");
        require(marketId != bytes32(0), "userflow: marketId is zero (market not deployed)");
        IEXFactory.MarketInfo memory info = f.getMarket(marketId);
        require(info.exManager != address(0), "userflow: market not registered in factory");
        return IEXManager(info.exManager);
    }
}
