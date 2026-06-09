// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRewardShareTracker
 * @notice Interface for the RewardShareTracker contract that manages the 10% reward share mechanism
 * @dev Tracks reward distributions and splits between Deployer (70%) and Treasury (30%)
 */
interface IRewardShareTracker {
    /* ========== STRUCTS ========== */

    /// @notice Record of a pending reward distribution
    struct PendingRewardDistribution {
        address validator;
        uint256 newRewardAmount;
        uint256 rewardShare;
        uint256 deployerAmount;
        uint256 treasuryAmount;
        uint256 requestTime;
        bool completed;
    }

    /* ========== EVENTS ========== */

    /// @notice Emitted when a reward distribution is queued
    event RewardDistributionQueued(
        uint256 indexed distributionId,
        address indexed validator,
        uint256 newRewardAmount,
        uint256 rewardShare,
        uint256 deployerAmount,
        uint256 treasuryAmount
    );

    /// @notice Emitted when a reward distribution is completed
    event RewardDistributionCompleted(uint256 indexed distributionId, uint256 rewardShare);

    /// @notice Emitted when reward share is calculated and tracked
    event RewardShareCalculated(
        uint256 totalRewards, uint256 rewardShareAmount, uint256 deployerShare, uint256 treasuryShare
    );

    /// @notice Emitted when deployer share is transferred
    event DeployerShareTransferred(address indexed deployer, uint256 amount);

    /// @notice Emitted when treasury share is transferred
    event TreasuryShareTransferred(address indexed treasury, uint256 amount);

    /// @notice Emitted when deployer wallet is updated
    event DeployerWalletUpdated(address indexed oldDeployer, address indexed newDeployer);

    /// @notice Emitted when treasury wallet is updated
    event TreasuryWalletUpdated(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Emitted when reward share percentage is updated
    event RewardShareBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when deployer split percentage is updated
    event DeployerSplitBpsUpdated(uint256 oldBps, uint256 newBps);

    /// @notice Emitted when staking manager address is updated
    event StakingManagerUpdated(address indexed oldManager, address indexed newManager);

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get the reward share percentage in basis points (default 1000 = 10%)
    function rewardShareBps() external view returns (uint256);

    /// @notice Get the deployer split percentage in basis points (default 7000 = 70%)
    function deployerSplitBps() external view returns (uint256);

    /// @notice Get the treasury split percentage in basis points (calculated as 10000 - deployerSplitBps)
    function treasurySplitBps() external view returns (uint256);

    /// @notice Get the deployer wallet address
    function deployerWallet() external view returns (address);

    /// @notice Get the treasury wallet address
    function treasuryWallet() external view returns (address);

    /// @notice Get total reward share ever distributed
    function totalRewardShareDistributed() external view returns (uint256);

    /// @notice Get total sent to deployer wallet
    function totalDeployerShareDistributed() external view returns (uint256);

    /// @notice Get total sent to treasury wallet
    function totalTreasuryShareDistributed() external view returns (uint256);

    /// @notice Get cumulative reward share diverted for a specific validator
    /// @param validator Address of the validator
    /// @return Cumulative reward share amount diverted from this validator
    function validatorRewardShareDiverted(address validator) external view returns (uint256);

    /// @notice Calculate the reward share amount for a given total rewards
    /// @param totalRewards Total rewards to calculate share from
    /// @return rewardShare The 10% reward share amount
    /// @return netRewards The 90% remaining for kHYPE holders
    function calculateRewardShare(uint256 totalRewards) external view returns (uint256 rewardShare, uint256 netRewards);

    /// @notice Calculate the deployer/treasury split for a reward share amount
    /// @param rewardShareAmount The reward share to split
    /// @return deployerAmount 70% to deployer
    /// @return treasuryAmount 30% to treasury
    function calculateSplit(uint256 rewardShareAmount)
        external
        view
        returns (uint256 deployerAmount, uint256 treasuryAmount);

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @notice Queue a new reward distribution (async - HYPE will arrive later from L1)
    /// @param newRewards Total new rewards since last distribution
    /// @param validator Validator address that earned the rewards
    /// @dev Can only be called by StakingManager
    /// @dev Does not receive HYPE immediately - queues for later completion
    function recordRewardDistribution(uint256 newRewards, address validator)
        external
        returns (uint256 distributionId, uint256 rewardShare, uint256 deployerAmount, uint256 treasuryAmount);

    /// @notice Complete a matured reward distribution (HYPE arrived from L1)
    /// @param distributionId ID of the distribution to complete
    /// @dev Can only be called by StakingManager
    /// @dev Receives HYPE and immediately transfers to deployer/treasury
    function completeRewardDistribution(uint256 distributionId) external payable;

    /// @notice Get all pending reward distributions
    function getPendingDistributions() external view returns (PendingRewardDistribution[] memory);

    /// @notice Get the first matured pending distribution
    function getFirstMaturedDistribution()
        external
        view
        returns (PendingRewardDistribution memory distribution, uint256 distributionId);

    /// @notice Get count of pending distributions
    function getPendingDistributionCount() external view returns (uint256);

    /// @notice Get reward distribution delay (time before distribution can be completed)
    function rewardDistributionDelay() external view returns (uint256);

    /* ========== ADMIN FUNCTIONS ========== */

    /// @notice Set the deployer wallet address
    function setDeployerWallet(address newDeployer) external;

    /// @notice Set the treasury wallet address
    function setTreasuryWallet(address newTreasury) external;

    /// @notice Set the reward share percentage (max 2000 = 20%)
    function setRewardShareBps(uint256 newBps) external;

    /// @notice Set the deployer split percentage (max 10000 = 100%)
    function setDeployerSplitBps(uint256 newBps) external;
}
