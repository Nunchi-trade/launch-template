// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";

/// @title IProtocolRolesController
/// @notice Interface for the ProtocolRolesController that holds protocol roles on factory-deployed market infrastructure
interface IProtocolRolesController {
    /// @notice Per-market component types whose AccessControl roles the controller holds.
    ///         Storage and function signatures use `uint8` for forward compatibility; new types
    ///         append at the end. Cast at call sites: `uint8(Component.Router)`.
    enum Component {
        Router, // 0 — KIP-2 router (facet selectors dispatch through fallback)
        EXLST, // 1 — admin only; mint/burn stay with EXManager
        StakingAccountant, // 2
        ValidatorManager, // 3
        OracleManager, // 4
        RewardShareTracker, // 5
        GhostLST, // 6 — admin only; mint/burn stay with Router
        DefaultOracle, // 7
        EXManager, // 8 — recovery-only (forceUnwindPhase, unwind); operator/admin stay outside controller
        LaunchFeeSplitter, // 9
        StakeFeesThrottle // 10
    }

    /* ========== ROLES ========== */

    /// @notice Wiring, role-admin, allowlist mutation; the ultimate authority on the controller
    function PROTOCOL_ADMIN_ROLE() external view returns (bytes32);

    /// @notice Bounded configuration (buffers, limits, oracle params, validator activation, etc.)
    function PROTOCOL_MANAGER_ROLE() external view returns (bytes32);

    /// @notice Bot operations (L1 ops, withdrawal confirmation, oracle updates, reward distribution)
    function PROTOCOL_OPERATOR_ROLE() external view returns (bytes32);

    /// @notice Rare/high-value treasury operations (rescueToken, withdrawTokenFromSpot)
    function PROTOCOL_TREASURY_ROLE() external view returns (bytes32);

    /// @notice Emergency operations (resetL1OperationsQueue, executeEmergencyWithdrawal)
    function PROTOCOL_RECOVERY_ROLE() external view returns (bytes32);

    /* ========== STATE ========== */

    /// @notice Factory used to resolve per-market component addresses at execute time
    function factory() external view returns (IEXFactory);

    /// @notice Returns the protocol role required to call (component, selector); bytes32(0) means not allowed
    /// @param component One of `Component` enum values cast to uint8
    /// @param selector 4-byte function selector on the target component
    function roleForSelector(uint8 component, bytes4 selector) external view returns (bytes32);

    /// @notice The expected `keccak256(args)` for (component, selector); bytes32(0) means no pin
    ///         and any args are accepted (subject to the role check). When non-zero, `execute`
    ///         requires `keccak256(data[4:]) == this value`.
    /// @dev bytes32(0) is the "no pin" sentinel — finding args whose keccak256 hashes to
    ///      bytes32(0) is a preimage attack on keccak256 (computationally infeasible). Same
    ///      cryptographic assumption as `roleForSelector == bytes32(0)` meaning "no entry".
    function dataForSelector(uint8 component, bytes4 selector) external view returns (bytes32);

    /* ========== EVENTS ========== */

    /// @notice Emitted when execute() forwards a call to a per-market component
    /// @param caller The address holding the required protocol role
    /// @param marketId Target market on EXFactory
    /// @param component Component ID
    /// @param selector First 4 bytes of the forwarded calldata
    event Executed(address indexed caller, bytes32 indexed marketId, uint8 indexed component, bytes4 selector);

    /// @notice Emitted when the (component, selector) → role allowlist entry is added, replaced, or removed
    /// @param component Component ID
    /// @param selector Function selector on the component
    /// @param prevRole Previous required role (bytes32(0) if newly added)
    /// @param role New required role (bytes32(0) if entry removed)
    event SelectorRoleUpdated(uint8 indexed component, bytes4 indexed selector, bytes32 prevRole, bytes32 role);

    /// @notice Emitted when the calldata-args pin for (component, selector) is set, replaced, or cleared
    /// @param component Component ID
    /// @param selector Function selector on the component
    /// @param prevHash Previous expected args-hash (bytes32(0) if newly added)
    /// @param newHash New expected args-hash (bytes32(0) if entry cleared)
    event SelectorDataUpdated(uint8 indexed component, bytes4 indexed selector, bytes32 prevHash, bytes32 newHash);

    /* ========== EXTERNAL FUNCTIONS ========== */

    /// @notice Forwards a role-gated call to a per-market component
    /// @dev Reverts SelectorNotAllowed if the (component, selector) pair is not in the allowlist;
    ///      reverts NotAuthorized if msg.sender lacks the required role; reverts UnknownComponent if
    ///      the resolver returns address(0); bubbles target reverts verbatim.
    /// @param marketId The marketId on EXFactory whose component is being called
    /// @param component One of `Component` enum values cast to uint8
    /// @param data ABI-encoded call (selector + args) for the target component
    /// @return The forwarded call's return data
    function execute(bytes32 marketId, uint8 component, bytes calldata data) external returns (bytes memory);

    /// @notice Adds, replaces, or removes the role required to call (component, selector)
    /// @dev Setting role to bytes32(0) removes the allowlist entry. PROTOCOL_ADMIN_ROLE only.
    /// @param component One of `Component` enum values cast to uint8
    /// @param selector Function selector on the target component
    /// @param role Required protocol role; bytes32(0) removes the entry
    function setSelectorRole(uint8 component, bytes4 selector, bytes32 role) external;

    /// @notice Sets or clears the calldata-args pin for (component, selector).
    /// @dev When pinned, `execute` requires `keccak256(data[4:]) == keccak256(args)`. Combine
    ///      with `setSelectorRole` to lock down both who may dispatch AND what args they may
    ///      pass. PROTOCOL_ADMIN_ROLE only.
    /// @param component One of `Component` enum values cast to uint8
    /// @param selector Function selector on the target component
    /// @param args Expected calldata-args (after the 4-byte selector). Empty = clear the pin.
    function setSelectorData(uint8 component, bytes4 selector, bytes calldata args) external;
}
