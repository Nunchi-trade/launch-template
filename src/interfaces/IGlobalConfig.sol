// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IL1Read} from "@kinetiq/launch/src/interfaces/IL1Read.sol";

/// @title IGlobalConfig
/// @notice Interface for the Global Config across all Kinetiq markets
interface IGlobalConfig {
    /// @notice Configuration for a market tier (immutable once added)
    /// @param minHypeStake Minimum HYPE stake required for markets at this tier (queried at runtime)
    /// @param supplyCap exLST supply cap for markets at this tier (set at deploy, raised on tier upgrade)
    /// @param name Human-readable tier name (e.g. "HIP-3", "HIP-4")
    struct MarketTier {
        uint256 minHypeStake;
        uint256 supplyCap;
        string name;
    }

    /// @notice Cached config for an HIP-1 token usable to activate a market's L1 account
    /// @param evmContract The token's HyperEVM ERC20 contract (cached from l1Read.tokenInfo).
    ///        For direct-bridge tokens this is the ERC20 the caller transfers. For adapter-bridged
    ///        tokens (e.g., USDC's CoreDepositWallet) this is the HyperCore-linked wrapper —
    ///        informational only; `token` is the actual ERC20 the caller transfers.
    /// @param systemAddress The system address tokens transfer to in order to credit L1 spot
    /// @param evmDecimals weiDecimals + evmExtraWeiDecimals of `evmContract`, precomputed at
    ///        registration. Informational; `decimals` drives the activate floor check.
    /// @param token The ERC20 the caller actually transfers in. Equals `evmContract` for direct
    ///        path; equals `adapter.token()` (resolved once at registration) for adapter path.
    /// @param decimals Decimals of `token` — drives the activate floor check. Equals `evmDecimals`
    ///        for direct path; equals `IERC20Metadata(token).decimals()` (resolved once at
    ///        registration) for adapter path.
    /// @param adapter Vault-style activation adapter (e.g., Circle's CoreDepositWallet) for tokens
    ///        that bridge through a `depositFor(recipient, amount, destinationDex)` shape. Set to
    ///        `address(0)` for direct-bridge tokens.
    /// @param destinationDex Dex argument forwarded to `adapter.depositFor`. Pinned to
    ///        `HIP3L1Write.SPOT_DEX` on the direct path since the field is unused there.
    /// @dev Activation tokens MUST NOT be fee-on-transfer ERC20s — the transferFrom-then-transfer
    ///      pattern in EXManager.activate / HIP3ConfigFacet.depositTokenToSpot assumes the full
    ///      `amount` is delivered. CONFIG_ADMIN must vet tokens before adding.
    struct TokenConfig {
        address evmContract;
        address systemAddress;
        uint8 evmDecimals;
        address token;
        uint8 decimals;
        address adapter;
        uint32 destinationDex;
    }

    /// @notice Pending downward floor mutation for an existing market tier
    /// @param newFloor The new minHypeStake to apply once the delay elapses
    /// @param effectiveAt The block.timestamp after which `applyLowerTierFloor` may be called
    struct PendingTierFloor {
        uint256 newFloor;
        uint256 effectiveAt;
    }

    /// @notice Pre-registered activation token entry passed to `initialize`. Mirrors the per-token
    ///         registration surface: `adapter == address(0)` routes through the direct-bridge path;
    ///         `adapter != address(0)` routes through the vault-adapter path with the given dex.
    /// @param tokenId The HIP-1 token ID
    /// @param adapter Vault-style adapter contract address; `address(0)` for direct-bridge tokens
    /// @param destinationDex Dex ID forwarded to `adapter.depositFor` (ignored when `adapter == 0`,
    ///        pinned to `HIP3L1Write.SPOT_DEX` internally to mark the field as unused)
    struct TokenParams {
        uint32 tokenId;
        address adapter;
        uint32 destinationDex;
    }

