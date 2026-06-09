// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";

/// @title IEXGate
/// @notice Interface for modular gating hooks on EXManager deposit and withdrawal operations
/// @dev Gates are called by EXManager AFTER all core logic completes (minting, burning, transfers,
///      queue routing). This ordering ensures that even if reentrancy guards are removed, external
///      calls to gates cannot manipulate in-progress state. A gate MUST revert to reject an
///      operation, which rolls back the entire transaction. Returning normally indicates approval.
///      Gates receive full context about the completed operation to enable flexible access control
///      policies without re-deriving values.
///
/// @dev Example use cases:
///      - Token-gated minting (e.g., require sKNTQ balance for exLST mints — see TieredMintGate)
///      - Whitelist enforcement via EIP712 signatures or merkle proofs (see WhitelistGate)
///      - Phase-routed gating (different gate per market phase — see MultiplexerGate)
///      - Composing multiple gates as a single hook (see CompositeGate)
///
/// @dev The `data` parameter enables extensibility without interface changes:
///      - Pass EIP712 signatures for whitelist verification
///      - Pass merkle proofs for allowlist membership
///      - Pass arbitrary gate-specific parameters
///      - Empty bytes when no per-call data is required
///
/// @dev Security considerations:
///      - Gates MUST gate `onDeposit` / `onWithdraw` to a single authorized caller (the EXManager
///        they were configured for). Reference implementations enforce this with an
///        `authorizedCaller` immutable/state field checked at the top of each hook.
///      - Gates SHOULD NOT trust user-supplied `data` without validation
interface IEXGate {
    // ═══════════════════════════════════════════════════════════════════════
    //                              DEPOSIT HOOK
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Hook called by EXManager after a deposit completes
    /// @dev Called AFTER all core deposit logic completes: HYPE staked to the per-market
    ///      exStakingManager, ghost LST minted to EXManager, exLST shares calculated
    ///      pro-rata against ghost reserves, and exLST minted to `recipient`. The gate
    ///      receives full context about the completed deposit to make access decisions.
    ///      MUST revert to reject the deposit (rolls back the entire transaction).
    ///
    /// @dev Common gate implementations:
    ///      - TieredMintGate: Per-tier mint caps gated by locked sKNTQ balance
    ///      - WhitelistGate: Decode `data` as EIP712SignedData, verify signature
    ///      - MultiplexerGate: Route to a phase-specific child gate
    ///      - CompositeGate: AND-compose multiple child gates
    ///
    /// @param exPhase Current phase of the EXManager. EXManager rejects deposits outside
    ///        FUNDING / LAUNCHING / LIVE before reaching the gate, so gates see only
    ///        these three phases:
    ///        - FUNDING: HYPE staked directly to exStakingManager → ghost LST reserves
    ///          accumulate; exLST minted pro-rata. Common gating target for whitelists.
    ///        - LAUNCHING: Same staking flow as FUNDING; brief wallet-sig handoff window.
    ///        - LIVE: Fully operational HIP-3 market; primary gating target for production
    ///          policies (mint caps, sKNTQ-locked tiers, etc.).
    ///
    /// @param sender The address initiating the deposit (msg.sender in EXManager)
    ///        May differ from recipient in delegated deposit scenarios
    ///
    /// @param recipient The address receiving the minted exLST shares
    ///        Gates typically enforce caps per-recipient, not per-sender
    ///
    /// @param tokenIn The token being deposited. Always HYPE in current EXManager
    ///        (FR-7 removed kHYPE deposits — HYPE is staked directly to exStakingManager).
    ///        Kept as a parameter for forward-compat with future deposit token paths.
    ///
    /// @param amountIn The amount of tokenIn being deposited (== msg.value)
    ///        Useful for gates that want to enforce deposit size limits
    ///
    /// @param sharesOut The exLST shares minted to recipient
    ///        Gates enforcing mint caps should track cumulative sharesOut per recipient
    ///
    /// @param data Extensible payload for gate-specific parameters
    ///        Common encodings:
    ///        - abi.encode(IEIP712Verifier.EIP712SignedData) for whitelist signatures
    ///        - abi.encode(bytes32[] proof, uint256 allowance) for merkle proofs
    ///        - Empty bytes for gates that don't need additional data
    function onDeposit(
        IEXManager.EXPhase exPhase,
        address sender,
        address recipient,
        address tokenIn,
        uint256 amountIn,
        uint256 sharesOut,
        bytes memory data
    ) external;

