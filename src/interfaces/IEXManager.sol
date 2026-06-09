// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPauserRegistry} from "@kinetiq/lst/src/interfaces/IPauserRegistry.sol";
import {IStakingAccountant} from "@kinetiq/lst/src/interfaces/IStakingAccountant.sol";
import {IStakingManager} from "@kinetiq/lst/src/interfaces/IStakingManager.sol";
import {IHIP3StakingManager} from "@kinetiq/launch/src/interfaces/IHIP3StakingManager.sol";
import {IEIP712Verifier} from "@kinetiq/launch/src/interfaces/IEIP712Verifier.sol";
import {IEXLST} from "@kinetiq/launch/src/interfaces/IEXLST.sol";
import {IGlobalConfig} from "@kinetiq/launch/src/interfaces/IGlobalConfig.sol";
import {IBlockedWithdrawalQueue} from "@kinetiq/launch/src/interfaces/IBlockedWithdrawalQueue.sol";
import {IEXGate} from "@kinetiq/launch/src/interfaces/IEXGate.sol";

/// @title IEXManager
/// @notice Interface for the EXManager — manages a single Kinetiq-launched HIP-3/4+ market lifecycle
///
/// ## Market Lifecycle
///   1. activate()        — Bridges an ERC20 quote token (USDC/USDT/USDH) to the per-market
///                          Router's HyperCore spot balance. Factory-only — driven by
///                          EXFactory.activateMarket which pays inline from its caller.
///                          Required before bond() — bond() reverts NotActivated until
///                          L1Read.coreUserExists(router) returns true. Repeatable during
///                          UNBONDED until L1 credits.
///   2. bond()            — Stakes the deployer's HYPE bond (escrowed on the factory at
///                          deployMarket) and transitions UNBONDED → FUNDING. Factory-only —
///                          driven by EXFactory.bondMarket. Bond capital ownership stays with
///                          the deployer: excess shares at bond and the bond return at unwind
///                          flow to the deployer, not the operator.
///   3. deposit()         — Depositors stake HYPE during FUNDING, earning yield immediately
///   4. fund()            — Operator validates ghost LST reserves meet tier's minHypeStake, transitions FUNDING → LAUNCHING
///   5. launch()          — Operator provides wallet admin signature, transitions LAUNCHING → LIVE
///   6. link()            — exWalletAdmin records HC perp-dex coordinates (perpDexId,
///                          collateralTokenId, buybackWallet) and snapshots linkTimestamp once
///                          HC-side perpDeploy succeeds. Re-callable for rotation (linkTimestamp
///                          is sticky). Gate for LFS.split and the LIVE-phase unwind cliff.
///   7. setUnwindPhase()  — Operator (or protocol admin) queues voluntary wind down
///   8. release()         — exWalletAdmin attests HC-side unwind has been initiated. Required
///                          for unwind() to finalize from LIVE on both operator and recovery paths.
///   9. unwind()          — After unwindEligibleAt + (LIVE only) the link cliff, finalizes wind
///                          down and sweeps the bond shares back to the deployer; → WOUND_DOWN
///
/// ## Tier Upgrade Flow (Operator)
///   Tier upgrades are STRICTLY one-directional from the operator's perspective: the new tier
///   must have a strictly greater `minHypeStake` than the current tier. Downgrades and lateral
///   moves at the same floor are forbidden because EVM `marketTier` and HyperCore HIP-3 deployer
///   commitment are independent — a downgrade on EVM would let withdrawals queue below what
///   HyperCore will actually undelegate, locking late depositors behind the L1 floor. Floor
///   relaxations (e.g. Hyperliquid lowering the HIP-3 minimum) are handled out-of-band by
///   CONFIG_ADMIN via `GlobalConfig.queueLowerTierFloor`, which mutates an existing tier's
///   floor atomically across all markets at that tier.
///
///   1. queueTierUpgrade(newTier)     — Queues tier change, starts tierUpgradeDelay clock.
///                                      Reverts if `marketTiers(newTier).minHypeStake <=
///                                      marketTiers(marketTier).minHypeStake`.
///   2. raiseSupplyCapForUpgrade()    — Raises exLST supply cap to new tier's cap during delay window,
///                                      enabling depositors to fund the market to the new tier's minHypeStake.
///                                      Required before confirm if new tier's supply cap > current tier's.
///   3. confirmTierUpgrade()          — After delay, finalizes tier change. If new tier's supply cap >
///                                      current tier's, reverts unless exLST cap matches new tier's cap.
///                                      Always reverts if market doesn't meet the new tier's minHypeStake.
///      OR cancelTierUpgrade()        — After delay, cancels the pending upgrade. Supply cap (if raised) persists.
///
interface IEXManager {
    /// @notice The global config contract across all markets
    function globalConfig() external view returns (IGlobalConfig);