    /// @notice The ex wallet admin address. Signs EIP712 payloads authorizing API-wallet rotations
    ///         for every per-market `exStakingManager`, and acts as the protocol attester for
    ///         HyperCore lifecycle state that HyperEVM cannot independently verify — callbacks via
    ///         `EXManager.link()` (HC perpDeploy succeeded) and `EXManager.release()` (HC unwind
    ///         initiated) gate LaunchFeeSplitter dispatch and LIVE-phase unwind finalize respectively.
    function exWalletAdmin() external view returns (address);

    /// @notice The ex treasury address to send withdrawal fees to across all Kinetiq launched HIP3 markets
    function exTreasury() external view returns (address);

    /// @notice The unstake fee rate for withdrawing exLST shares to HYPE once an HIP3 market is live
    function unstakeFeeRate() external view returns (uint256);

    /// @notice The time between queueing to wind down market and actual winding down by operator
    function unwindDelay() external view returns (uint256);

    /// @notice Minimum time (seconds) since `EXManager.link()` was called before `unwind()` may
    ///         finalize from LIVE. Mirrors the Hyperliquid HIP-3 perp-dex unwind cliff
    ///         (~183 days post-perpDeploy). Applies to both operator and recovery paths.
    function minLinkAgeForUnwind() external view returns (uint256);

    /// @notice The protocol fee share in basis points (% of deployer's HIP-3 fee share taken by protocol)
    function protocolFeeShare() external view returns (uint256);

    /// @notice The treasury address that receives the protocol fee share of deployer's HIP-3 fee share
    function protocolFeeTreasury() external view returns (address);

    /// @notice The minimum operator bond amount in wei for deploying a new market
    function minOperatorBond() external view returns (uint256);

    /// @notice The minimum stake amount on per-market LST Routers (in wei)
    function minStakeAmount() external view returns (uint256);

    /// @notice The chunk size for processing blocked withdrawals (in wei)
    function bwqChunkSize() external view returns (uint256);

    /// @notice The max performance bound for per-market OracleManagers
    function maxPerformanceBound() external view returns (uint256);

    /// @notice The deployer wallet address for reward share distribution (receives 70% of reward share)
    function exDeployerWallet() external view returns (address);

    /// @notice The minimum amount of exLST shares required for withdrawal when a market is live
    function minimumWithdrawWhenLive() external view returns (uint256);

    /// @notice Max impact in basis points for fee staking throttle operations
    function stakeFeesMaxImpactBps() external view returns (uint16);

    /// @notice Minimum seconds between fee-staking throttle executions
    function stakeFeesMinIntervalSeconds() external view returns (uint256);

    /// @notice Time horizon in seconds used for fee-staking clearance pacing
    function stakeFeesClearancePeriodSeconds() external view returns (uint256);

    /// @notice Returns full fee-staking throttle config in one read
    /// @return maxImpactBps Max impact in basis points
    /// @return minIntervalSeconds Minimum seconds between executions
    /// @return clearancePeriodSeconds Clearance horizon in seconds
    function stakeFeesThrottleConfig()
        external
        view
        returns (uint16 maxImpactBps, uint256 minIntervalSeconds, uint256 clearancePeriodSeconds);

    /// @notice Initialization parameters for `GlobalConfig.initialize`.
    /// @dev Addresses first, scalars next, dynamic arrays last (calldata layout).
    struct InitParams {
        address globalAdmin;
        address configAdmin;
        address exWalletAdmin;
        address exTreasury;
        address protocolFeeTreasury;
        address exDeployerWallet;
        address l1Read;
        uint256 unstakeFeeRate;
        uint256 unwindDelay;
        uint256 minLinkAgeForUnwind;
        uint256 protocolFeeShare;
        uint256 minOperatorBond;
        uint256 minStakeAmount;
        uint256 bwqChunkSize;
        uint256 maxPerformanceBound;
        uint256 minimumWithdrawWhenLive;
        uint256 tierUpgradeDelay;
        uint16 stakeFeesMaxImpactBps;
        uint256 stakeFeesMinIntervalSeconds;
        uint256 stakeFeesClearancePeriodSeconds;
        MarketTier[] tiers;
        TokenParams[] activationTokens;
    }

