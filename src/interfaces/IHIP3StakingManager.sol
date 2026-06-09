// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IStakingManager} from "@kinetiq/lst/src/interfaces/IStakingManager.sol";

/// @title IHIP3StakingManager
/// @notice Interface for a per-market StakingManagerRouter with HIP-3 extensions.
///         Typed variable used by EXManager and other Launch contracts to call both
///         standard staking operations (via Router fallback) and HIP-3 facet operations.
interface IHIP3StakingManager is IStakingManager {
    /// @notice Emitted when the API wallet is updated
    /// @param wallet The address of the API wallet
    event ApiWalletUpdated(address wallet);

    /// @notice Emitted when HYPE is deposited to the spot balance
    /// @param amount The amount of HYPE deposited
    event SpotDeposited(uint256 amount);

    /// @notice Emitted when an ERC20 token is bridged. Direct path: `adapter == address(0)`,
    ///         destinationDex is the registry's unused-on-direct-path sentinel. Adapter path:
    ///         non-zero adapter + destinationDex registered for the token.
    event TokenDeposited(
        address indexed token,
        uint256 amount,
        address indexed systemAddress,
        address indexed adapter,
        uint32 destinationDex
    );

    /// @notice Deposits HYPE to the spot balance
    function depositToSpot() external payable;

    /// @notice Bridges an ERC20 token already held by this Router. Direct path (adapter == 0)
    ///         transfers to `systemAddress`. Adapter path approves `adapter` and calls
    ///         `IActivationAdapter(adapter).depositFor(address(this), amount, destinationDex)`.
    /// @dev Whitelist-gated. Caller must ensure the Router holds at least `amount` of `token`
    ///      before invoking — this function does NOT pull the token in. Activation tokens MUST
    ///      NOT be fee-on-transfer ERC20s — see IGlobalConfig.TokenConfig.
    function depositTokenToDex(
        address token,
        uint256 amount,
        address systemAddress,
        address adapter,
        uint32 destinationDex
    ) external;

    /// @notice Sets the API wallet
    /// @param wallet The address of the API wallet
    function setApiWallet(address wallet) external;
}
