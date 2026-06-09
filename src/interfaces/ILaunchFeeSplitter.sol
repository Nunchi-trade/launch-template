// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";
import {IGlobalConfig} from "@kinetiq/launch/src/interfaces/IGlobalConfig.sol";

/// @title ILaunchFeeSplitter
/// @notice External surface for the per-market launch fee splitter.
/// @dev HC perp-dex coordinates (`perpDexId`, `collateralTokenId`, `buybackWallet`) live on the
///      per-market `EXManager` and are set by `EXManager.link()`. LFS reads them live at split-time.
///
///      `split` takes an operator-provided `amount` in `collateralTokenId` HC weiDecimals. The
///      operator (PROTOCOL_OPERATOR_ROLE via ProtocolRolesController) is responsible for reading
///      the splitter's `accountMarginSummary` on `exManager.perpDexId()` off-chain and computing
///      the correct distribution amount. Keeping the unit conversion off-chain avoids
///      decimal-mismatch errors and removes any precompile dependency from `split`.
///
///      `activate(uint32, uint256)` and `activated()` live on the inherited `IHyperCoreActivatable`
///      surface — callers casting through this contract-specific interface can additionally cast
///      to `IHyperCoreActivatable` to reach those.
interface ILaunchFeeSplitter {
    /// @notice Global protocol configuration source (treasury and fee-share parameters).
    function globalConfig() external view returns (IGlobalConfig);

    /// @notice The per-market EXManager — source of truth for `perpDexId`, `collateralTokenId`,
    ///         `buybackWallet`, and `linkTimestamp`. LFS gates `split` on `linkTimestamp != 0`.
    function exManager() external view returns (IEXManager);

    /// @notice Deployer treasury destination for the deployer fee share.
    function deployerTreasury() external view returns (address);

    /// @notice Buyback share in basis points applied to the deployer post-protocol remainder.
    function buybackBps() external view returns (uint64);

    /// @notice Splits an operator-supplied `amount` (in `exManager.collateralTokenId()`
    ///         weiDecimals) three ways: protocol / deployer / buyback. Each share is routed via
    ///         CoreWriter.sendAsset (action 13) from `exManager.perpDexId()` to spot.
    /// @dev OPERATOR_ROLE only. Reverts `NotLinked` if `exManager.linkTimestamp() == 0`.
    /// @param amount Total fee amount to distribute (in collateralTokenId HC weiDecimals)
    function split(uint64 amount) external;

    /// @notice Pure preview of the 3-way split for a given amount in collateralTokenId weiDecimals.
    /// @dev No precompile dependency, no link-state gate (callable any time for operator off-chain UX).
    /// @param amount The hypothetical total amount to split
    /// @return protocolFeeShare Amount routable to `globalConfig.protocolFeeTreasury()`
    /// @return buybackFeeShare Amount routable to `exManager.buybackWallet()`
    /// @return deployerFeeShare Amount routable to `deployerTreasury`
    function viewSplits(uint64 amount)
        external
        view
        returns (uint64 protocolFeeShare, uint64 buybackFeeShare, uint64 deployerFeeShare);
}
