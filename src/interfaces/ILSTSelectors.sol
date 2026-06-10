// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/// @title ILSTSelectors
/// @notice Selector-only stubs for the four LST stack methods that operator-driven scripts
///         invoke via `ProtocolRolesController.execute(marketId, component, calldata)`. The
///         actual implementations live in the protocol's LST stack (`L1OperationsFacet`,
///         `RewardShareFacet`, `OracleManager`, `DefaultOracle`) and are not vendored here;
///         this interface exists so script-side `abi.encodeCall(ILSTSelectors.<method>, args)`
///         stays type-safe without pulling the concrete contracts into this repo.
interface ILSTSelectors {
    function processL1Operations(uint256 maxOps) external; // L1OperationsFacet

    function completeRewardDistribution() external; // RewardShareFacet

    function generatePerformance(address validator) external; // OracleManager

    function updateValidatorMetrics(
        address validator,
        uint256 balance,
        uint256 performanceBps,
        uint256 cumulativeReward,
        uint256 cumulativeSlashing,
        uint256 blockNumber
    ) external; // DefaultOracle
}
