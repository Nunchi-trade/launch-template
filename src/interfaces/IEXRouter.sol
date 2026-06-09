// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";
import {IBlockedWithdrawalQueue} from "@kinetiq/launch/src/interfaces/IBlockedWithdrawalQueue.sol";

/// @title IEXRouter
/// @notice Interface for the ex router
interface IEXRouter {
    /// @notice Deposits HYPE into an ex manager, minting exLST shares
    /// @dev msg.value is the HYPE amount to deposit, forwarded directly to exManager
    /// @param exManager The address of the ex manager to deposit into
    /// @param recipient The recipient of the exLST shares minted
    /// @param data Gate data to pass through to the ex manager
    /// @return sharesOut The amount of exLST shares minted
    function deposit(IEXManager exManager, address recipient, bytes memory data)
        external
        payable
        returns (uint256 sharesOut);

    /// @notice Withdraws from ex manager burning exLST shares for HYPE
    /// @dev Async queued withdrawal requests could occur depending on the phase ex manager is in
    /// @param exManager The address of the ex manager to withdraw from
    /// @param sharesIn The amount of exLST shares to withdraw
    /// @param recipient The recipient of the funds from withdrawing
    /// @param maxBlockedShares The maximum amount of blocked shares user is willing to accept
    /// @param data Gate data to pass through to the ex manager
    /// @return amountOut The amount of HYPE received
    /// @return withdrawalFee The amount of fees charged on the withdrawal request
    /// @return withdrawalId The queued ID for the withdrawal request, if any
    /// @return blockedShares The amount of exLST shares queued as blocked withdrawals, if any
    /// @return blockedWithdrawalId The blocked withdrawal ID (0 if no blocked withdrawal), if any
    function withdraw(
        IEXManager exManager,
        uint256 sharesIn,
        address recipient,
        uint256 maxBlockedShares,
        bytes memory data
    )
        external
        returns (
            uint256 amountOut,
            uint256 withdrawalFee,
            uint256 withdrawalId,
            uint256 blockedShares,
            uint256 blockedWithdrawalId
        );

    /// @notice Confirms a withdrawal request to withdraw HYPE from an LST via its staking manager
    /// @param exManager The address of the ex manager to confirm the withdrawal request
    /// @param withdrawalId The withdrawal id to confirm
    /// @param recipient The recipient of the withdrawal
    /// @return amountOut The amount of HYPE received by recipient after confirmation
    /// @return withdrawalFee The amount of HYPE fees sent to the ex treasury after confirmation
    function confirm(IEXManager exManager, uint256 withdrawalId, address recipient)
        external
        returns (uint256 amountOut, uint256 withdrawalFee);

    /// @notice Confirms a blocked withdrawal by claiming the specified batches
    /// @param exManager The ex manager whose BWQ holds the blocked withdrawal
    /// @param blockedWithdrawalId The ID of the blocked withdrawal to confirm
    /// @param queuedBatchIndices Array of batch indices to confirm and claim
    /// @return amountReceived The amount of HYPE received by the recipient
    function confirmBlockedWithdrawal(
        IEXManager exManager,
        uint256 blockedWithdrawalId,
        uint256[] calldata queuedBatchIndices
    ) external returns (uint256 amountReceived);

    /// @notice Confirms both regular and blocked withdrawals in a single transaction
    /// @param exManager The ex manager (BWQ derived from `exManager.blockedWithdrawalQueue()`)
    /// @param withdrawalIds Array of regular withdrawal IDs to confirm
    /// @param blockedWithdrawalIds Array of blocked withdrawal IDs to confirm
    /// @param queuedBatchIndicesPerWithdrawal Array of batch indices for each blocked withdrawal
    /// @param recipient The recipient address for all confirmations
    /// @return totalHypeReceived Total HYPE received by recipient across all confirmations
    function confirmAll(
        IEXManager exManager,
        uint256[] calldata withdrawalIds,
        uint256[] calldata blockedWithdrawalIds,
        uint256[][] calldata queuedBatchIndicesPerWithdrawal,
        address recipient
    ) external returns (uint256 totalHypeReceived);

    /// @notice Returns the current phase of the ex manager
    /// @param exManager The address of the ex manager to get the phase of
    /// @return phase The current phase of the ex manager
    function phase(IEXManager exManager) external view returns (IEXManager.EXPhase);

    /// @notice Returns the address of the exLST token for an ex manager
    /// @param exManager The address of the ex manager to get the exLST token of
    /// @return exLST The address of the exLST token for the ex manager
    function exLST(IEXManager exManager) external view returns (address);

    /// @notice Returns the amount of exLST shares equivalent to a given HYPE amount
    /// @param exManager The address of the ex manager
    /// @param amountIn The amount of HYPE to convert
    /// @return sharesOut The amount of exLST shares equivalent to the given HYPE amount
    function hypeToExLst(IEXManager exManager, uint256 amountIn) external view returns (uint256 sharesOut);

    /// @notice Returns the amount of HYPE equivalent to a given amount of exLST shares
    /// @param exManager The address of the ex manager
    /// @param sharesIn The amount of exLST shares to convert
    /// @return amountOut The amount of HYPE equivalent to the given exLST shares
    function exLstToHype(IEXManager exManager, uint256 sharesIn) external view returns (uint256 amountOut);

