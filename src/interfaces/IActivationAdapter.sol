// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IActivationAdapter
/// @notice Minimal interface for vault-style activation adapters — contracts that bridge a wrapped
///         HyperCore asset to HyperEVM by accepting the underlying ERC20 and forwarding the deposit
///         on behalf of a specified recipient. The shape matches Circle's `CoreDepositWallet` ABI
///         subset so the on-chain vault contracts can be registered directly without a custom shim.
/// @dev `token()` is consulted only at `GlobalConfig.addActivationTokenWithAdapter` time — the
///      resolved underlying address is cached in `TokenConfig.token` to avoid runtime staticcalls
///      and to make the value stable + audit-friendly.
/// @dev `depositFor` is the runtime activation entrypoint. The adapter pulls the underlying ERC20
///      from `msg.sender` via its internal `transferFrom`, performs whatever HyperCore bridge
///      mechanism it implements, and credits `recipient` on the chosen `destinationDex`.
interface IActivationAdapter {
    /// @notice The ERC20 the adapter consumes when its `depositFor` is called
    /// @return The underlying ERC20 contract address on HyperEVM
    function token() external view returns (address);

    /// @notice Bridges `amount` of the underlying ERC20 to credit `recipient` on HyperCore.
    /// @dev Caller MUST have approved this adapter to spend at least `amount` of `token()` before
    ///      invoking. The adapter pulls via its internal `transferFrom(msg.sender, ...)`.
    /// @param recipient The HyperCore address to credit
    /// @param amount The underlying ERC20 amount to deposit (in HyperEVM token units)
    /// @param destinationDex The HyperCore destination dex ID (e.g., 0 = Core Perps; uint32.max = Spot)
    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external;
}