    /// @notice Emitted when the ex wallet admin address is updated
    /// @param oldExWalletAdmin The old ex wallet admin address
    /// @param newExWalletAdmin The new ex wallet admin address
    event WalletAdminUpdated(address indexed oldExWalletAdmin, address indexed newExWalletAdmin);

    /// @notice Emitted when the ex treasury address to send withdrawal fees to across all Kinetiq launched HIP3 markets is updated
    /// @param oldExTreasury The old ex treasury address to send withdrawal fees to across all Kinetiq launched HIP3 markets
    /// @param newExTreasury The new ex treasury address to send withdrawal fees to across all Kinetiq launched HIP3 markets
    event TreasuryUpdated(address indexed oldExTreasury, address indexed newExTreasury);

    /// @notice Emitted when the unstake fee rate for withdrawing exLST shares to HYPE is updated
    /// @param oldUnstakeFeeRate The old unstake fee rate for withdrawing exLST shares to HYPE
    /// @param newUnstakeFeeRate The new unstake fee rate for withdrawing exLST shares to HYPE
    event UnstakeFeeRateUpdated(uint256 indexed oldUnstakeFeeRate, uint256 indexed newUnstakeFeeRate);

    /// @notice Emitted when the time between queueing to wind down market and actual winding down by operator is updated
    /// @param oldUnwindDelay The old time between queueing to wind down market and actual winding down by operator
    /// @param newUnwindDelay The new time between queueing to wind down market and actual winding down by operator
    event UnwindDelayUpdated(uint256 indexed oldUnwindDelay, uint256 indexed newUnwindDelay);

    /// @notice Sets the ex wallet admin address
    /// @param _exWalletAdmin The new ex wallet admin address
    function setWalletAdmin(address _exWalletAdmin) external;

    /// @notice Sets the ex treasury address to send withdrawal fees to across all Kinetiq launched HIP3 markets
    /// @dev Should not be set to an ex manager address
    /// @param _exTreasury The new ex treasury address to send withdrawal fees to across all Kinetiq launched HIP3 markets
    function setTreasury(address _exTreasury) external;

    /// @notice Sets the unstake fee rate for withdrawing exLST shares to HYPE once an HIP3 market is live
    /// @param _unstakeFeeRate The new unstake fee rate for withdrawing exLST shares to HYPE once an HIP3 market is live
    function setUnstakeFeeRate(uint256 _unstakeFeeRate) external;

    /// @notice Sets the time between queueing to wind down market and actual winding down by operator
    /// @param _unwindDelay The new time between queueing to wind down market and actual winding down by operator
    function setUnwindDelay(uint256 _unwindDelay) external;

    /// @notice Emitted when the HC-side perp-dex unwind cliff (`minLinkAgeForUnwind`) is updated
    event MinLinkAgeForUnwindUpdated(uint256 indexed oldDelay, uint256 indexed newDelay);

    /// @notice Sets the HC perp-dex unwind cliff (seconds since `EXManager.link()`)
    /// @dev CONFIG_ADMIN_ROLE. Reverts `InvalidMinLinkAgeForUnwind` if `_delay > Constants.MAX_LINK_AGE_FOR_UNWIND`.
    function setMinLinkAgeForUnwind(uint256 _delay) external;

    /// @notice Emitted when the protocol fee share is updated
    event ProtocolFeeShareUpdated(uint256 indexed oldProtocolFeeShare, uint256 indexed newProtocolFeeShare);

    /// @notice Emitted when the protocol fee treasury is updated
    event ProtocolFeeTreasuryUpdated(address indexed oldProtocolFeeTreasury, address indexed newProtocolFeeTreasury);

    /// @notice Emitted when the minimum operator bond is updated
    event MinOperatorBondUpdated(uint256 indexed oldMinOperatorBond, uint256 indexed newMinOperatorBond);