    /// @notice The pauser registry contract
    function pauserRegistry() external view returns (IPauserRegistry);

    /// @notice The ex staking manager contract
    function exStakingManager() external view returns (IHIP3StakingManager);

    /// @notice The ex staking accountant contract
    function exStakingAccountant() external view returns (IStakingAccountant);

    /// @notice The exLST contract
    function exLST() external view returns (IEXLST);

    /// @notice The blocked withdrawal queue contract
    function blockedWithdrawalQueue() external view returns (IBlockedWithdrawalQueue);

    /// @notice The gate contract for deposit/withdrawal access control
    /// @return The gate contract (address(0) if no gating)
    function gate() external view returns (IEXGate);

    enum EXPhase {
        UNBONDED, // Initial state, waiting for operator bond
        FUNDING, // Operator bonded, accepting deposits. Depositors earn yield.
        LAUNCHING, // Funded — operator sets wallet to go LIVE
        LIVE, // Fully operational HIP-3 market
        WOUND_DOWN // Terminated, deployer's bond shares swept back at unwind
    }

    /// @notice Current phase of the ex manager
    /// @return phase The current phase of the ex manager
    function exPhase() external view returns (EXPhase);

    /// @notice The operator bond amount required to bond the ex manager
    function opBond() external view returns (uint256);

    /// @notice The next id for a recipient's withdrawal
    function nextRecipientWithdrawalId(address recipient) external view returns (uint256);

    /// @notice Initialization parameters for EXManager.
    /// @dev Wrapped into a single struct so initialize stays under via-IR's stack-too-deep
    ///      threshold. `recoverer` is protocol-scoped (ProtocolRolesController for forceUnwind
    ///      authority); `enclaver` is per-market, deployer-specified. Only the role grants are
    ///      observable to EXManager — the contract is agnostic to who holds which role.
    struct InitParams {
        // Holder of DEFAULT_ADMIN_ROLE (factory in production; held for transferOperator/transferAdmin/transferEnclaver)
        address admin;
        // Market operator (receives OPERATOR_ROLE)
        address operator;
        // Market deployer — bond capital owner; receives bond shares + excess at bond and bond return on unwind
        address deployer;
        // Protocol-side recoverer (receives RECOVERY_ROLE; gates forceUnwindPhase + admin clause of unwind)
        address recoverer;
        // Market enclaver (receives WALLET_ROLE) — the wallet the deployer designates as the
        // on-chain identifier for whoever drives HyperCore-side API-wallet requests against the
        // off-chain enclave for this market. The enclave authenticates incoming requests against
        // this address via `hasRole(WALLET_ROLE, requester)`. Implementation of the off-chain
        // submitter is the deployer's choice (enclave-backed wallet, MPC, hot key — up to the
        // deployer's security posture). Per-market, per-deployer; rotated via
        // `EXFactory.transferEnclaver`. Passive identifier — does NOT gate any on-chain logic.
        address enclaver;
        // Factory address — sole authorized caller for activate() and bond()
        address factory;
        // PauserRegistry singleton
        address pauserRegistry;
        // Operator bond amount in exLST shares
        uint256 opBond;
        // Protocol GlobalConfig
        address globalConfig;
        // Per-market exLST token
        address exLST;
        // Per-market StakingManagerRouter
        address exStakingManager;
        // Per-market StakingAccountant
        address exStakingAccountant;
        // Per-market ghost LST token (internal accounting)
        address exGhostLST;
        // kHYPE token (LSTState init — kHYPE conversion views)
        address kHYPE;
        // kHYPE staking manager (LSTState init)
        address kHYPEStakingManager;
        // kHYPE staking accountant (LSTState init)
        address kHYPEStakingAccountant;
        // BlockedWithdrawalQueue address
        address blockedWithdrawalQueue;
        // Gate contract (address(0) for no gate)
        address gate;
        // Market tier index (1-indexed; must satisfy 1 <= marketTier <= globalConfig.tierCount())
        uint256 marketTier;
    }

