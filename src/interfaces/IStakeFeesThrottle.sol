// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";
import {IGlobalConfig} from "@kinetiq/launch/src/interfaces/IGlobalConfig.sol";

/// @title IStakeFeesThrottle
/// @notice External surface for the per-market stake-fees throttle.
/// @dev Drips post-buyback HYPE into `EXManager.stakeFees` (operator-only `execute`) and bridges
///      Core-spot HYPE back to EVM (permissionless `sweep`). Drip rate is bounded by GlobalConfig
///      throttle config (impact bps, min interval, clearance period) capped by
///      `Constants.MAX_IMPACT_BPS` (20%). `activate(uint32, uint256)` and `activated()` live on
///      the inherited `IHyperCoreActivatable` surface — callers casting through this
///      contract-specific interface can additionally cast to `IHyperCoreActivatable` to reach those.
interface IStakeFeesThrottle {
    /// @notice Emitted on every successful `execute()` cycle that stakes EVM HYPE.
    /// @param caller The address that invoked `execute()` (OPERATOR_ROLE holder).
    /// @param stakeAmount The HYPE amount staked into `EXManager.stakeFees` after clearance/impact bounds.
    /// @param timestamp Block timestamp of the call.
    /// @param blockNumber Block number of the call.
    event Executed(address indexed caller, uint256 stakeAmount, uint256 timestamp, uint256 blockNumber);

    /// @notice Emitted on every successful `sweep()` that dispatches a spot-to-EVM bridge.
    /// @param caller The address that invoked `sweep()` (permissionless).
    /// @param amount The HC spot HYPE amount bridged (HyperCore 8-decimal units) to `L1_HYPE_BRIDGE`.
    /// @param timestamp Block timestamp of the call.
    /// @param blockNumber Block number of the call.
    event Swept(address indexed caller, uint64 amount, uint256 timestamp, uint256 blockNumber);

    /// @notice Timestamp of the most recent execution that performed a non-zero EVM-side drip.
    function lastDripTimestamp() external view returns (uint256);

    /// @notice Last block number where `execute()` was called (per-block guard).
    function lastExecutionBlock() external view returns (uint256);

    /// @notice Last block number where `sweep()` dispatched a spot bridge (per-block guard).
    function lastSweepBlock() external view returns (uint256);

    /// @notice EXManager receiving the dripped stake fees.
    function exManager() external view returns (IEXManager);

    /// @notice Global protocol configuration (throttle config + L1Read endpoint).
    function globalConfig() external view returns (IGlobalConfig);

    /// @notice HIP-1 token id used for HYPE spot-balance reads and bridge sends.
    function hypeTokenId() external view returns (uint64);

    /// @notice Whether `execute()` can run at the current block/timestamp.
    /// @dev Interval-only check (min interval elapsed since last drip). Callers should
    ///      additionally pre-flight `previewStakeAmount() >= router.minStakeAmount()` to avoid
    ///      `BelowMinimum` reverts on dust-pinned balances.
    function isReady() external view returns (bool);

    /// @notice Amount of EVM HYPE that the next `execute()` would stake under current caps.
    function previewStakeAmount() external view returns (uint256);

    /// @notice Spendable spot HYPE (total minus hold) owned by this throttle on HyperCore.
    function availableSpotHype() external view returns (uint64);

    /// @notice Dispatches a `CoreWriter.sendSpot` (action 6) bridging the throttle's full
    ///         spendable HC spot HYPE balance to the EVM bridge address. Permissionless.
    /// @dev Reverts `Errors.AlreadyExecutedThisBlock` if sweep already ran this block;
    ///      reverts `Errors.NotReady` if no spot HYPE to bridge. Bridge credit lands on the
    ///      throttle's EVM balance asynchronously and is later consumed by `execute()`.
    function sweep() external;

    /// @notice Drips EVM-side HYPE into `EXManager.stakeFees` for one throttle cycle.
    /// @dev OPERATOR_ROLE only. Reverts `Errors.AlreadyExecutedThisBlock` on same-block re-entry,
    ///      `Errors.NotReady` if interval hasn't elapsed. The inner `_stake` call reverts
    ///      `BelowMinimum()` when the computed drip is below the LST Router's `minStakeAmount`
    ///      — operator should call `previewStakeAmount()` first and skip the call if too small.
    ///      Spot bridging lives in the separate permissionless `sweep()` so a sub-minimum
    ///      stake leg cannot block independent spot drainage.
    function execute() external;
}