    /// @notice Sets the protocol fee share in basis points
    /// @param _protocolFeeShare The new protocol fee share
    function setProtocolFeeShare(uint256 _protocolFeeShare) external;

    /// @notice Sets the protocol fee treasury address
    /// @param _protocolFeeTreasury The new protocol fee treasury address
    function setProtocolFeeTreasury(address _protocolFeeTreasury) external;

    /// @notice Sets the minimum operator bond amount
    /// @param _minOperatorBond The new minimum operator bond
    function setMinOperatorBond(uint256 _minOperatorBond) external;

    /// @notice Emitted when the minimum stake amount applied to per-market LST Routers is updated
    /// @param oldMinStakeAmount The previous minimum stake amount in HYPE
    /// @param newMinStakeAmount The new minimum stake amount in HYPE
    event MinStakeAmountUpdated(uint256 indexed oldMinStakeAmount, uint256 indexed newMinStakeAmount);

    /// @notice Sets the minimum stake amount on per-market LST Routers
    /// @param _minStakeAmount The new minimum stake amount
    function setMinStakeAmount(uint256 _minStakeAmount) external;

    /// @notice Emitted when the BlockedWithdrawalQueue chunk size is updated
    /// @param oldBwqChunkSize The previous batch size for processing blocked withdrawals
    /// @param newBwqChunkSize The new batch size for processing blocked withdrawals
    event BwqChunkSizeUpdated(uint256 indexed oldBwqChunkSize, uint256 indexed newBwqChunkSize);

    /// @notice Sets the chunk size for processing blocked withdrawals
    /// @param _bwqChunkSize The new chunk size
    function setBwqChunkSize(uint256 _bwqChunkSize) external;

    /// @notice Emitted when the max performance bound applied to per-market OracleManagers is updated
    /// @param oldMaxPerformanceBound The previous max performance bound (BPS)
    /// @param newMaxPerformanceBound The new max performance bound (BPS)
    event MaxPerformanceBoundUpdated(uint256 indexed oldMaxPerformanceBound, uint256 indexed newMaxPerformanceBound);

    /// @notice Sets the max performance bound for per-market OracleManagers
    /// @param _maxPerformanceBound The new max performance bound
    function setMaxPerformanceBound(uint256 _maxPerformanceBound) external;

    /// @notice Emitted when the deployer wallet address used for reward share distribution is updated
    /// @param oldExDeployerWallet The previous deployer wallet
    /// @param newExDeployerWallet The new deployer wallet
    event ExDeployerWalletUpdated(address indexed oldExDeployerWallet, address indexed newExDeployerWallet);

    /// @notice Sets the deployer wallet address for reward share distribution
    function setExDeployerWallet(address _exDeployerWallet) external;

    /// @notice Emitted when the protocol-wide LIVE-phase minimum-withdrawal floor is updated
    /// @param oldMinimum The previous minimum withdrawal amount in exLST shares
    /// @param newMinimum The new minimum withdrawal amount in exLST shares
    event MinimumWithdrawWhenLiveUpdated(uint256 indexed oldMinimum, uint256 indexed newMinimum);

    /// @notice Sets the minimum withdrawal amount when a market is live
    /// @param _minimumWithdrawWhenLive The new minimum withdrawal amount
    function setMinimumWithdrawWhenLive(uint256 _minimumWithdrawWhenLive) external;

    /// @notice Emitted when the fee-staking throttle max impact changes
    event StakeFeesMaxImpactBpsUpdated(uint16 indexed oldValue, uint16 indexed newValue);

    /// @notice Emitted when the fee-staking throttle min-interval changes
    event StakeFeesMinIntervalSecondsUpdated(uint256 indexed oldValue, uint256 indexed newValue);

    /// @notice Emitted when the fee-staking throttle clearance period changes
    event StakeFeesClearancePeriodSecondsUpdated(uint256 indexed oldValue, uint256 indexed newValue);