    /// @notice Struct for storing user withdrawals
    struct UserWithdrawal {
        // Withdrawal id on staking manager
        uint256 smid;
        // Staking Manager used for this withdrawal
        IStakingManager stakingManager;
        // Ex manager fee rate to apply in BPS to the withdrawal.
        uint96 feeRate;
    }

    /// @notice The user withdrawal data for a given user and withdrawal id
    function userWithdrawals(address user, uint256 withdrawalId) external view returns (UserWithdrawal memory);

    /// @notice The nonce for the ex manager for uniquely tracking API wallet updates by operator
    function walletNonce() external view returns (uint256);

    /// @notice Returns the amount of HYPE added to the operator auction gas from EVM side for market auctions
    /// @return The amount of HYPE added to the operator auction gas from EVM side
    function operatorAuctionGas() external view returns (uint256);

    /// @notice Returns the timestamp at which the queued unwind becomes eligible to finalize
    /// @dev Set at setUnwindPhase / forceUnwindPhase = block.timestamp + globalConfig.unwindDelay() (snapshotted at queue time)
    /// @return The eligibility timestamp, 0 if no unwind is queued
    function unwindEligibleAt() external view returns (uint256);

    /// @notice Whether the current unwind was initiated by the protocol admin (operator cannot cancel)
    function protocolInitiatedUnwind() external view returns (bool);

    /// @notice The market tier this EXManager is operating at
    function marketTier() external view returns (uint256);

    /// @notice The pending tier for a queued upgrade (0 = no pending upgrade)
    function pendingTier() external view returns (uint256);

    /// @notice The timestamp at which a queued tier upgrade becomes eligible to confirm or cancel
    /// @dev Set at queueTierUpgrade = block.timestamp + globalConfig.tierUpgradeDelay() (snapshotted at queue time)
    function tierUpgradeEligibleAt() external view returns (uint256);

    /// @notice The factory address — sole authorized caller for activate() and bond()
    function factory() external view returns (address);

    /// @notice The deployer of this market — set at init, immutable post-deploy. Owns the bond capital
    ///         (receives excess shares at bond + bond return at unwind).
    function deployer() external view returns (address);

    /// @notice Whether the pending tier upgrade requires a supply cap raise before confirmation
    function tierUpgradeRequiresCapRaise() external view returns (bool);

    /// @notice Snapshot of the pending tier's `minHypeStake` taken at queueTierUpgrade. Compared
    ///         against the live value at confirm time to detect CONFIG_ADMIN-driven floor
    ///         lowering during the delay window. Zero when no upgrade is queued.
    function pendingTierMinHypeStake() external view returns (uint256);

    /// @notice Returns the operator address (first member of OPERATOR_ROLE)
    function operator() external view returns (address);

    /// @notice Returns the enclaver address (first member of WALLET_ROLE) — the on-chain
    ///         identifier the off-chain enclave authenticates HyperCore-side HIP-3 API-wallet
    ///         requests against for this market.
    function enclaver() external view returns (address);

    /// @notice The HyperCore perp-dex ID for this market — set by `link()` after exWalletAdmin
    ///         observes that perpDeploy succeeded on HC. Zero until `link()` is called.
    function perpDexId() external view returns (uint32);

    /// @notice The HC quote-token ID used as collateral / fee asset for this market's perp dex —
    ///         set by `link()`. LFS reads this when dispatching `sendAsset` from the perp dex margin.
    function collateralTokenId() external view returns (uint32);

    /// @notice The off-chain bot wallet that receives the buyback share of perp fees on HC spot.
    ///         Set by `link()`; LFS reads this for the buyback recipient of `split()`. The address
    ///         must be `coreUserExists(...) == true` at link time so the first sendAsset can't be
    ///         silently rerouted to other recipients by HC's recipient-activation behavior.
    function buybackWallet() external view returns (address);

    /// @notice `block.timestamp` snapshotted at the FIRST successful `link()` call; subsequent
    ///         re-links rotate other fields but do not refresh this. Drives the LIVE-phase unwind
    ///         cliff: `unwind()` reverts until
    ///         `block.timestamp >= linkTimestamp + globalConfig.minLinkAgeForUnwind()`.
    ///         Assumes no HC perp-dex migration for this market.
    function linkTimestamp() external view returns (uint256);

    /// @notice True once exWalletAdmin has called `release(true)` to attest that HC-side HIP-3
    ///         unwind has been initiated. Required for `unwind()` finalization from LIVE on both
    ///         operator and recovery paths.
    function coreUnwound() external view returns (bool);

