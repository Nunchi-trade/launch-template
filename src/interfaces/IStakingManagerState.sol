// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IKHYPEToken} from "@kinetiq/lst/src/interfaces/IKHYPE.sol";
import {IPauserRegistry} from "@kinetiq/lst/src/interfaces/IPauserRegistry.sol";
import {IStakingAccountant} from "@kinetiq/lst/src/interfaces/IStakingAccountant.sol";
import {IValidatorManager} from "@kinetiq/lst/src/interfaces/IValidatorManager.sol";

/// @title IStakingManagerState
/// @notice Interface for public storage getters auto-generated on the StakingManagerRouter.
///         These are not declared in IStakingManager but exist as public vars in StakingManagerStorage.
interface IStakingManagerState {
    /* ========== STATE FUNCTIONS ========== */

    /// @notice The validator manager for the staking manager
    function validatorManager() external view returns (IValidatorManager);

    /// @notice The pauser registry for the staking manager
    function pauserRegistry() external view returns (IPauserRegistry);

    /// @notice The staking accountant for the staking manager
    function stakingAccountant() external view returns (IStakingAccountant);

    /// @notice The kHYPE/ghost LST token for the staking manager
    function tokenAddress() external view returns (IKHYPEToken);

    /// @notice The treasury for the staking manager
    function treasury() external view returns (address);

    /// @notice Whether the staking is paused for the staking manager
    function stakingPaused() external view returns (bool);

    /// @notice Whether the withdrawal is paused for the staking manager
    function withdrawalPaused() external view returns (bool);

    /// @notice Whether the whitelist is enabled for the staking manager
    function whitelistEnabled() external view returns (bool);

    /// @notice Minimum withdrawable shares in one call
    function minWithdrawalAmount() external view returns (uint256);
}