    /// @notice Sets max impact bps for StakeFeesThrottle
    /// @dev Reverts if `_stakeFeesMaxImpactBps == 0` or `> Constants.MAX_IMPACT_BPS` (20% protocol-wide ceiling).
    function setStakeFeesMaxImpactBps(uint16 _stakeFeesMaxImpactBps) external;

    /// @notice Sets minimum interval for StakeFeesThrottle
    function setStakeFeesMinIntervalSeconds(uint256 _stakeFeesMinIntervalSeconds) external;

    /// @notice Sets clearance period for StakeFeesThrottle
    function setStakeFeesClearancePeriodSeconds(uint256 _stakeFeesClearancePeriodSeconds) external;

    // ═══════════════════════════════════════════════════════════════════════════
    //                          MARKET TIER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════
    //
    // Operator-driven tier changes via `EXManager.queueTierUpgrade` are strict-increase only:
    // the new tier's `minHypeStake` must be strictly greater than the current tier's. EVM
    // `marketTier` is independent of the HIP-3 deployer commitment held on HyperCore — a tier
    // change emits no CoreWriter action — so a downgrade would let EVM withdrawals queue below
    // the L1 floor HyperCore actually enforces, permanently locking late depositors when
    // undelegations are refused.
    //
    // Floor relaxations — when Hyperliquid policy genuinely changes — flow through CONFIG_ADMIN
    // here on GlobalConfig via `queueLowerTierFloor` / `applyLowerTierFloor` /
    // `cancelLowerTierFloor`. The mutation is downward-only on an existing tier's
    // `minHypeStake`, delay-protected, and applies atomically across every market at that tier.
    // Tier IDs and supplyCap are immutable; only the floor mutates. This separates per-market
    // operator upgrades (strict-increase, untrusted operator) from protocol-wide floor
    // adjustments (CONFIG_ADMIN-trusted, externally attested by Hyperliquid policy).
    //

    /// @notice The number of registered market tiers (1-indexed, tier 0 is reserved/invalid)
    function tierCount() external view returns (uint256);

    /// @notice The delay before a queued tier upgrade can be confirmed
    function tierUpgradeDelay() external view returns (uint256);

    /// @notice Returns the market tier configuration for a given tier ID
    function marketTiers(uint256 tier) external view returns (MarketTier memory);

    /// @notice Adds a new market tier (tiers are immutable once added)
    function addTier(string calldata name, uint256 minHypeStake, uint256 supplyCap) external returns (uint256);

    /// @notice Returns the pending floor reduction for a tier, or (0, 0) if none queued
    function pendingTierFloors(uint256 tier) external view returns (uint256 newFloor, uint256 effectiveAt);

    /// @notice Queues a downward mutation of a tier's `minHypeStake`. The new floor takes effect
    ///         only after `tierUpgradeDelay` elapses and `applyLowerTierFloor(tier)` is called.
    ///         Tier IDs and `supplyCap` are immutable; only the floor mutates.
    /// @dev Used to track Hyperliquid policy changes (e.g. HIP-3 minimum stake relaxation) under
    ///      CONFIG_ADMIN trust without re-opening the operator-driven downgrade attack vector.
    ///      Operator-driven tier upgrades on `EXManager.queueTierUpgrade` remain strict-increase;
    ///      this function is the only path for floors to move down. Reverts if a reduction is
    ///      already queued for `tier` (call `cancelLowerTierFloor` first), if `newFloor` is not
    ///      strictly less than the existing floor, not a multiple of 1e10, or below
    ///      `Constants.MIN_OPERATOR_BOND`.
    function queueLowerTierFloor(uint256 tier, uint256 newFloor) external;

    /// @notice Finalizes a queued floor reduction after `tierUpgradeDelay` has elapsed.
    /// @dev CONFIG_ADMIN-only. Mutates `marketTiers(tier).minHypeStake` to the queued value;
    ///      every market at this tier reads the new floor immediately via the existing
    ///      `marketTiers` view. Reverts if no reduction is queued for `tier` or the delay
    ///      hasn't elapsed.
    function applyLowerTierFloor(uint256 tier) external;

