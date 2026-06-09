// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IUpgradeableBeaconRegistry
/// @notice Interface for the UpgradeableBeaconRegistry that manages per-market beacon instances.
///         Contract types are identified by uint8 keys. InitialContractType enum defines the
///         initial types registered at initialization; new types can be added via registerBeacon().
interface IUpgradeableBeaconRegistry {
    /// @notice Initial per-market contract types registered at initialization
    enum InitialContractType {
        Router,
        EXManager,
        EXLST,
        StakingAccountant,
        ValidatorManager,
        OracleManager,
        RewardShareTracker,
        GhostLST,
        BlockedWithdrawalQueue,
        LaunchFeeSplitter,
        StakeFeesThrottle
    }

    /// @notice Returns the human-readable name for a contract type
    function contractTypeName(uint8 contractType) external view returns (string memory);

    /// @notice Returns the total number of registered contract types
    function totalContractTypes() external view returns (uint8);

    /// @notice Emitted when a new beacon is registered
    event BeaconRegistered(uint8 indexed contractType, address beacon, address implementation);

    /// @notice Emitted when a beacon implementation is upgraded
    event BeaconUpgraded(uint8 indexed contractType, address oldImplementation, address newImplementation);

    /// @notice Registers a new beacon for a contract type
    /// @dev Reverts if the contract type already has a beacon
    /// @param contractType The uint8 key for the new contract type
    /// @param impl The initial implementation address
    /// @param name Human-readable name for the contract type
    function registerBeacon(uint8 contractType, address impl, string calldata name) external;

    /// @notice Returns the beacon address for a contract type
    function getBeacon(uint8 contractType) external view returns (address);

    /// @notice Returns the current implementation for a contract type
    function implementation(uint8 contractType) external view returns (address);

    /// @notice Upgrades the implementation for a contract type
    function upgradeTo(uint8 contractType, address newImpl) external;
}