    // ═══════════════════════════════════════════════════════════════════════════
    //                               EVENTS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Emitted when the per-market Router's L1 account is activated via bridging
    ///         an ERC20 quote token (USDC/USDT/USDH) to the Router's HyperCore spot balance.
    /// @param deployer The deployer of this market (immutable owner of bond capital, queried from factory)
    /// @param operator The operator role-holder for this market
    /// @param tokenId The HIP-1 token ID used for activation
    /// @param amount The amount of the token bridged (in EVM units)
    event Activated(address indexed deployer, address indexed operator, uint32 indexed tokenId, uint256 amount);

    /// @notice Emitted when capital is bonded to the ex manager (always called via factory escrow)
    /// @param deployer The deployer of this market (recipient of excess shares + bond return at unwind)
    /// @param operator The operator role-holder for this market
    /// @param shares The amount of exLST shares escrowed for the bond
    event Bonded(address indexed deployer, address indexed operator, uint256 shares);

    /// @notice Emitted when an operator validates ghost LST reserves meet minHypeStake
    /// @param operator The operator that funded the ex manager
    /// @param hypeAmount The HYPE value of ghost LST reserves meeting minHypeStake
    event Funded(address indexed operator, uint256 hypeAmount);

    /// @notice Emitted when an operator launches the HIP-3 market by setting the API wallet
    /// @param operator The operator that launched
    /// @param wallet The wallet address set as the API wallet for the ex staking manager
    event Launched(address indexed operator, address indexed wallet);

    /// @notice Emitted when the API wallet for the ex staking manager is updated
    /// @param operator The operator that updated the API wallet
    /// @param wallet The wallet address set as the API wallet for the ex staking manager
    /// @param walletNonce The nonce for the ex wallet to prevent replay submissions
    event WalletUpdated(address indexed operator, address indexed wallet, uint256 walletNonce);

    /// @notice Emitted when HYPE fees are staked to compound the stake
    event FeesStaked(uint256 amount);

    /// @notice Emitted when HYPE is added to the operator auction gas from EVM side for market auctions
    /// @param operator The operator that added HYPE to the operator auction gas
    /// @param value The amount of HYPE added to the operator auction gas
    event OperatorAuctionGasAdded(address indexed operator, uint256 value);

    /// @notice Emitted when the wind down phase for the ex manager is set or cancelled
    /// @param sender The address that set or cancelled the wind down (operator or protocol admin)
    /// @param unwindEligibleAt The eligibility timestamp at which finalization is allowed (0 if cancelled)
    /// @param isWindingDown True if winding down, false if cancelling
    /// @param forced True if initiated via forceUnwindPhase by protocol admin
    event UnwindPhaseSet(address indexed sender, uint256 unwindEligibleAt, bool isWindingDown, bool forced);

    /// @notice Emitted when the HIP-3 market wind down is finalized
    /// @param sender The msg.sender that finalized the wind down (operator or RECOVERY)
    /// @param deadline The eligibility timestamp at which finalization was allowed
    /// @param blockTimestamp The timestamp when finalization occurred
    /// @param shares The amount of escrowed exLST shares swept to the deployer
    event Unwound(address indexed sender, uint256 deadline, uint256 blockTimestamp, uint256 shares);

    /// @notice Emitted when a user deposits HYPE to the ex manager minting exLST shares
    /// @param sender The depositor
    /// @param recipient The recipient of the exLST shares
    /// @param hypeAmount The amount of HYPE deposited (after 1e10 rounding)
    /// @param shares The amount of exLST shares issued
    event Deposited(address indexed sender, address indexed recipient, uint256 hypeAmount, uint256 shares);

    /// @notice Emitted when a user queues a withdrawal request
    /// @param sender The user that queued the withdrawal
    /// @param recipient The recipient of the HYPE after withdrawal
    /// @param hypeAmount The amount of HYPE expected from available withdrawal
    /// @param hypeFee The amount of HYPE fees for the available withdrawal
    /// @param sharesWithdrawn The amount of exLST shares withdrawn through available withdrawals
    /// @param withdrawalId The withdrawal request ID for available withdrawals
    /// @param blockedShares The amount of exLST shares queued as blocked withdrawals (LIVE only)
    /// @param blockedWithdrawalId The blocked withdrawal ID (0 if no blocked withdrawal)
    event Withdrawn(
        address indexed sender,
        address indexed recipient,
        uint256 hypeAmount,
        uint256 hypeFee,
        uint256 sharesWithdrawn,
        uint256 withdrawalId,
        uint256 blockedShares,
        uint256 blockedWithdrawalId
    );

