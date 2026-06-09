// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEXDeployer} from "@kinetiq/launch/src/interfaces/IEXDeployer.sol";
import {IGlobalConfig} from "@kinetiq/launch/src/interfaces/IGlobalConfig.sol";
import {IFacetRegistry} from "@kinetiq/lst/src/interfaces/IFacetRegistry.sol";
import {IPauserRegistry} from "@kinetiq/launch/src/interfaces/IPauserRegistry.sol";

/// @title IEXFactory
/// @notice Interface for the EXFactory that deploys and manages HIP-3 markets.
/// @dev Three-phase deploy lifecycle:
///        deployMarket   — payable; escrows opBond HYPE in factory, provisions the per-market
///                         contract suite, snapshots cancelEligibleAt for the cancel time-lock
///        activateMarket — permissionless; bridges activation token (e.g. USDH) to the
///                         per-market Router's HyperCore spot balance via EXManager.activate
///        bondMarket     — deployer-only; forwards escrowed opBond HYPE to EXManager.bond,
///                         transitioning the market UNBONDED → FUNDING
///      Pre-bond exit:
///        cancelMarket   — deployer-only; time-locked until cancelEligibleAt; refunds escrowed
///                         HYPE and removes PauserRegistry + FacetRegistry entries
interface IEXFactory {
    /// @notice The per-market suite deployer (BeaconProxy + plain oracle instances). Extracted
    ///         from the factory to keep EXFactory under the EIP-170 24,576-byte runtime cap.
    ///         Its `beaconRegistry()` getter is the canonical source for the beacon registry.
    function exDeployer() external view returns (IEXDeployer);

    /// @notice The shared protocol-level global config
    function globalConfig() external view returns (IGlobalConfig);

    /// @notice The shared facet registry for all per-market StakingManagerRouters
    function facetRegistry() external view returns (IFacetRegistry);

    /// @notice The ProtocolRolesController address all markets deployed by this factory point to
    function protocolRolesController() external view returns (address);

    /// @notice The shared pauser registry singleton
    function pauserRegistry() external view returns (IPauserRegistry);

    /// @notice The kHYPE token address (used for per-market LSTState initialization)
    function kHYPE() external view returns (address);

    /// @notice The kHYPE staking manager address
    function kHYPEStakingManager() external view returns (address);

    /// @notice The kHYPE staking accountant address
    function kHYPEStakingAccountant() external view returns (address);

    /// @notice The kHYPE validator manager address (used to validate active validators)
    function kHYPEValidatorManager() external view returns (address);

    /// @notice The HYPE token ID on L1
    function hypeTokenId() external view returns (uint64);

    /// @notice Maps an EXManager address to its market ID (bytes32(0) if not a factory-deployed market)
    function exManagerToMarketId(address exManager) external view returns (bytes32);

    /// @notice Parameters for deploying a new HIP-3 market
    /// @param admin Address with authority to transfer the operator + enclaver (e.g. multisig)
    /// @param operator Address to receive OPERATOR_ROLE on the EXManager
    /// @param enclaver Address to receive WALLET_ROLE on the EXManager — off-chain identifier the enclave authenticates HIP-3 API-wallet requests against for this market
    /// @param opBond Intended operator bond amount (must be >= globalConfig.minOperatorBond())
    /// @param validator L1 validator address to delegate to
    /// @param gate Optional gate contract address (address(0) = no gate)
    /// @param lstName Name for the market's exLST token (e.g. "Kinetiq Markets LST")
    /// @param lstSymbol Symbol for the market's exLST token (e.g. "kmHYPE")
    /// @param marketTier Market tier index (1-indexed, determines minHypeStake + supplyCap)
    /// @param hyperCoreDeployer HC-side ticker owner stored on EXLST for the Path-2 linker; must be non-zero (pass `msg.sender` if same as EVM deployer)
    /// @param deployerTreasury Destination wallet for this market's deployer fee share in LaunchFeeSplitter
    /// @param buybackBps Buyback share in basis points for this market's launch fee splitter
    struct MarketParams {
        address admin;
        address operator;
        address enclaver;
        uint256 opBond;
        address validator;
        address gate;
        string lstName;
        string lstSymbol;
        uint256 marketTier;
        address hyperCoreDeployer;
        address deployerTreasury;
        uint64 buybackBps;
    }

