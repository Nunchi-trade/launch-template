// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";
import {IUpgradeableBeaconRegistry} from "@kinetiq/launch/src/interfaces/IUpgradeableBeaconRegistry.sol";

/// @title IEXDeployer
/// @notice External surface for the per-market suite deployer extracted from EXFactory.
interface IEXDeployer {
    /// @notice Beacon registry holding per-market beacon impls used by every BeaconProxy this
    ///         deployer creates.
    function beaconRegistry() external view returns (IUpgradeableBeaconRegistry);

    /// @notice The EXFactory address authorized to call `deployMarketContracts`. The protocol
    ///         roles controller used for DefaultOracle's operator role is read live from the
    ///         factory at deploy time (`exFactory.protocolRolesController()`) — not stored here.
    function exFactory() external view returns (IEXFactory);

    /// @notice Deploys the 11 BeaconProxy + 2 plain oracle instances that make up a per-market
    ///         suite and returns their addresses.
    /// @dev Phase A of `EXFactory.deployMarket`: deploys BeaconProxy instances for upgradeable
    ///      per-market contracts (Router, EXManager, EXLST, StakingAccountant, ValidatorManager,
    ///      OracleManager, RewardShareTracker, GhostLST, BlockedWithdrawalQueue, LaunchFeeSplitter,
    ///      StakeFeesThrottle) plus the 2 plain oracle contracts (DefaultOracle, OracleAdapter).
    ///      All proxies are deployed empty; `initialize()` is called from the factory's
    ///      `_initializeLSTInfra` / `_initializeLaunchInfra` so cross-references between the
    ///      addresses can be wired up. DefaultOracle's constructor takes the factory as initial
    ///      admin and the protocol roles controller as initial operator; admin handover to the
    ///      controller happens later in the factory's `_transferRoles`. Gated to
    ///      `msg.sender == exFactory` so only the wired factory can request deployments.
    ///      Uses CREATE2 with `marketId`-keyed salts so every address is a deterministic
    ///      function of `(deployer, deployerNonce)` — front-run-immune (attacker calling
    ///      `deployMarket` cannot shift the victim's addresses).
    /// @param marketId Per-market identifier from `EXFactory` (`keccak256(abi.encode(deployer, nonce))`)
    ///                 — drives the CREATE2 salt for every contract in the suite.
    /// @return Struct holding every per-market contract address, populated in deploy order
    function deployMarketContracts(bytes32 marketId) external returns (IEXFactory.MarketContracts memory);

    /// @notice Computes the addresses that `deployMarketContracts(marketId)` would produce for the
    ///         given `marketId`, without deploying.
    /// @dev Pure function of `marketId` and current beacon-registry state. Beacon addresses are
    ///      immutable per contract type (`registerBeacon` reverts if already set; impl rotation
    ///      via `UpgradeableBeacon.upgradeTo` swaps the impl behind a stable beacon address), so
    ///      predictions are stable across impl upgrades.
    function predictDeployment(bytes32 marketId) external view returns (IEXFactory.MarketContracts memory);
}