    /// @notice Emitted when a user confirms a withdrawal request
    /// @param sender The user that confirmed the withdrawal
    /// @param recipient The user that receives the HYPE
    /// @param hypeAmount The amount of HYPE received
    /// @param hypeFee The amount of HYPE fees sent to the treasury
    /// @param withdrawalId The withdrawal request ID
    event WithdrawalConfirmed(
        address indexed sender, address indexed recipient, uint256 hypeAmount, uint256 hypeFee, uint256 withdrawalId
    );

    /// @notice Emitted when a tier upgrade is queued
    event TierUpgradeQueued(uint256 indexed currentTier, uint256 indexed newTier, uint256 timestamp);

    /// @notice Emitted when a tier upgrade is confirmed
    event TierUpgraded(uint256 indexed oldTier, uint256 indexed newTier);

    /// @notice Emitted when a pending tier upgrade is cancelled
    event TierUpgradeCancelled(uint256 indexed cancelledTier);

    /// @notice Emitted when the operator raises the exLST supply cap for a pending tier upgrade
    event SupplyCapRaised(uint256 indexed oldCap, uint256 indexed newCap, uint256 indexed forTier);

    /// @notice Emitted when exWalletAdmin links this market to its HyperCore perp dex via `link()`.
    ///         Re-callable to rotate `perpDexId` / `collateralTokenId` / `buybackWallet`; the stored
    ///         `linkTimestamp` is sticky-on-first-set and not refreshed by subsequent calls.
    /// @param walletAdmin The exWalletAdmin caller that submitted the link
    /// @param perpDexId The HC perp-dex ID
    /// @param collateralTokenId The HC quote-token ID for the perp dex
    /// @param buybackWallet The buyback recipient (must be `coreUserExists`)
    /// @param linkTimestamp The canonical cliff anchor (first-link `block.timestamp`)
    event Linked(
        address indexed walletAdmin,
        uint32 indexed perpDexId,
        uint32 indexed collateralTokenId,
        address buybackWallet,
        uint256 linkTimestamp
    );

    /// @notice Emitted when exWalletAdmin attests HC-side HIP-3 unwind state via `release()`.
    /// @param walletAdmin The exWalletAdmin caller that submitted the attestation
    /// @param coreUnwound True if HC-side unwind has been initiated; false to revoke an earlier attestation
    /// @param blockTimestamp The timestamp at which the attestation was set
    event Released(address indexed walletAdmin, bool coreUnwound, uint256 blockTimestamp);

    // ═══════════════════════════════════════════════════════════════════════════
    //                            FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Activates the per-market Router's L1 account by bridging an ERC20 activation token
    ///         (USDC/USDT/USDH) to its HyperCore spot balance. Must complete (and L1 must process)
    ///         before bond() will succeed.
    /// @dev Overrides the `HyperCoreActivatable.activate` default with EXManager-specific semantics:
    ///      - Auth: factory-only (`msg.sender == factory`); UNBONDED-phase only; pauser-gated.
    ///      - Recipient: forwards the token to the per-market Router via
    ///        `safeTransferFrom(factory, exStakingManager, amount)` then calls
    ///        `exStakingManager.depositTokenToDex(token, amount, systemAddress, adapter, destinationDex)`.
    ///        The Router (not EXManager) is the HC-activated address.
    ///      - Event: emits the richer `Activated(deployer, operator, tokenId, amount)` (4-arg form)
    ///        rather than the base `HyperCoreActivated`.
    ///      - Floor: min-amount enforced upstream in `EXFactory.activateMarket` (per-contract
    ///        floor × 3 contracts orchestrated together); this function only enforces token
    ///        registration via the GlobalConfig lookup.
    ///      Driven by `EXFactory.activateMarket` which pulls the activation token from its caller
    ///      and forwards into this function. Repeatable while UNBONDED if a prior attempt's L1
    ///      bridging didn't credit. Source of truth for "activated" is `coreUserExists(router)` via
    ///      L1Read, surfaced by `activated()` and re-checked in `bond()`. Activation tokens must
    ///      not be fee-on-transfer ERC20s; see `IGlobalConfig.TokenConfig`.
    /// @param tokenId The HIP-1 token ID (must be registered in `globalConfig.activationTokens`)
    /// @param amount The amount of activation token to forward to the Router for HC-bridging
    function activate(uint32 tokenId, uint256 amount) external;