    /// @notice Information about a deployed market plus its escrow lifecycle state.
    ///         Combines static identity (deployer/exManager/nonce — set at deploy) with mutable
    ///         lifecycle state (admin/operator transferable; opBondEscrowed/cancelEligibleAt/bonded
    ///         driven by deployMarket → bondMarket / cancelMarket).
    /// @param deployer Address that deployed the market (msg.sender at deployMarket; immutable)
    /// @param admin Address with authority to transfer the operator + enclaver (mutable via transferAdmin)
    /// @param operator Current operator address (mutable via transferOperator)
    /// @param enclaver Current WALLET_ROLE holder (mutable via transferEnclaver — distinct from
    ///        transferAdmin/transferOperator since this address gates off-chain enclave
    ///        authentication, not on-chain control)
    /// @param nonce Deployer's nonce at time of deployment
    /// @param exManager Address of the market's EXManager proxy
    /// @param opBondEscrowed HYPE currently escrowed for the bond; cleared on bond (set 0) or cancel (entry deleted)
    /// @param cancelEligibleAt block.timestamp at deploy + globalConfig.unwindDelay() snapshot;
    ///        cancelMarket is time-locked until block.timestamp >= this value
    /// @param bonded True after bondMarket succeeds; gates bondMarket re-entry and cancelMarket
    struct MarketInfo {
        address deployer;
        address admin;
        address operator;
        address enclaver;
        uint256 nonce;
        address exManager;
        uint256 opBondEscrowed;
        uint256 cancelEligibleAt;
        bool bonded;
    }

    /// @notice All per-market contract addresses deployed by the factory
    struct MarketContracts {
        address router;
        address exManager;
        address exLST;
        address stakingAccountant;
        address validatorManager;
        address oracleManager;
        address rewardShareTracker;
        address ghostLST;
        address bwq;
        address defaultOracle;
        address oracleAdapter;
        address launchFeeSplitter;
        address stakeFeesThrottle;
    }

    /// @notice Emitted when a new market is deployed (includes the escrowed opBond + cancel-eligibility timestamp)
    event MarketDeployed(
        bytes32 indexed marketId,
        address indexed deployer,
        address indexed exManager,
        MarketContracts contracts,
        uint256 opBondEscrowed,
        uint256 cancelEligibleAt
    );

    /// @notice Emitted when activateMarket bridges activation tokens for a market
    event MarketActivated(bytes32 indexed marketId, address indexed caller, uint32 indexed tokenId, uint256 amount);

    /// @notice Emitted when bondMarket finalizes the bond on a market's EXManager
    event MarketBonded(bytes32 indexed marketId, address indexed deployer, uint256 opBond);

    /// @notice Emitted when cancelMarket refunds and tears down a pre-bond market
    /// @param marketId The market ID being cancelled
    /// @param deployer The deployer that initiated the cancel
    /// @param recipient The address the HYPE refund was sent to (deployer-specified)
    /// @param hypeRefund The HYPE amount refunded
    event MarketCancelled(
        bytes32 indexed marketId, address indexed deployer, address indexed recipient, uint256 hypeRefund
    );

