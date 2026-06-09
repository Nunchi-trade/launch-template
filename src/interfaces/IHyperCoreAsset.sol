// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IHyperCoreAsset
/// @notice Interface for assets that support linking HyperCore and HyperEVM spot assets
interface IHyperCoreAsset {
    /// @notice Emitted when the HyperCore deployer address is set
    event HyperCoreDeployerSet(address indexed deployer);

    /// @notice Gets the HyperCore deployer address used for contract linking verification
    /// @return The stored deployer address
    function getHyperCoreDeployer() external view returns (address);
}