    /// @notice Whether the per-market Router has an existing HyperCore account (true post-activation).
    /// @dev Overrides `HyperCoreActivatable.activated` to return
    ///      `coreUserExists(exStakingManager)` instead of `coreUserExists(address(this))` —
    ///      EXManager itself never calls CoreWriter; the Router does, and the Router's account is
    ///      what `EXFactory.bondMarket` needs to gate on. Off-chain bots also use this view to
    ///      pre-flight before driving the activate → bond lifecycle.
    /// @return True if the per-market Router's HC spot account exists, false otherwise.
    function activated() external view returns (bool);

    /// @notice Bonds capital to the ex manager, transitioning from UNBONDED to FUNDING
    /// @dev Factory-only (msg.sender == factory), UNBONDED phase. Driven by
    ///      EXFactory.bondMarket which forwards the deployer's escrowed opBond HYPE as
    ///      msg.value. Bond capital ownership stays with the deployer: shares - opBond
    ///      excess sweeps to the deployer here, and the opBond shares are also swept to
    ///      the deployer at unwind. Reverts `NotActivated` if the per-market Router's L1
    ///      account has not been activated yet.
    /// @return shares The amount of exLST shares minted for the bonded HYPE
    function bond() external payable returns (uint256 shares);

    /// @notice Validates ghost LST reserves meet minHypeStake, transitioning from FUNDING to LAUNCHING
    /// @dev Only callable in FUNDING phase by OPERATOR_ROLE
    /// @return hypeAmount The HYPE value of ghost LST reserves
    function fund() external returns (uint256 hypeAmount);

    /// @notice The data for a wallet
    struct WalletData {
        address exStakingManager; // The ex staking manager address to set the API wallet for
        address exWallet; // The ex wallet address to set as the API wallet
        uint256 walletNonce; // The nonce for the ex wallet to prevent replay submissions
    }

    /// @notice Sets the API wallet and transitions from LAUNCHING to LIVE
    /// @dev Only callable in LAUNCHING phase by OPERATOR_ROLE
    /// @param walletSignedData EIP712 signed wallet data from wallet admin
    /// @return wallet The API wallet address set
    function launch(IEIP712Verifier.EIP712SignedData memory walletSignedData) external returns (address wallet);

    /// @notice Updates the API wallet for the ex staking manager
    /// @dev Callable in LIVE or WOUND_DOWN phase by `globalConfig.exWalletAdmin` (always) or any
    ///      holder of OPERATOR_ROLE (only while no unwind is queued — the operator-relay branch
    ///      is frozen during the unwind window so emergency rotation stays exclusively with the
    ///      wallet admin). The wallet admin's EIP712 signature on walletSignedData is required
    ///      regardless of submitter — only the wallet admin can authorize the destination wallet.
    /// @param walletSignedData EIP712 signed wallet data from wallet admin
    /// @return wallet The new API wallet address
    function updateWallet(IEIP712Verifier.EIP712SignedData memory walletSignedData) external returns (address wallet);

    /// @notice Deposits HYPE, staking to exStakingManager for ghost LST, minting exLST shares
    /// @dev Callable in FUNDING, LAUNCHING, LIVE phases. msg.value is HYPE to deposit.
    /// @dev Rounds down to 1e10, refunds dust to sender.
    /// @param recipient The recipient of the exLST shares
    /// @param data Gate data to pass through to gate hooks
    /// @return shares The amount of exLST shares issued
    function deposit(address recipient, bytes memory data) external payable returns (uint256 shares);

