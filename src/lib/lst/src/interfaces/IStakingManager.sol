// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakingManager {
    /* ========== STRUCTS ========== */

    struct WithdrawalRequest {
        uint256 hypeAmount; // Amount in HYPE to withdraw
        uint256 kHYPEAmount; // Amount in kHYPE to burn (excluding fee)
        uint256 kHYPEFee; // Fee amount in kHYPE tokens
        uint256 bufferUsed; // Amount fulfilled from hypeBuffer
        uint256 timestamp; // Request timestamp
    }

    // Define the enum on operation type
    enum OperationType {
        UserDeposit, // 0: User deposit operation; from EVM to Validator
        SpotDeposit, // 1: Deposit operation from SpotAccount to Validator(handling dusts)
        RebalanceDeposit, // 2: Rebalancing deposit operation; from StakingAccount to Validator
        UserWithdrawal, // 3: User withdrawal; From Validator to EVM
        RebalanceWithdrawal // 4: Rebalancing withdrawal; From Validator to StakingAccount
    }

    // Update the L1Operation struct to use the enum
    struct L1Operation {
        address validator;
        uint256 amount;
        OperationType operationType;
    }

    /* ========== EVENTS ========== */

    event StakeReceived(address indexed staking, address indexed staker, uint256 amount);
    event WithdrawalQueued(
        address indexed staking,
        address indexed user,
        uint256 indexed withdrawalId,
        uint256 kHYPEAmount,
        uint256 hypeAmount,
        uint256 feeAmount
    );
    event WithdrawalConfirmed(address indexed user, uint256 indexed withdrawalId, uint256 amount);
    event WithdrawalCancelled(
        address indexed user, uint256 indexed withdrawalId, uint256 amount, uint256 totalCancelled
    );
    event StakingLimitUpdated(uint256 newStakingLimit);
    event MinStakeAmountUpdated(uint256 newMinStakeAmount);
    event MaxStakeAmountUpdated(uint256 newMaxStakeAmount);
    event MinWithdrawalAmountUpdated(uint256 newMinWithdrawalAmount);
    event WithdrawalDelayUpdated(uint256 newDelay);
    event QuickWithdrawalDelayUpdated(uint256 newDelay);
    event Delegate(address indexed staking, address indexed validator, uint256 amount);
    event TargetBufferUpdated(uint256 newTargetBuffer);
    event BufferIncreased(uint256 amountAdded, uint256 newTotal);
    event BufferDecreased(uint256 amountRemoved, uint256 newTotal);
    event ValidatorWithdrawal(address indexed staking, address indexed validator, uint256 amount);
    event WhitelistEnabled();
    event WhitelistDisabled();
    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);
    // Add events for pause state changes
    event StakingPaused(address indexed by);
    event StakingUnpaused(address indexed by);
    event WithdrawalPaused(address indexed by);
    event WithdrawalUnpaused(address indexed by);
    event WithdrawalRedelegated(uint256 amount);
    event UnstakeFeeRateUpdated(uint256 newRate);
    // Add event for treasury updates
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    // Add event for stake & unstake queued L1 operations, amount is decimal 8 here
    event L1DelegationQueued(
        address indexed staking, address indexed validator, uint256 amount, OperationType operationType
    );
    event L1DelegationProcessed(
        address indexed staking, address indexed validator, uint256 amount, OperationType operationType
    );
    event SpotWithdrawn(uint256 amount);
    // Add events for airdrops
    /**
     * @notice Emitted when a token is withdrawn from spot balance
     * @param tokenId The ID of the token withdrawn
     * @param amount The amount withdrawn
     * @param recipient The address receiving the tokens
     */
    event TokenWithdrawnFromSpot(uint64 indexed tokenId, uint64 amount, address indexed recipient);
    /**
     * @notice Emitted when a token is rescued from the contract
     * @param token The address of the token rescued (address(0) for native tokens)
     * @param amount The amount rescued
     * @param recipient The address receiving the tokens
     */
    event TokenRescued(address indexed token, uint256 amount, address indexed recipient);
    /**
     * @notice Emitted when L1 operations are queued for retry
     * @param validators Array of validator addresses
     * @param amounts Array of amounts
     * @param operationTypes Array of operation types
     */
    event L1OperationsQueued(address[] validators, uint256[] amounts, OperationType[] operationTypes);
    /**
     * @notice Emitted when L1 operations are processed in batch
     * @param processedCount Number of operations processed
     * @param remainingCount Number of operations remaining
     */
    event L1OperationsBatchProcessed(uint256 processedCount, uint256 remainingCount);
    /**
     * @notice Emitted when the L1 operations queue is reset
     * @param queueLength Length of the queue before reset
     */
    event L1OperationsQueueReset(uint256 queueLength);
    /**
     * @notice Emitted when an emergency withdrawal is executed
     * @param validator Address of the validator
     * @param amount Amount withdrawn
     */
    event EmergencyWithdrawalExecuted(address indexed validator, uint256 amount);

    /**
     * @notice Emitted when an L1 operation is aggregated with an existing operation
     * @param staking Address of the staking contract
     * @param validator Address of the validator
     * @param addedAmount Amount added to existing operation
     * @param newTotalAmount New total amount after aggregation
     * @param operationType Type of operation
     */
    event L1OperationAggregated(
        address indexed staking,
        address indexed validator,
        uint256 addedAmount,
        uint256 newTotalAmount,
        OperationType operationType
    );

    /* ========== INSTANT UNSTAKE EVENTS ========== */

    /**
     * @notice Emitted when instant unstake pool address is updated
     * @param poolAddress New pool address (or address(0) if disabled)
     */
    event InstantUnstakePoolUpdated(address poolAddress);
    event OracleManagerUpdated(address oracleManager);
    event RewardShareTrackerUpdated(address rewardShareTracker);
    /**
     * @notice Emitted when InstantUnstakePool is cleared via emergencyClear
     * @param amountReturned Amount of HYPE returned from the pool
     * @param totalCancelledAmount Total amount now available for redelegation
     */
    event InstantUnstakePoolCleared(uint256 amountReturned, uint256 totalCancelledAmount);
    event InstantUnstakeExecuted(
        address indexed user,
        uint256 kHYPEAmount,
        uint256 hypeReceived,
        uint256 kHYPEFee,
        uint256 feeRateBps,
        uint256 kHYPEFeeBurned,
        uint256 kHYPEFeeToTreasury
    );

    /**
     * @notice Emitted when buffer is rebalanced via withdrawal from validators
     * @param amount Amount withdrawn to buffer
     */
    event BufferRebalanceWithdrawal(uint256 amount);
    event BufferRebalanceCompleted(uint256 indexed rebalanceId, uint256 amount);

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Gets the total amount of HYPE staked
    function totalStaked() external view returns (uint256);

    /// @notice Gets the total amount of HYPE claimed
    function totalClaimed() external view returns (uint256);

    /// @notice Gets the total amount of queued withdrawals
    function totalQueuedWithdrawals() external view returns (uint256);

    /// @notice Gets the current HYPE buffer amount
    function hypeBuffer() external view returns (uint256);

    /// @notice Gets the target buffer size
    function targetBuffer() external view returns (uint256);

    /// @notice Gets the maximum total staking limit
    function stakingLimit() external view returns (uint256);

    /// @notice Gets the minimum stake amount per transaction
    function minStakeAmount() external view returns (uint256);

    /// @notice Gets the maximum stake amount per transaction
    function maxStakeAmount() external view returns (uint256);

    /// @notice Gets the withdrawal delay period
    function withdrawalDelay() external view returns (uint256);

    /// @notice Gets the quick withdrawal delay period
    function quickWithdrawalDelay() external view returns (uint256);

    /// @notice Gets withdrawal request details for a user
    function withdrawalRequests(address user, uint256 id) external view returns (WithdrawalRequest memory);

    /// @notice Gets the next withdrawal ID for a user
    function nextWithdrawalId(address user) external view returns (uint256);

    /// @notice Gets the current unstake fee rate
    function unstakeFeeRate() external view returns (uint256);

    /// @notice Gets the basis points constant (10000 = 100%)
    function BASIS_POINTS() external view returns (uint256);

    /* ========== INSTANT UNSTAKE VIEW FUNCTIONS ========== */

    /// @notice Gets comprehensive queue information for both withdrawal and deposit operations
    /// @return withdrawalLength Total length of withdrawal queue
    /// @return withdrawalIndex Current processing index for withdrawals
    /// @return depositLength Total length of deposit queue
    /// @return depositIndex Current processing index for deposits
    /// @return unprocessedWithdrawals Number of unprocessed withdrawal operations
    /// @return unprocessedDeposits Number of unprocessed deposit operations
    function getQueueInfo()
        external
        view
        returns (
            uint256 withdrawalLength,
            uint256 withdrawalIndex,
            uint256 depositLength,
            uint256 depositIndex,
            uint256 unprocessedWithdrawals,
            uint256 unprocessedDeposits
        );

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Stake HYPE with protocol-controlled delegation (default)
     * @dev Converts HYPE to kHYPE at current exchange rate
     */
    function stake() external payable;

    /**
     * @notice Stake HYPE with user-delegated validator
     * @param validator Address of the validator to delegate to
     * @dev User must choose from active validator set
     */
    function stake(address validator) external payable;

    /**
     * @notice Instant unstake - withdraw HYPE immediately from buffer with flat fee
     * @param kHYPEAmount Amount of kHYPE to unstake
     * @param minHYPEOut Minimum HYPE to receive (slippage protection)
     */
    function instantUnstake(uint256 kHYPEAmount, uint256 minHYPEOut) external;

    /// @notice Queues a withdrawal request (from current delegation)
    function queueWithdrawal(uint256 amount) external;

    /// @notice Confirms a withdrawal request (user confirms their own)
    function confirmWithdrawal(uint256 withdrawalId) external;

    /**
     * @notice Batch confirm multiple withdrawal requests (user confirms their own)
     * @param withdrawalIds Array of withdrawal IDs to confirm
     */
    function batchConfirmWithdrawals(uint256[] calldata withdrawalIds) external;

    /**
     * @notice Confirm a withdrawal on behalf of a user (operator confirms for user)
     * @param user Address of the withdrawal owner
     * @param withdrawalId ID of the withdrawal request
     * @dev Funds are sent to the user, not the caller (operator)
     * @dev Only callable by OPERATOR_ROLE
     */
    function confirmWithdrawalFor(address user, uint256 withdrawalId) external;

    /**
     * @notice Batch confirm multiple withdrawals for a user (operator confirms for user)
     * @param user Address of the withdrawal owner
     * @param withdrawalIds Array of withdrawal IDs to confirm
     * @dev Funds are sent to the user, not the caller (operator)
     * @dev Only callable by OPERATOR_ROLE
     */
    function batchConfirmWithdrawalsFor(address user, uint256[] calldata withdrawalIds) external;

    /**
     * @notice Process pending L1 operations in batches
     * @param batchSize Maximum number of operations to process
     * @dev Only callable by OPERATOR_ROLE
     * @dev Processes both pending withdrawals and deposits
     */
    function processL1Operations(uint256 batchSize) external;

    /**
     * @notice Queue L1 operations directly for retrying failed operations
     * @dev Callable by OPERATOR_ROLE
     * @param validators Array of validator addresses
     * @param amounts Array of amounts to process
     * @param operationTypes Array of operation types
     */
    function queueL1Operations(
        address[] calldata validators,
        uint256[] calldata amounts,
        OperationType[] calldata operationTypes
    ) external;

    /* ========== WHITELIST FUNCTIONS ========== */

    function setWhitelistEnabled(bool enabled) external;
    function manageWhitelist(address[] calldata accounts, bool add) external;
    function isWhitelisted(address account) external view returns (bool);
    function whitelistLength() external view returns (uint256);

    /* ========== INSTANT UNSTAKE ADMIN FUNCTIONS ========== */

    /**
     * @notice Set the instant unstake pool address
     * @param poolAddress Address of the InstantUnstakePool contract (or address(0) to disable)
     */
    function setInstantUnstakePool(address poolAddress) external;

    /**
     * @notice Request buffer rebalance withdrawal to fill instant unstake pool
     * @dev Only callable by OPERATOR_ROLE
     * @dev Amount is auto-calculated by the pool based on low water mark
     */
    function requestBufferRebalance() external;

    /**
     * @notice Complete the oldest buffer rebalance after HYPE arrives from L1
     * @dev Only callable by OPERATOR_ROLE
     * @dev Transfers HYPE to the pool and completes the rebalance
     */
    function completeBufferRebalance() external;

    /* ========== REWARD SHARE FUNCTIONS ========== */

    /**
     * @notice Queue a reward share distribution
     * @param validator Validator address that earned rewards
     * @param rewardShareAmount The 10% reward share amount (pre-calculated by OracleManager)
     * @return distributionId ID of the queued distribution
     * @dev Called by OracleManager when rewards are reported
     * @dev OracleManager calculates the 10% split; RewardShareTracker splits 70% deployer / 30% treasury
     */
    function queueRewardDistribution(address validator, uint256 rewardShareAmount)
        external
        returns (uint256 distributionId);

    /**
     * @notice Complete the first matured reward distribution (transfer HYPE to RewardShareTracker)
     * @dev Only callable by OPERATOR_ROLE
     * @dev Called after HYPE arrives from L1 settlement
     * @dev Queries first matured distribution and sends HYPE to tracker for distribution
     */
    function completeRewardDistribution() external;
}
