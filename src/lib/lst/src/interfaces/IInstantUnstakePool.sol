// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IInstantUnstakePool {
    /* ========== STRUCTS ========== */

    struct PendingBufferRebalance {
        uint256 amount;
        uint256 requestTime;
        bool fromBuffer; // True if rebalance was fulfilled from buffer, false if from validator
        bool completed;
    }

    /* ========== EVENTS ========== */

    event InstantUnstakeExecuted(
        address indexed user,
        uint256 kHYPEAmount,
        uint256 hypeReceived,
        uint256 kHYPEFee,
        uint256 feeRateBps,
        uint256 kHYPEFeeBurned,
        uint256 kHYPEFeeToTreasury
    );

    event RebalanceRequested(uint256 indexed rebalanceId, uint256 amount, uint256 requestTime);
    event RebalanceCompleted(uint256 indexed rebalanceId, uint256 amount);
    event BufferDeposited(uint256 amount, uint256 newTotal);
    event BufferWithdrawn(address indexed user, uint256 amount, uint256 newTotal);
    event TreasuryCreditDeposited(uint256 amount, uint256 totalCredit, uint256 newBufferTotal);
    event TreasuryCreditRepaid(uint256 amount, uint256 remainingCredit, uint256 newBufferTotal);
    event TargetBufferUpdated(uint256 newTarget);
    event LowWaterMarkUpdated(uint256 newMark);
    event InstantUnstakeFeeRateUpdated(uint256 newRate);
    event FeeDistributionBurnUpdated(uint256 newBurnBps);
    event EmergencyCleared(uint256 amountReturned);

    /* ========== VIEW FUNCTIONS ========== */

    function instantUnstakeBuffer() external view returns (uint256);
    function targetInstantUnstakeBuffer() external view returns (uint256);
    function lowWaterMark() external view returns (uint256);
    function instantUnstakeFeeRate() external view returns (uint256);
    function feeDistributionBurnBps() external view returns (uint256);
    function treasuryCredit() external view returns (uint256);

    function getEffectiveBuffer() external view returns (uint256);
    function getBufferRebalanceStatus() external view returns (bool needsRebalance, uint256 amount);
    function getFirstMaturedRebalance()
        external
        view
        returns (PendingBufferRebalance memory rebalance, uint256 rebalanceId);
    function getPendingRebalances() external view returns (PendingBufferRebalance[] memory);
    function getPendingRebalanceCount() external view returns (uint256 count);

    function previewInstantUnstake(uint256 kHYPEAmount)
        external
        view
        returns (uint256 hypeAmount, uint256 kHYPEFee, uint256 feeRateBps, bool bufferSufficient);

    function getBufferStatus()
        external
        view
        returns (
            uint256 currentBuffer,
            uint256 effectiveBuffer,
            uint256 target,
            uint256 utilizationBps,
            uint256 pendingAmount
        );

    /* ========== MUTATIVE FUNCTIONS ========== */

    function transferFromBuffer(address user, uint256 hypeAmount, uint256 minHYPEOut) external;

    function depositToBuffer(uint256 amount) external payable;

    function treasuryDepositCredit() external payable;

    function repayTreasuryCredit(uint256 amount) external;

    function queueBufferRebalance(uint256 amount, bool fromBuffer) external returns (uint256 rebalanceId);

    function completeBufferRebalance() external payable;

    /* ========== ADMIN FUNCTIONS ========== */

    function setTargetBuffer(uint256 newTarget) external;
    function setLowWaterMark(uint256 newMark) external;
    function setInstantUnstakeFeeRate(uint256 newRate) external;
    function setFeeDistributionBurn(uint256 newBurnBps) external;
    function setTreasury(address newTreasury) external;
    function emergencyClear(bool forceClear) external returns (uint256 amountReturned);
}