    /// @notice Withdraws exLST shares by queuing ghost LST withdrawal on exStakingManager
    /// @dev Callable in FUNDING, LIVE, WOUND_DOWN phases. Fee applied in all phases.
    /// @dev In LIVE phase, excess shares route to blocked withdrawal queue.
    /// @dev In LIVE phase, aggregate `shares` must be >= globalConfig.minimumWithdrawWhenLive().
    ///      The blocked-withdrawal residual is gated against the same floor in any phase to
    ///      keep BWQ entries economical and to prevent the aggregate gate from being bypassed
    ///      via `shares = available + dust`. WOUND_DOWN dust exits remain reachable: once
    ///      processBlockedWithdrawals drains the BWQ FIFO, the immediate leg handles small
    ///      withdrawals without routing to BWQ at all.
    /// @param shares The amount of exLST shares to withdraw
    /// @param recipient The recipient of the HYPE after withdrawal confirmation
    /// @param data Gate data to pass through to gate hooks
    /// @return hypeAmount HYPE expected from available withdrawal
    /// @return hypeFee HYPE fees for the available withdrawal
    /// @return withdrawalId Withdrawal request ID for available withdrawals
    /// @return blockedShares exLST shares queued as blocked withdrawals (LIVE + WOUND_DOWN)
    /// @return blockedWithdrawalId Blocked withdrawal ID (0 if none)
    function withdraw(uint256 shares, address recipient, bytes memory data)
        external
        returns (
            uint256 hypeAmount,
            uint256 hypeFee,
            uint256 withdrawalId,
            uint256 blockedShares,
            uint256 blockedWithdrawalId
        );

    /// @notice Confirms a withdrawal request to receive HYPE
    /// @param withdrawalId The user's withdrawal id
    /// @param recipient The recipient to claim the withdrawal for
    /// @return hypeAmount HYPE received by recipient
    /// @return hypeFee HYPE fees sent to treasury
    function confirmWithdrawal(uint256 withdrawalId, address recipient)
        external
        returns (uint256 hypeAmount, uint256 hypeFee);

    /// @notice Stakes HYPE fees without minting exLST (compounds stake into reserve)
    /// @dev Callable in LIVE and WOUND_DOWN phases. WOUND_DOWN support lets the fee throttle
    ///      distribute residual buyback HYPE pro-rata to remaining holders after wind-down.
    function stakeFees() external payable;

    /// @notice Adds HYPE to operator auction gas for market auctions
    /// @dev Only callable in LIVE phase by OPERATOR_ROLE. If Core spot top-up is genuinely needed
    ///      during wind-down, the RECOVERY_ROLE holder can send HYPE to the Router directly as
    ///      an escape hatch.
    function addOperatorAuctionGas() external payable;

    /// @notice Operator queues or cancels voluntary wind down (FUNDING, LAUNCHING, or LIVE phase)
    /// @dev Only callable by OPERATOR_ROLE from any active phase. FUNDING supports the case where
    ///      the market doesn't raise enough HYPE to launch. LAUNCHING supports the case
    ///      where the wallet admin is unresponsive. Operator cannot cancel a protocol-initiated unwind.
    /// @param isWindingDown True to queue, false to cancel
    function setUnwindPhase(bool isWindingDown) external;

    /// @notice Protocol-side forces unwind from any active phase (FUNDING, LAUNCHING, LIVE)
    /// @dev Only callable by holders of RECOVERY_ROLE. Operator cannot cancel a force-unwind.
    ///      May be called while an operator-initiated unwind is pending to convert it to a
    ///      protocol-initiated one; the existing eligibility timestamp is preserved so depositors
    ///      already waiting on the operator's clock are not pushed onto a fresh delay. Cannot
    ///      re-queue an already-protocol-initiated unwind.
    /// @param isWindingDown True to queue forced unwind, false to cancel
    function forceUnwindPhase(bool isWindingDown) external;

    /// @notice Finalizes wind down after unwindDelay has passed
    /// @dev Callable by holders of OPERATOR_ROLE (market operator) or RECOVERY_ROLE (protocol-side).
    ///      Unwind must have been queued via setUnwindPhase or forceUnwindPhase.
    function unwind() external;

    /// @notice Returns the HYPE amount equivalent to a given amount of exLST shares
    /// @param shares The amount of exLST shares
    /// @return hypeAmount The HYPE amount equivalent to the given amount of exLST shares
    function EXLSTToHYPE(uint256 shares) external view returns (uint256 hypeAmount);

    /// @notice Returns the exLST shares equivalent to a given amount of HYPE
    /// @param hypeAmount The amount of HYPE
    /// @return shares The exLST shares equivalent to the given amount of HYPE
    function HYPEToEXLST(uint256 hypeAmount) external view returns (uint256 shares);

    /// @notice Returns the available exLST shares for withdrawal (not through blocked queue)
    /// @return availableShares The available exLST shares for withdrawal given current phase
    function availableWithdrawals() external view returns (uint256 availableShares);

