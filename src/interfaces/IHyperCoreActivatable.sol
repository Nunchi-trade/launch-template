// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IHyperCoreActivatable
/// @notice External surface for any HyperEVM contract that needs an HC spot account before it
///         can emit CoreWriter actions. Implemented by the `HyperCoreActivatable` base; declared
///         here so contract interfaces (`ILaunchFeeSplitter`, `IStakeFeesThrottle`, `IEXManager`)
///         can inherit a single shared declaration and avoid override-disambiguation boilerplate.
interface IHyperCoreActivatable {
    /// @notice Emitted on a successful default-path activation deposit (base implementation).
    /// @param caller msg.sender that supplied the activation token
    /// @param tokenId HIP-1 token id used (registered in `GlobalConfig.activationTokens`)
    /// @param amount The activation token amount transferred in and bridged
    event HyperCoreActivated(address indexed caller, uint32 indexed tokenId, uint256 amount);

    /// @notice Pulls `amount` of the activation token from msg.sender and bridges it to this
    ///         contract's HyperCore spot balance, registering the contract's HC account so it can
    ///         subsequently emit `CoreWriter.sendRawAction(...)` calls (sendSpot, sendAsset, etc.).
    /// @dev Two bridge paths, selected by the activation token's registered adapter:
    ///      - Direct (`adapter == address(0)`): `safeTransfer(systemAddress, amount)` — HyperCore
    ///        credits this contract directly from the token's deterministic system address.
    ///      - Adapter (Circle-style vault): `safeIncreaseAllowance(adapter, amount)` followed by
    ///        `IActivationAdapter(adapter).depositFor(address(this), amount, destinationDex)` —
    ///        the vault pulls the token and routes the HC credit on this contract's behalf.
    ///      The token, systemAddress, adapter, and destinationDex are looked up from the
    ///      implementing contract's `_globalConfig().activationTokens(tokenId)` registry. Reverts
    ///      `UnsupportedActivationToken` if `tokenId` is not registered.
    /// @param tokenId HIP-1 token id of the activation token (must be registered in
    ///        `GlobalConfig.addActivationToken*`)
    /// @param amount Raw token wei to pull from msg.sender and bridge
    function activate(uint32 tokenId, uint256 amount) external;

    /// @notice Reads `L1Read.coreUserExists(address(this)).exists` to check whether this
    ///         contract has an HC spot account registered.
    /// @dev Returns true once any `activate(...)` call has completed and HyperCore has processed
    ///      the bridge credit. Off-chain bots use this to pre-flight CoreWriter calls;
    ///      `EXFactory.bondMarket` uses it as the gate before bonding a market.
    /// @return True if this contract's HC spot account exists (post-activation), false otherwise.
    function activated() external view returns (bool);
}