    // ═══════════════════════════════════════════════════════════════════════
    //                             WITHDRAWAL HOOK
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Hook called by EXManager after a withdrawal completes
    /// @dev Called AFTER all core withdrawal logic completes: requested shares pulled in,
    ///      available portion routed to a per-market staking-manager queue, blocked portion
    ///      (if any) routed to BlockedWithdrawalQueue, and the LIVE-phase minHypeStake
    ///      invariant re-checked. The gate receives full context about the routed outcome.
    ///      MUST revert to reject the withdrawal (rolls back the entire transaction).
    ///
    /// @dev Withdrawal flow context:
    ///      1. User calls `EXManager.withdraw(shares, recipient, data)` with N total shares
    ///      2. EXManager pulls `shares` exLST in for the burn, then computes the portion
    ///         the per-market reserves can immediately satisfy
    ///      3. `sharesWithdrawn` are queued on the per-market staking manager (subject to
    ///         that manager's withdrawal delay before user can confirm)
    ///      4. `blockedShares` (= shares - sharesWithdrawn) routed to BlockedWithdrawalQueue
    ///         when LIVE/WOUND_DOWN reserves are insufficient
    ///      5. LIVE-phase `minHypeStake` invariant re-checked
    ///      6. Gate hook called with the full breakdown
    ///
    /// @dev Common gate implementations:
    ///      - Most gates: No withdrawal restrictions (return immediately)
    ///      - LockGate: Enforce holding period before withdrawal allowed
    ///      - CooldownGate: Require minimum time between withdrawals
    ///
    /// @param exPhase Current phase of the EXManager. EXManager rejects withdrawals outside
    ///        FUNDING / LIVE / WOUND_DOWN before reaching the gate, so gates see only
    ///        these three phases:
    ///        - FUNDING: Pre-launch refunds; reserves typically suffice (no blocked portion).
    ///        - LIVE: Normal withdrawals; may have blocked portion when reserves dip below
    ///          tier minHypeStake; minimumWithdrawWhenLive floor enforced by EXManager.
    ///        - WOUND_DOWN: Exit withdrawals; minHypeStake invariant relaxed.
    ///
    /// @param sender The address initiating the withdrawal (msg.sender in EXManager)
    ///
    /// @param recipient The address receiving the withdrawn HYPE
    ///        May differ from sender; gates should validate recipient if needed
    ///
    /// @param tokenOut The token being withdrawn. Always HYPE in current EXManager
    ///        (FR-7 standardized HYPE-only flows). Kept as a parameter for forward-compat.
    ///
    /// @param amountOut The HYPE amount queued for `recipient` (post-fee), pending confirmation
    ///        on the per-market staking manager. Excludes any blocked portion which awaits
    ///        BlockedWithdrawalQueue processing.
    ///
    /// @param withdrawalFee The fee amount in HYPE taken by the protocol on this withdrawal
    ///
    /// @param sharesWithdrawn The exLST shares routed to the per-market staking manager queue
    ///        Burned by EXManager; recipient confirms after the staking manager's delay.
    ///
    /// @param blockedShares The exLST shares routed to BlockedWithdrawalQueue
    ///        Set when LIVE/WOUND_DOWN reserves can't cover the full request.
    ///        Recipient must wait for reserves to replenish before BWQ batch processing.
    ///        Invariant: sharesWithdrawn + blockedShares == shares argument to withdraw()
    ///
    /// @param data Extensible payload for gate-specific parameters
    ///        Less commonly used for withdrawals than deposits
    ///        Could encode unlock proofs or gate-specific attestations
    function onWithdraw(
        IEXManager.EXPhase exPhase,
        address sender,
        address recipient,
        address tokenOut,
        uint256 amountOut,
        uint256 withdrawalFee,
        uint256 sharesWithdrawn,
        uint256 blockedShares,
        bytes memory data
    ) external;
}

