// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IStakingManager} from "@kinetiq/lst/src/interfaces/IStakingManager.sol";
import {IStakingAccountant} from "@kinetiq/lst/src/interfaces/IStakingAccountant.sol";

/// @title ILSTState
/// @notice Interface for the LST state variables
interface ILSTState {
    /// @notice The token address associated with native HYPE for the contracts
    function HYPE() external view returns (address);

    /// @notice The KHYPE token address
    function KHYPE() external view returns (address);

    /// @notice The KHYPE staking manager
    function KHYPE_STAKING_MANAGER() external view returns (IStakingManager);

    /// @notice The KHYPE staking accountant
    function KHYPE_STAKING_ACCOUNTANT() external view returns (IStakingAccountant);
}