    /// @notice Queues a tier change (subject to tierUpgradeDelay)
    /// @dev Strict-increase only — the new tier's `minHypeStake` MUST be strictly greater than
    ///      the current tier's; downgrades and same-floor lateral moves revert with
    ///      `Errors.InvalidTier`. EVM `marketTier` is an independent bookkeeping from the
    ///      HIP-3 deployer commitment held on HyperCore (a tier change emits no CoreWriter
    ///      action), so a downgrade would let EVM withdrawals queue below the L1 floor that
    ///      HyperCore actually enforces, permanently locking late depositors when undelegations
    ///      are refused. Floor relaxations belong to CONFIG_ADMIN on
    ///      `GlobalConfig.queueLowerTierFloor`, which mutates an existing tier's floor
    ///      atomically across all markets at that tier. Does NOT raise supply cap — operator
    ///      must explicitly call `raiseSupplyCapForUpgrade()` during the delay window if the
    ///      new tier has a higher cap.
    /// @param newTier The tier to upgrade to (must exist, must differ from current tier, must
    ///        have a strictly greater minHypeStake than the current tier)
    function queueTierUpgrade(uint256 newTier) external;

    /// @notice Raises exLST supply cap to the pending tier's cap (increase only)
    /// @dev Can only be called while a tier upgrade is queued. Opens headroom for depositors
    ///      to fund the market to the new tier's minHypeStake during the delay window.
    function raiseSupplyCapForUpgrade() external;

    /// @notice Confirms a queued tier upgrade after the delay has passed
    /// @dev If tierUpgradeRequiresCapRaise is true, reverts unless exLST supply cap matches
    ///      the new tier's cap (operator must call raiseSupplyCapForUpgrade first). Always reverts
    ///      if market doesn't meet the new tier's minHypeStake requirement.
    ///
    ///      Reverts `InvalidTier` if `globalConfig.marketTiers(pendingTier).minHypeStake` no
    ///      longer matches the value snapshotted into `pendingTierMinHypeStake` at queue time.
    ///      GlobalConfig only permits LOWERING a tier's floor (`queueLowerTierFloor` enforces
    ///      `newFloor < existing.minHypeStake`), so any drift means CONFIG_ADMIN lowered the
    ///      target floor during the delay window and the upgrade is now smaller than what the
    ///      operator queued — possibly a lateral move or downgrade vs the current tier, which
    ///      would let immediate-withdrawal capacity drop below the original HyperCore commitment.
    ///      Operator must `cancelTierUpgrade` and re-queue against the new floor if still desired.
    function confirmTierUpgrade() external;

    /// @notice Cancels a pending tier upgrade after the delay has passed
    function cancelTierUpgrade() external;

    /// @notice Links this market to its HyperCore perp dex once exWalletAdmin observes that
    ///         HC-side perpDeploy succeeded. Sets `perpDexId`, `collateralTokenId`, `buybackWallet`,
    ///         and snapshots `linkTimestamp` on the FIRST call (subsequent re-links rotate the
    ///         other fields but do NOT refresh `linkTimestamp`).
    /// @dev LIVE-only, pauser-gated. Re-callable by exWalletAdmin to rotate the rotatable fields.
    ///      Reverts `AlreadyReleased` if `coreUnwound` is already set (link must precede release).
    ///      NOT gated by `_checkNotUnwinding()` — link must be reachable mid-unwind to satisfy
    ///      finalize gates if operator queued unwind w/o prior link. Auth: `msg.sender ==
    ///      globalConfig.exWalletAdmin()` (mirrors `updateWallet` direct-check pattern; not
    ///      routed through ProtocolRolesController).
    /// @param _dexId The HC perp-dex ID (must be non-zero; HIP-3 dexes start at 1)
    /// @param _collateralTokenId HC quote-token ID (must be registered as an activation token)
    /// @param _buybackWallet Buyback recipient (must satisfy `l1Read.coreUserExists`)
    function link(uint32 _dexId, uint32 _collateralTokenId, address _buybackWallet) external;

    /// @notice Attests HC-side HIP-3 unwind state — gates `unwind()` finalize from LIVE for
    ///         BOTH operator and recovery paths.
    /// @dev LIVE-only, pauser-gated. Requires `link()` to have fired (`linkTimestamp != 0`) and
    ///      an unwind queued (`unwindEligibleAt != 0`). Idempotent / toggleable until `unwind()`
    ///      finalizes — exWalletAdmin can flip back to false if HC state changes mid-unwind.
    ///      Auth: `msg.sender == globalConfig.exWalletAdmin()`.
    /// @param _coreUnwound True if HC-side perp-dex unwind has been initiated
    function release(bool _coreUnwound) external;
}