    /// @notice Cancels a queued floor reduction before it is applied
    /// @dev CONFIG_ADMIN-only. Reverts if no reduction is queued for `tier`.
    function cancelLowerTierFloor(uint256 tier) external;

    /// @notice Sets the tier upgrade delay
    function setTierUpgradeDelay(uint256 _tierUpgradeDelay) external;

    /// @notice Emitted when a new market tier is added
    /// @param tier The 1-indexed tier ID
    /// @param name Human-readable tier name (e.g. "HIP-3", "HIP-4")
    /// @param minHypeStake Minimum HYPE stake required for markets at this tier
    /// @param supplyCap exLST supply cap for markets deployed at this tier
    event TierAdded(uint256 indexed tier, string name, uint256 minHypeStake, uint256 supplyCap);

    /// @notice Emitted when CONFIG_ADMIN queues a downward floor mutation for a tier
    event TierFloorLowerQueued(uint256 indexed tier, uint256 oldFloor, uint256 newFloor, uint256 effectiveAt);

    /// @notice Emitted when a queued floor reduction is finalized
    event TierFloorLowered(uint256 indexed tier, uint256 oldFloor, uint256 newFloor);

    /// @notice Emitted when CONFIG_ADMIN cancels a queued floor reduction before it is applied
    event TierFloorLowerCancelled(uint256 indexed tier);

    /// @notice Emitted when the tier upgrade delay is updated
    /// @param oldDelay The previous tier upgrade delay
    /// @param newDelay The new tier upgrade delay
    event TierUpgradeDelayUpdated(uint256 indexed oldDelay, uint256 indexed newDelay);

    // ═══════════════════════════════════════════════════════════════════════════
    //                       L1 ACCOUNT ACTIVATION REGISTRY
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice The deployed L1Read contract used by all per-market contracts to read HyperCore state
    function l1Read() external view returns (IL1Read);

    /// @notice Returns the cached config for an activation token (zeroed if not registered).
    ///         Auto-generated getter for the public `activationTokens` mapping; returns the
    ///         destructured tuple of `TokenConfig` fields.
    /// @param tokenId The HIP-1 token ID
    /// @return evmContract Cached HyperEVM ERC20 contract for the token (HyperCore-linked address)
    /// @return systemAddress HyperCore system address that credits the L1 spot balance
    /// @return evmDecimals Cached decimals of `evmContract` (weiDecimals + evmExtraWeiDecimals)
    /// @return token The user-facing ERC20 transferFrom'd at activate time
    /// @return decimals Decimals of `token` — drives the floor check at activate
    /// @return adapter Vault activation adapter; address(0) for direct-bridge tokens
    /// @return destinationDex Forwarded to `adapter.depositFor`; pinned to uint32.max on direct path
    function activationTokens(uint32 tokenId)
        external
        view
        returns (
            address evmContract,
            address systemAddress,
            uint8 evmDecimals,
            address token,
            uint8 decimals,
            address adapter,
            uint32 destinationDex
        );

    /// @notice Returns the list of registered activation token IDs
    function getActivationTokenIds() external view returns (uint32[] memory);

    /// @notice Returns true if `tokenId` is currently registered as an activation token
    function isActivationToken(uint32 tokenId) external view returns (bool);

    /// @notice Updates the L1Read contract address used by per-market contracts
    /// @dev CONFIG_ADMIN_ROLE
    function setL1Read(address _l1Read) external;

