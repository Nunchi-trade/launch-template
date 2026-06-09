// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPauserRegistry as ILSTPauserRegistry} from "@kinetiq/lst/src/interfaces/IPauserRegistry.sol";

/// @title IPauserRegistry
/// @notice Extended PauserRegistry interface that includes authorize/deauthorize
interface IPauserRegistry is ILSTPauserRegistry {
    /// @notice Authorizes a contract to be managed by the pauser registry
    /// @param contractAddress The address of the contract to authorize
    function authorizeContract(address contractAddress) external;

    /// @notice Removes a contract from the pauser registry's authorized set
    /// @param contractAddress The address of the contract to deauthorize
    function deauthorizeContract(address contractAddress) external;
}