    /// @notice Returns the withdrawal delay in seconds to process an available withdrawal
    /// @dev Does not consider blocked withdrawals which can have potential unbounded delay due to min HYPE stake requirements
    /// @param exManager The address of the ex manager to get the withdrawal delay for
    /// @param exPhase The ex phase to get the withdrawal delay for
    /// @return delay The withdrawal delay on available withdrawals in seconds
    function withdrawalDelay(IEXManager exManager, IEXManager.EXPhase exPhase) external view returns (uint256 delay);

    /// @notice Returns the withdrawal queue availability for an ex manager
    /// @param exManager The ex manager to get availability for
    /// @return instantWithdrawalCapacity The amount of shares that can be withdrawn instantly (denominated in EXLST shares)
    /// @return processableWithdrawalCapacity The amount of shares that can be withdrawn with a delay (denominated in EXLST shares)
    /// @return currentBlockedWithdrawals The current amount of blocked withdrawals (denominated in GHOST LST shares)
    /// @return delay The withdrawal delay for processable withdrawals
    /// @return minWithdrawalAmount The minimum amount of shares that may be withdrawn.
    function queueWithdrawalAvailability(IEXManager exManager)
        external
        view
        returns (
            uint256 instantWithdrawalCapacity,
            uint256 processableWithdrawalCapacity,
            uint256 currentBlockedWithdrawals,
            uint256 delay,
            uint256 minWithdrawalAmount
        );

    /// @notice Returns withdrawal info for a user's withdrawals on an ex manager
    /// @param exManager The ex manager to get withdrawal info for
    /// @param recipient The recipient to get withdrawal info for
    /// @return exManagerWithdrawals Array of withdrawal info for the user
    function userWithdrawalInfo(IEXManager exManager, address recipient)
        external
        view
        returns (WithdrawalInfo[] memory exManagerWithdrawals);

    /// @notice Returns blocked withdrawal info for a recipient
    /// @param blockedWithdrawalQueue The blocked withdrawal queue to get info from
    /// @param recipient The recipient to get blocked withdrawal info for
    /// @return blockedWithdrawals Array of blocked withdrawal info for the recipient
    function blockedWithdrawalInfo(IBlockedWithdrawalQueue blockedWithdrawalQueue, address recipient)
        external
        view
        returns (BlockedWithdrawalInfo[] memory blockedWithdrawals);

    /// @notice Aggregate market state for frontend consumption — single call alternative to
    ///         waterfalling phase / tier / reserves / share supply / cap reads.
    /// @param exManager The ex manager to get market state for; must be a factory-registered market
    /// @return state Aggregated market state struct
    function marketState(IEXManager exManager) external view returns (MarketState memory state);

    /// @notice Withdrawal info struct
    struct WithdrawalInfo {
        uint256 withdrawalId; // Withdrawal ID
        uint256 hypeAmount; // Amount of HYPE received from withdrawal
        uint256 delayDeadline; // When the withdrawal should be complete.
        bool withdrawable; // Validates deadline has passed and manager has the required capital.
    }

    /// @notice Processing batch info struct
    struct ProcessingBatch {
        uint256 index; // Batch index
        uint256 deadline; // Deadline for the batch to be processed
    }

    /// @notice Blocked withdrawal info struct
    struct BlockedWithdrawalInfo {
        uint256 blockedWithdrawalId; // Blocked withdrawal ID
        uint256 ghostLstAmountUnprocessed; // Amount of ghost LST shares unprocessed
        uint256 ghostLstAmountProcessed; // Amount of ghost LST shares processed
        uint256[] claimableBatchIndices; // Batch indices that are claimable
        uint256 claimableAmount; // Amount of HYPE that is claimable
        ProcessingBatch[] processingBatches; // Batches that are being processed
        uint256 processingHype; // Amount of HYPE that is being processed
    }

    /// @notice Aggregate market state — every field a frontend would render for a single market
    /// @param phase Current lifecycle phase of the market
    /// @param marketTier Market's tier (1-indexed; resolves via GlobalConfig tier registry)
    /// @param hypeForExLst HYPE reserves backing outstanding exLST shares
    /// @param hypeInBwq HYPE reserves earmarked for pending blocked withdrawals
    /// @param totalHypeReserves Total HYPE reserves under the market's management (hypeForExLst + hypeInBwq)
    /// @param minHypeStake Minimum HYPE reserves required to maintain the market's current tier
    /// @param totalShares exLST shares in circulation
    /// @param supplyCap Maximum exLST shares that may circulate (raises via tier upgrade)
    /// @param deployer Bond capital owner (immutable; sweep target at unwind, recipient of activate refund)
    /// @param buybackBps Deployer-chosen % (basis points) of post-protocol-share remainder routed to the
    ///                   LST-compound loop (vs deployer's direct treasury revenue); set at LFS init
    /// @param activated True iff every contract in `factory.activationTargets(marketId)` reports
    ///                  `IHyperCoreActivatable.activated()` — mirrors `bondMarket`'s precondition so the
    ///                  frontend sees the same activation state that gates bonding on-chain
    /// @param validator Per-market L1 validator (kHYPE delegation target on the per-market Router)
    struct MarketState {
        IEXManager.EXPhase phase;
        uint256 marketTier;
        uint256 hypeForExLst;
        uint256 hypeInBwq;
        uint256 totalHypeReserves;
        uint256 minHypeStake;
        uint256 totalShares;
        uint256 supplyCap;
        address deployer;
        uint64 buybackBps;
        bool activated;
        address validator;
    }
}