    /// @notice Registers an HIP-1 token as a valid market-activation token via the direct-transfer
    ///         bridge path (HYPE / USDH-style assets).
    /// @dev CONFIG_ADMIN_ROLE. Fetches cached metadata from `l1Read.tokenInfo(tokenId)`. Sets
    ///      `token = evmContract`, `decimals = evmDecimals`, `adapter = address(0)`, and pins
    ///      `destinationDex = HIP3L1Write.SPOT_DEX` (field unused on this path).
    ///      Reverts `InvalidTokenInfo` if the token has no HyperEVM ERC20 contract (naturally
    ///      rejects HYPE). Reverts `TokenAlreadyAdded` if already registered. Activation tokens
    ///      MUST NOT charge transfer fees — see `TokenConfig` natspec.
    function addActivationToken(uint32 tokenId) external;

    /// @notice Registers an HIP-1 token as a valid market-activation token via a vault-style adapter
    ///         (e.g., USDC's CoreDepositWallet). The adapter implements `depositFor(recipient,
    ///         amount, destinationDex)` and exposes the actual user-facing underlying ERC20 via
    ///         `token()`; this function caches both in `TokenConfig` so activate-time runs have no
    ///         further staticcalls to the adapter.
    /// @dev CONFIG_ADMIN_ROLE. Fetches HyperCore metadata from `l1Read.tokenInfo(tokenId)`. Calls
    ///      `IActivationAdapter(adapter).token()` (once) to resolve the underlying, then
    ///      `IERC20Metadata(underlying).decimals()` (once) for the floor-check decimals. Reverts
    ///      `InvalidAdapter` if `adapter == 0` or its `token()` returns the zero address.
    ///
    ///      `destinationDex == type(uint32).max` (the Spot sentinel) is permitted on the adapter
    ///      path. Vault adapters such as Circle's `CoreDepositWallet` interpret the Spot sentinel
    ///      as "deposit to recipient on HyperCore Spot directly" — `_depositAndForwardIfDexEnabled`
    ///      takes the else branch (Spot is never a forwarding-enabled dex on Circle's wallet) and
    ///      credits the recipient on Spot without invoking `CoreWriter.sendAsset`. The
    ///      activation-flip required by `bond()` (via `coreUserExists(router)` becoming true) is
    ///      produced equivalently for any destinationDex the adapter accepts, so there is no
    ///      protocol-level reason to forbid the Spot sentinel here. CONFIG_ADMIN remains
    ///      responsible for choosing a destinationDex the registered adapter actually supports.
    /// @param tokenId The HIP-1 token ID
    /// @param adapter Vault-style adapter contract; must implement IActivationAdapter
    /// @param destinationDex Dex ID forwarded to adapter.depositFor (e.g., 0 for Core Perps,
    ///        type(uint32).max for the Core Spot sentinel)
    function addActivationTokenWithAdapter(uint32 tokenId, address adapter, uint32 destinationDex) external;

    /// @notice Removes an HIP-1 token from the activation registry
    /// @dev CONFIG_ADMIN_ROLE. Reverts `TokenNotWhitelisted` if not registered.
    function removeActivationToken(uint32 tokenId) external;

    /// @notice Emitted when the L1Read contract address is updated
    event L1ReadUpdated(address indexed oldL1Read, address indexed newL1Read);

    /// @notice Emitted when an activation token is registered (either path)
    /// @param tokenId The HIP-1 token ID
    /// @param evmContract HyperCore-linked EVM contract from L1Read.tokenInfo
    /// @param systemAddress L1 bridge address derived from tokenId
    /// @param evmDecimals Decimals of evmContract from L1Read
    /// @param token User-facing ERC20 (== evmContract for direct, == adapter.token() for adapter)
    /// @param decimals Decimals of `token`
    /// @param adapter Vault adapter address (zero for direct path)
    /// @param destinationDex Dex ID forwarded to adapter.depositFor (uint32.max on direct path)
    event ActivationTokenAdded(
        uint32 indexed tokenId,
        address evmContract,
        address systemAddress,
        uint8 evmDecimals,
        address token,
        uint8 decimals,
        address adapter,
        uint32 destinationDex
    );

    /// @notice Emitted when an activation token is removed from the registry
    event ActivationTokenRemoved(uint32 indexed tokenId);
}
