// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IGlobalConfig} from "@kinetiq/launch/src/interfaces/IGlobalConfig.sol";
import {IHIP3StakingManager} from "@kinetiq/launch/src/interfaces/IHIP3StakingManager.sol";
import {IStakingAccountant} from "@kinetiq/lst/src/interfaces/IStakingAccountant.sol";
import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";
import {IEXLST} from "@kinetiq/launch/src/interfaces/IEXLST.sol";
import {IPauserRegistry} from "@kinetiq/lst/src/interfaces/IPauserRegistry.sol";

/// @title IBlockedWithdrawalQueue
/// @notice Interface for the BlockedWithdrawalQueue contract
interface IBlockedWithdrawalQueue {
    /* ========== STRUCTS ========== */

    /// @notice Data structure for a blocked withdrawal
    struct BlockedWithdrawal {
        address recipient; // The recipient of the withdrawal
        uint256 remainingGhostShares; // Remaining ghost shares to be processed
        uint256 totalGhostShares; // Total ghost shares in the blocked withdrawal
        QueuedBatch[] queuedBatches; // Array of queued batches for this withdrawal
    }

    /// @notice Data structure for a queued batch within a blocked withdrawal
    struct QueuedBatch {
        uint256 smid; // Staking Manager withdrawal ID
        uint256 hypeOwed; // Amount of HYPE owed for this batch after fees
    }

    /// @notice Data structure for a batch info
    struct BatchInfo {
        uint248 fee; // 248 bits for fee, larger than hype supply.
        BatchStatus status; // Status of the batch
        uint256 hypeExpected; // Gross HYPE expected (pre-fee) across all users in the batch (set at process time)
        uint256 hypeReceived; // Gross HYPE received from staking manager (set at confirm time)
    }

    enum BatchStatus {
        UNINITIALIZED,
        PENDING,
        CONFIRMED
    }

    /* ========== EVENTS ========== */

    /// @notice Emitted when a blocked withdrawal is queued
    /// @param recipient The recipient of the withdrawal
    /// @param blockedWithdrawalId The ID of the blocked withdrawal
    /// @param ghostShares The number of ghost LST shares queued
    event BlockedWithdrawalQueued(address recipient, uint256 blockedWithdrawalId, uint256 ghostShares);

    /// @notice Emitted when a batch is queued for a blocked withdrawal
    /// @param smid The StakingManager withdrawal ID
    /// @param ghostShares The number of ghost LST shares in the batch
    /// @param hypeAmount The amount of HYPE expected after fees
    /// @param hypeFee The amount of HYPE charged as fees
    event BatchQueued(uint256 smid, uint256 ghostShares, uint256 hypeAmount, uint256 hypeFee);

    /// @notice Emitted when a blocked withdrawal batch is confirmed
    /// @param recipient The recipient of the withdrawal
    /// @param blockedWithdrawalId The ID of the blocked withdrawal
    /// @param batchIndexes The index of the batches confirmed
    /// @param hypeAmount The amount of HYPE received
    event BlockedWithdrawalConfirmed(
        address indexed recipient, uint256 indexed blockedWithdrawalId, uint256[] batchIndexes, uint256 hypeAmount
    );

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Returns the global config contract
    /// @return The global config contract
    function globalConfig() external view returns (IGlobalConfig);

    /// @notice Returns the pauser registry contract — gates processBlockedWithdrawals + confirmBlockedWithdrawal
    /// @return The pauser registry contract
    function pauserRegistry() external view returns (IPauserRegistry);

    /// @notice Returns the ex staking manager
    /// @return The ex change staking manager
    function exStakingManager() external view returns (IHIP3StakingManager);

    /// @notice Returns the ex staking accountant
    /// @return The ex staking accountant
    function exStakingAccountant() external view returns (IStakingAccountant);

    /// @notice Returns the ex manager
    /// @return The ex manager
    function exManager() external view returns (IEXManager);

    /// @notice Returns the ghost LST token address
    /// @return The address of the ghost LST token associated with exStakingManager
    function ghostLST() external view returns (address);

    /// @notice Returns the total blocked queue amount
    /// @return The total amount of ghostLST shares in the blocked queue
    function totalBlockedQueue() external view returns (uint256);

    /// @notice Returns the batch info for a queued batch
    /// @param smid The staking manager withdrawal ID
    /// @return fee The fee amount for the batch
    /// @return status The status of the batch
    function queuedBatch(uint256 smid)
        external
        view
        returns (uint248 fee, BatchStatus status, uint256 hypeExpected, uint256 hypeReceived);

    /// @notice Returns the last withdrawal ID for a recipient
    /// @param recipient The recipient address
    /// @return The last withdrawal ID for the recipient
    function recipientWithdrawalId(address recipient) external view returns (uint256);

    /// @notice Returns the blocked withdrawal ID for a user's withdrawal index
    /// @param recipient The recipient address
    /// @param index The withdrawal index for the recipient
    /// @return The blocked withdrawal ID
    function userWithdrawalIndices(address recipient, uint256 index) external view returns (uint256);

    /// @notice Returns the index of the last processed blocked withdrawal
    /// @return The index of the last processed blocked withdrawal
    function lastProcessedBlockedWithdrawal() external view returns (uint256);

    /// @notice Returns the blocked withdrawal data for a given ID
    /// @param blockedWithdrawalId The ID of the blocked withdrawal
    /// @return The blocked withdrawal struct
    function blockedWithdrawal(uint256 blockedWithdrawalId) external view returns (BlockedWithdrawal memory);

    /// @notice Returns the number of shares that can be processed
    /// @return The number of ghost LST shares that can be processed
    function processableShares() external view returns (uint256);

    /* ========== EXTERNAL FUNCTIONS ========== */

    /// @notice Queues a blocked withdrawal
    /// @param blockedShares The number of shares to queue
    /// @param recipient The recipient of the withdrawal
    /// @return blockedWithdrawalId The ID of the blocked withdrawal
    function queueBlockedWithdrawal(uint256 blockedShares, address recipient)
        external
        returns (uint256 blockedWithdrawalId);

    /// @notice Processes blocked withdrawals from the queue
    /// @dev Iterates through blocked withdrawals in FIFO order and processes up to available liquidity
    /// @dev Processing stops when:
    ///      - No more withdrawable shares are available
    ///      - Available shares are below chunkSize threshold
    ///      - A withdrawal is only partially processed
    /// @param items The number of items to process. If 0, processes until hits one of the stop conditions.
    function processBlockedWithdrawals(uint256 items) external;

    /// @notice Confirms a blocked withdrawal by claiming the batches
    /// @param blockedWithdrawalId The ID of the blocked withdrawal
    /// @param queuedBatchIndices The indices of the queued batches to confirm
    /// @return amountReceived The amount of HYPE received by the recipient
    function confirmBlockedWithdrawal(uint256 blockedWithdrawalId, uint256[] calldata queuedBatchIndices)
        external
        returns (uint256 amountReceived);
}
