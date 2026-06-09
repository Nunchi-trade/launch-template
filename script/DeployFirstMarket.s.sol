// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";
import {IGlobalConfig} from "@kinetiq/launch/src/interfaces/IGlobalConfig.sol";
import {IHyperCoreActivatable} from "@kinetiq/launch/src/interfaces/IHyperCoreActivatable.sol";
import {IValidatorManager} from "@kinetiq/lst/src/interfaces/IValidatorManager.sol";

import {DeployHelpers} from "./lib/DeployHelpers.sol";
import {PrecompileStubs} from "./lib/PrecompileStubs.sol";

/// @title DeployFirstMarket
/// @notice Per-market lifecycle: deployMarket → activateMarket → bondMarket → (optional) cancelMarket.
///         Each phase is its own external entry — HyperCore must confirm the activation token bridge
///         before `bondMarket` can land, and that confirmation is off-chain. The deployer runs the
///         phases sequentially with a wait between activate and bond.
///
/// @notice Every phase takes `(marketConfigPath, globalConfigPath)`. The marketConfig is the
///         deployer's per-market intake file (`TEMPLATE.json` is the seed they copy + fill in).
///         The globalConfig is the per-network protocol singleton + pinned-defaults file; pass `""`
///         for `globalConfigPath` to auto-resolve from the marketConfig's `network.name`
///         (defaults to `script/config/globals/<networkName>.json`), or pass an explicit path to
///         override (custom globalConfig for forks, alternate deployments, etc.).
///
/// @dev    Usage:
///         forge script script/DeployFirstMarket.s.sol:DeployFirstMarket \
///           --sig 'deployMarket(string,string)' "$MARKET_CONFIG_JSON" "$GLOBAL_CONFIG_JSON" \
///           --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract DeployFirstMarket is Script {
    using stdJson for string;
    using DeployHelpers for string;

    /* ========== PHASE 1: deployMarket ========== */

    function deployMarket(string memory marketConfigPath, string memory globalConfigPath) public {
        PrecompileStubs.etchAll();
        (string memory marketConfig, string memory globalConfig,) =
            DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        DeployHelpers.labelDeployed(globalConfig);

        IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
        IEXFactory.MarketParams memory params = _buildMarketParams(marketConfig, globalConfig);

        _preFlightAssertsForDeploy(f, params);

        vm.startBroadcast();
        (bytes32 marketId, address exManager) = f.deployMarket{value: params.opBond}(params);
        vm.stopBroadcast();

        DeployHelpers.writeJsonBytes32(marketConfigPath, ".deployed.marketId", marketId);
        DeployHelpers.writeJsonAddress(marketConfigPath, ".deployed.exManager", exManager);
        // Reset bonded + cancelled when a new market is deployed — protects against stale state
        // from a previously-bonded or previously-cancelled market reusing the same marketConfig.
        DeployHelpers.writeJsonBool(marketConfigPath, ".deployed.bonded", false);
        DeployHelpers.writeJsonBool(marketConfigPath, ".deployed.cancelled", false);

        console.log("[deployMarket] marketId:", vm.toString(marketId));
        console.log("[deployMarket] exManager:", exManager);
        console.log("[deployMarket] opBond escrowed:", params.opBond);
        console.log("Next: activateMarket(<marketConfig>, <globalConfig>) once activation token approved + funded.");
    }

    /* ========== PHASE 2: activateMarket ========== */

    function activateMarket(string memory marketConfigPath, string memory globalConfigPath) public {
        PrecompileStubs.etchAll();
        (string memory marketConfig, string memory globalConfig,) =
            DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        DeployHelpers.labelDeployed(globalConfig);

        IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
        bytes32 marketId = marketConfig.readBytes32(".deployed.marketId");
        require(marketId != bytes32(0), "DeployFirstMarket: market not deployed");

        // Activation token = the HC perp dex's collateral token (deployer-chosen in the core block).
        uint32 tokenId = uint32(marketConfig.readUint(".core.registerAsset.schema.collateralToken"));

        IGlobalConfig gc = f.globalConfig();
        require(gc.isActivationToken(tokenId), "DeployFirstMarket: collateralToken not registered as activation token");
        (,,, address token, uint8 decimals,,) = gc.activationTokens(tokenId);

        // Amount = totalRequired (whole tokens, summed across the 3 activation targets) scaled by
        // the token's decimals. Deployer must hold + approve this floor; over-funding (a custom
        // amount) is intentionally unsupported via this script to keep the deployer flow simple.
        (,, uint256 totalRequired) = f.activationTargets(marketId);
        uint256 amount = totalRequired * (10 ** uint256(decimals));
        require(
            IERC20(token).balanceOf(msg.sender) >= amount, "DeployFirstMarket: deployer balance < activation minimum"
        );

        vm.startBroadcast();
        IERC20(token).approve(address(f), amount);
        f.activateMarket(marketId, tokenId, amount);
        vm.stopBroadcast();

        console.log("[activateMarket] bridged", amount, "of token", token);
        console.log("[activateMarket] tokenId:", tokenId);
        console.log("Next: bondMarket(<marketConfig>, <globalConfig>) once HyperCore credits the Router's L1 spot.");
    }

    /* ========== PHASE 3: bondMarket ========== */

    function bondMarket(string memory marketConfigPath, string memory globalConfigPath) public {
        PrecompileStubs.etchAll();
        (string memory marketConfig, string memory globalConfig,) =
            DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        DeployHelpers.labelDeployed(globalConfig);

        IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
        bytes32 marketId = marketConfig.readBytes32(".deployed.marketId");
        require(marketId != bytes32(0), "DeployFirstMarket: market not deployed");

        IEXFactory.MarketContracts memory mc = f.getMarketContracts(marketId);
        // Match EXFactory.bondMarket's _activationTargets: [exManager, launchFeeSplitter,
        // stakeFeesThrottle]. EXManager.activated() reads coreUserExists(exStakingManager)
        // internally — the Router itself doesn't inherit HyperCoreActivatable.
        _requireActivated(mc.exManager, "EXManager (reads coreUserExists on exStakingManager)");
        _requireActivated(mc.launchFeeSplitter, "LaunchFeeSplitter");
        _requireActivated(mc.stakeFeesThrottle, "StakeFeesThrottle");

        vm.startBroadcast();
        f.bondMarket(marketId);
        vm.stopBroadcast();

        DeployHelpers.writeJsonBool(marketConfigPath, ".deployed.bonded", true);
        console.log("[bondMarket] market bonded, transitioned to FUNDING");
        console.log("[bondMarket] exManager:", mc.exManager);
    }

    /* ========== PHASE 4: cancelMarket ========== */

    /// @notice Aborts a pre-bond market and refunds `opBondEscrowed` to `.cancelRecipient`
    ///         (defaults to `msg.sender` when unset). Pre-flight asserts `bonded == false`
    ///         and `block.timestamp >= cancelEligibleAt`. The `cancelEligibleAt` timer is
    ///         snapshotted at deployMarket time (= deploy block timestamp +
    ///         `globalConfig.unwindDelay()`).
    function cancelMarket(string memory marketConfigPath, string memory globalConfigPath) public {
        PrecompileStubs.etchAll();
        (string memory marketConfig, string memory globalConfig,) =
            DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
        DeployHelpers.labelDeployed(globalConfig);

        IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
        bytes32 marketId = marketConfig.readBytes32(".deployed.marketId");
        require(marketId != bytes32(0), "DeployFirstMarket: market not deployed");

        address recipient = DeployHelpers.readOptionalAddress(marketConfig, ".cancelRecipient");
        if (recipient == address(0)) recipient = msg.sender;

        IEXFactory.MarketInfo memory info = f.getMarket(marketId);
        require(info.exManager != address(0), "DeployFirstMarket: market not found in factory");
        require(!info.bonded, "DeployFirstMarket: market is bonded, cannot cancel");
        require(block.timestamp >= info.cancelEligibleAt, "DeployFirstMarket: cancelEligibleAt not yet elapsed");

        uint256 recipientBalBefore = recipient.balance;

        vm.startBroadcast();
        f.cancelMarket(marketId, recipient);
        vm.stopBroadcast();

        DeployHelpers.writeJsonBool(marketConfigPath, ".deployed.cancelled", true);

        uint256 refund = recipient.balance - recipientBalBefore;
        console.log("[cancelMarket] recipient:", recipient);
        console.log("[cancelMarket] refunded wei:", refund);
        console.log("[cancelMarket] expected (opBondEscrowed):", info.opBondEscrowed);
    }

    /* ========== HELPERS ========== */

    /// @dev Constructs `MarketParams` by merging the deployer's marketConfig with the
    ///      globalConfig's pinned defaults. Marked `virtual` so end-clients forking this
    ///      script can override to constrain / pre-validate inputs (tighter buybackBps
    ///      caps, restricted role schemes, non-JSON sources, etc.). Override must remain
    ///      `view` per Solidity mutability narrowing rules.
    function _buildMarketParams(string memory marketConfig, string memory globalConfig)
        internal
        view
        virtual
        returns (IEXFactory.MarketParams memory)
    {
        return DeployHelpers.buildMarketParams(marketConfig, globalConfig);
    }

    /// @dev Mirrors the factory's own `deployMarket` validations — fail fast in the script
    ///      before we send the opBond. Distinctness asserts (admin!=operator etc.) omitted
    ///      because the source contracts don't enforce them and deployers may collapse
    ///      roles to a single EOA during dry-runs.
    function _preFlightAssertsForDeploy(IEXFactory f, IEXFactory.MarketParams memory p) internal view {
        require(p.admin != address(0), "params.admin == 0");
        require(p.operator != address(0), "params.operator == 0");
        require(p.enclaver != address(0), "params.enclaver == 0");
        require(p.validator != address(0), "params.validator == 0");
        require(p.hyperCoreDeployer != address(0), "params.hyperCoreDeployer == 0");
        require(p.deployerTreasury != address(0), "params.deployerTreasury == 0");
        require(bytes(p.lstName).length > 0, "params.lstName empty");
        require(bytes(p.lstSymbol).length > 0, "params.lstSymbol empty");
        require(p.buybackBps <= 10_000, "params.buybackBps > 10000");

        IGlobalConfig gc = f.globalConfig();
        require(p.opBond >= gc.minOperatorBond(), "params.opBond < minOperatorBond");
        require(p.opBond % 1e10 == 0, "params.opBond not 1e10-aligned");
        require(p.marketTier >= 1 && p.marketTier <= gc.tierCount(), "params.marketTier out of range");

        IValidatorManager vm_ = IValidatorManager(f.kHYPEValidatorManager());
        require(vm_.validatorActiveState(p.validator), "params.validator inactive on kHYPEValidatorManager");

        // Deployer wallet must hold opBond
        require(msg.sender.balance >= p.opBond, "deployer balance < opBond");
    }

    function _requireActivated(address ctrt, string memory label) internal view {
        require(
            IHyperCoreActivatable(ctrt).activated(),
            string.concat("DeployFirstMarket: ", label, " not yet HC-activated (wait for HyperCore to credit)")
        );
    }
}