    /// @notice Emitted when a market's operator is transferred
    event OperatorTransferred(bytes32 indexed marketId, address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when a market's admin is transferred
    event AdminTransferred(bytes32 indexed marketId, address indexed oldAdmin, address indexed newAdmin);

    /// @notice Emitted when a market's enclaver (WALLET_ROLE holder) is rotated via transferEnclaver
    event EnclaverTransferred(bytes32 indexed marketId, address indexed oldEnclaver, address indexed newEnclaver);

    /// @notice Deploys a full per-market HIP-3 contract suite and escrows the operator bond
    /// @param params Market deployment parameters
    /// @dev Phase 1 of the 3-phase lifecycle. Payable: msg.value MUST equal params.opBond and
    ///      params.opBond MUST be >= globalConfig.minOperatorBond(). The bond HYPE is escrowed
    ///      on the factory until either bondMarket forwards it to EXManager.bond or
    ///      cancelMarket refunds it to the deployer. The market is left in the EXManager
    ///      UNBONDED phase — activateMarket and bondMarket complete the launch.
    ///      Snapshots cancelEligibleAt = block.timestamp + globalConfig.unwindDelay() so the
    ///      cancel time-lock is symmetric with the bond+unwind exit cost (and immune to
    ///      mid-flight changes to globalConfig.unwindDelay).
    ///      Deploys BeaconProxy contracts for per-market upgradeable components + 2 oracle
    ///      contracts (DefaultOracle, OracleAdapter)
    ///      with full initialization, cross-wiring, and role transfers to ProtocolRolesController
    ///      in a single tx. Measured cost on the kHYPE mainnet fork: ~14.06M gas first market,
    ///      ~13.98M warm — well under the HyperEVM 30M block gas limit. ~800k of the per-market
    ///      cost is ProtocolRolesController wiring (admin/manager/operator/treasury/sentinel
    ///      role grants on LST infra plus the per-market MarketContracts mapping the
    ///      controller's resolver reads). The caller (msg.sender) becomes the market deployer
    ///      and bond owner — bond shares + bond return at unwind flow back to msg.sender.
    ///      Bond shares are exLST (ERC20) so any address can receive them. The HYPE refund on
    ///      `cancelMarket`, however, is a native transfer — the deployer specifies the refund
    ///      `recipient` at cancel time, so a contract-deployer without a payable receive can still
    ///      route the refund to an EOA.
    ///      The params.admin address (e.g. multisig) controls operator role transfers via
    ///      transferOperator().
    /// @return marketId Unique identifier for the market (keccak256(deployer, nonce))
    /// @return exManager Address of the deployed EXManager proxy
    function deployMarket(MarketParams calldata params) external payable returns (bytes32 marketId, address exManager);

    /// @notice Activates a market's L1 account by bridging an activation token (e.g. USDH) to HyperCore
    /// @dev Permissionless — anyone can call. Caller pays inline: must approve activation token to factory
    ///      before calling. Naturally retryable: if first attempt's L1 bridge doesn't credit, anyone can
    ///      call again with a fresh approval. Reverts if market is already bonded (post-bond, no need
    ///      to re-activate). `amount` is distributed pro-rata across `activationTargets(marketId)`
    ///      using the per-contract `minAmounts` weights; must satisfy
    ///      `amount >= totalRequired * 10**token.decimals`. Any mulDiv rounding dust is refunded
    ///      to msg.sender.
    /// @param marketId Market to activate
    /// @param tokenId HIP-1 token ID to bridge (must be in globalConfig's activation registry)
    /// @param amount Amount of activation token (in EVM units; >= `totalRequired * 10**decimals`)
    function activateMarket(bytes32 marketId, uint32 tokenId, uint256 amount) external;

    /// @notice Finalizes a market's bond by forwarding the escrowed opBond HYPE to EXManager.bond()
    /// @dev Deployer-only — they escrowed the bond and own the bond shares (returned at unwind).
    ///      Reverts if already bonded or if L1 activation hasn't completed (EXManager.bond reads
    ///      coreUserExists). Excess shares (shares - opBond) sweep to the deployer inside EXManager.bond.
    /// @param marketId Market to bond
    function bondMarket(bytes32 marketId) external;

    /// @notice Cancels a pre-bond market and refunds the escrowed HYPE to a deployer-specified recipient
    /// @dev Deployer-only. Time-locked: requires block.timestamp >= cancelEligibleAt (snapshotted at
    ///      deploy from globalConfig.unwindDelay()) — symmetric with bond+unwind exit cost. Cleans
    ///      PauserRegistry + FacetRegistry entries. Activation token (if anyone called activateMarket)
    ///      was bridged to L1 and is unrecoverable.
    ///      `recipient` is the HYPE refund address; the deployer specifies it explicitly so a
    ///      contract-deployer that lacks a payable receive can route the refund to an EOA. `recipient`
    ///      must be non-zero.
    /// @param marketId Market to cancel
    /// @param recipient Address to receive the HYPE refund (must be non-zero, must be able to receive HYPE)
    function cancelMarket(bytes32 marketId, address recipient) external;

    /// @notice Transfers the operator role of a market to a new address
    /// @dev Only callable by the market admin
    /// @param marketId The market to transfer
    /// @param newOperator The new operator address
    function transferOperator(bytes32 marketId, address newOperator) external;

    /// @notice Transfers the admin role of a market to a new address
    /// @dev Only callable by the current market admin
    /// @param marketId The market to transfer
    /// @param newAdmin The new admin address
    function transferAdmin(bytes32 marketId, address newAdmin) external;

    /// @notice Rotates the WALLET_ROLE holder (enclaver) on a market's EXManager
    /// @dev Only callable by the current market admin. Atomically revokes WALLET_ROLE from the
    ///      old enclaver and grants it to `newEnclaver` (factory retains DEFAULT_ADMIN_ROLE on
    ///      EXManager for this) and updates the cached `MarketInfo.enclaver`. Does NOT affect
    ///      on-chain control; the enclaver address is the off-chain enclave's authentication
    ///      identifier for this market's HyperCore HIP-3 API-wallet requests.
    /// @param marketId The market to transfer
    /// @param newEnclaver The new enclaver address
    function transferEnclaver(bytes32 marketId, address newEnclaver) external;

    /// @notice Returns market info for a given market ID
    /// @param marketId The market ID to query
    /// @return info The market information
    function getMarket(bytes32 marketId) external view returns (MarketInfo memory info);

    /// @notice Returns the full per-market contract suite addresses for a given market ID
    /// @param marketId The market ID to query
    /// @return contracts The per-market contract addresses (router, exManager, exLST, etc.)
    function getMarketContracts(bytes32 marketId) external view returns (MarketContracts memory contracts);

    /// @notice Returns all market IDs deployed by a given address
    /// @param deployer The deployer address to query
    /// @return marketIds Array of market IDs
    function getMarketsByDeployer(address deployer) external view returns (bytes32[] memory marketIds);

    /// @notice Returns the current nonce for a deployer
    /// @param deployer The deployer address
    /// @return nonce The current nonce
    function deployerNonce(address deployer) external view returns (uint256 nonce);

    /// @notice Computes the market ID for a deployer and nonce
    /// @param deployer The deployer address
    /// @param nonce The deployment nonce
    /// @return The market ID
    function marketId(address deployer, uint256 nonce) external pure returns (bytes32);

    /// @notice Predicts the 13 per-market contract addresses that `deployer`'s NEXT call to
    ///         `deployMarket` will produce.
    /// @dev Convenience wrapper over `exDeployer.predictDeployment(...)`: reads the deployer's
    ///      current nonce, derives the next `marketId`, and asks the deployer to compute the
    ///      CREATE2 addresses. Used by operators pre-binding gates to their future EXManager
    ///      address. Front-run-immune from other deployers' actions (their nonce is independent).
    function predictNextDeployment(address deployer) external view returns (MarketContracts memory);

    /// @notice Returns whether an address is a factory-deployed EXManager
    /// @param exManager The address to check
    /// @return True if the address is a registered market
    function isMarket(address exManager) external view returns (bool);

    /// @notice Returns the per-market HC-activated contract set + per-contract minimum activation
    ///         amounts (whole token units; decimals applied at call site) + precomputed sum.
    /// @dev Used by `activateMarket` to drive weighted pro-rata distribution under a single
    ///      aggregate strict-equality check. Exposed publicly so EXRouter / off-chain UX can
    ///      surface the per-market activation budget without re-deriving it. Reverts
    ///      `MarketNotFound` if `marketId` is unknown.
    /// @param marketId The market identifier
    /// @return ctrts The HC-activated contracts (EXManager, LaunchFeeSplitter, StakeFeesThrottle)
    /// @return minAmounts Per-contract minimum activation amounts (whole token units)
    /// @return totalRequired Sum of `minAmounts` — drives the strict-equality check in `activateMarket`
    function activationTargets(bytes32 marketId)
        external
        view
        returns (address[] memory ctrts, uint256[] memory minAmounts, uint256 totalRequired);
}
