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
///         before `bondMarket` can land, and that confirmation is off-chain. The operator runs the
///         entries with a wait in between.
///
/// @notice All phases take `(configPath, label)` — `label` selects the market entry under the JSON
///         `markets` object (keyed by label). Lets one config track multiple markets concurrently
///         (e.g., a bonded `firstMarket`, a `cancelTest`, a `secondMarket`, etc.). Keyed object
///         instead of array because forge `vm.writeJson` only supports dot-separated object key
///         paths — array-index syntax like `.markets[i]` doesn't work.
///
/// @dev    Usage:
///         forge script script/DeployFirstMarket.s.sol:DeployFirstMarket \
///           --sig 'deployMarket(string,string)' $CONFIG_JSON firstMarket \
///           --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
///
///         # then activateMarket / bondMarket / cancelMarket against the same label.
contract DeployFirstMarket is Script {
    using stdJson for string;
    using DeployHelpers for string;

    /* ========== PHASE 1: deployMarket ========== */

    function deployMarket(string memory configPath, string memory label) public {
        PrecompileStubs.etchAll();
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        require(
            config.hasMarket(label),
            string.concat("DeployFirstMarket: no market entry with label '", label, "' in .markets")
        );

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        IEXFactory.MarketParams memory params = _buildMarketParams(config, label);

        _preFlightAssertsForDeploy(f, params);

        vm.startBroadcast();
        (bytes32 marketId, address exManager) = f.deployMarket{value: params.opBond}(params);
        vm.stopBroadcast();

        string memory base = DeployHelpers.marketPath(label);
        DeployHelpers.writeJsonBytes32(configPath, string.concat(base, ".deployed.marketId"), marketId);
        DeployHelpers.writeJsonAddress(configPath, string.concat(base, ".deployed.exManager"), exManager);
        // Reset bonded + cancelled when a new market is deployed to a label slot — protects against
        // stale state from a previously-bonded or previously-cancelled market under the same label.
        DeployHelpers.writeJsonBool(configPath, string.concat(base, ".deployed.bonded"), false);
        DeployHelpers.writeJsonBool(configPath, string.concat(base, ".deployed.cancelled"), false);

        console.log("[deployMarket] label:", label);
        console.log("[deployMarket] marketId:", vm.toString(marketId));
        console.log("[deployMarket] exManager:", exManager);
        console.log("[deployMarket] opBond escrowed:", params.opBond);
        console.log("Next: activateMarket(<configPath>, <label>) once you have the activation token approved + funded.");
    }

    /* ========== PHASE 2: activateMarket ========== */

    function activateMarket(string memory configPath, string memory label) public {
        PrecompileStubs.etchAll();
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        require(
            config.hasMarket(label),
            string.concat("DeployFirstMarket: no market entry with label '", label, "' in .markets")
        );
        string memory base = DeployHelpers.marketPath(label);

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        bytes32 marketId = config.readBytes32(string.concat(base, ".deployed.marketId"));
        require(marketId != bytes32(0), "DeployFirstMarket: market not deployed");

        uint32 tokenId = uint32(config.readUint(string.concat(base, ".activation.tokenId")));
        uint256 amount = config.readUint(string.concat(base, ".activation.amount"));
        require(amount > 0, "DeployFirstMarket: activation amount == 0");

        IGlobalConfig gc = f.globalConfig();
        require(gc.isActivationToken(tokenId), "DeployFirstMarket: tokenId not registered as activation token");
        (,,, address token,,,) = gc.activationTokens(tokenId);

        vm.startBroadcast();
        IERC20(token).approve(address(f), amount);
        f.activateMarket(marketId, tokenId, amount);
        vm.stopBroadcast();

        console.log("[activateMarket] label:", label);
        console.log("[activateMarket] bridged", amount, "of token", token);
        console.log("[activateMarket] tokenId:", tokenId);
        console.log("Next: bondMarket(<configPath>, <label>) once HyperCore credits the Router's L1 spot balance.");
    }

    /* ========== PHASE 3: bondMarket ========== */

    function bondMarket(string memory configPath, string memory label) public {
        PrecompileStubs.etchAll();
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        require(
            config.hasMarket(label),
            string.concat("DeployFirstMarket: no market entry with label '", label, "' in .markets")
        );
        string memory base = DeployHelpers.marketPath(label);

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        bytes32 marketId = config.readBytes32(string.concat(base, ".deployed.marketId"));
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

        DeployHelpers.writeJsonBool(configPath, string.concat(base, ".deployed.bonded"), true);
        console.log("[bondMarket] label:", label);
        console.log("[bondMarket] market bonded, transitioned to FUNDING");
        console.log("[bondMarket] exManager:", mc.exManager);
    }

    /* ========== PHASE 4: cancelMarket ========== */

    /// @notice Aborts a pre-bond market and refunds `opBondEscrowed` to the configured recipient.
    /// @dev    Pre-flight asserts `bonded=false` and `block.timestamp >= cancelEligibleAt`. The
    ///         `cancelEligibleAt` timer is snapshotted at deployMarket time (= deploy block
    ///         timestamp + globalConfig.unwindDelay()) — for the dry-run, set unwindDelay to the
    ///         protocol floor (1 day) before deploying so the cancel completes in <2 days.
    function cancelMarket(string memory configPath, string memory label) public {
        PrecompileStubs.etchAll();
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        require(
            config.hasMarket(label),
            string.concat("DeployFirstMarket: no market entry with label '", label, "' in .markets")
        );
        string memory base = DeployHelpers.marketPath(label);

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        bytes32 marketId = config.readBytes32(string.concat(base, ".deployed.marketId"));
        require(marketId != bytes32(0), "DeployFirstMarket: market not deployed");

        address recipient = DeployHelpers.readOptionalAddress(config, string.concat(base, ".cancelRecipient"));
        if (recipient == address(0)) recipient = msg.sender;

        // Pre-flight: market exists, not bonded, eligible timer elapsed
        IEXFactory.MarketInfo memory info = f.getMarket(marketId);
        require(info.exManager != address(0), "DeployFirstMarket: market not found in factory");
        require(!info.bonded, "DeployFirstMarket: market is bonded, cannot cancel");
        require(block.timestamp >= info.cancelEligibleAt, "DeployFirstMarket: cancelEligibleAt not yet elapsed");

        uint256 recipientBalBefore = recipient.balance;

        vm.startBroadcast();
        f.cancelMarket(marketId, recipient);
        vm.stopBroadcast();

        DeployHelpers.writeJsonBool(configPath, string.concat(base, ".deployed.cancelled"), true);

        uint256 refund = recipient.balance - recipientBalBefore;
        console.log("[cancelMarket] label:", label);
        console.log("[cancelMarket] recipient:", recipient);
        console.log("[cancelMarket] refunded wei:", refund);
        console.log("[cancelMarket] expected (opBondEscrowed):", info.opBondEscrowed);
    }

    /* ========== HELPERS ========== */

    /// @dev Constructs `MarketParams` from the JSON config. Marked `virtual` so end-clients
    ///      forking this script can override to constrain / pre-validate inputs (e.g., enforce
    ///      tighter buybackBps caps, restrict admin/operator/enclaver to a fixed scheme, swap
    ///      to a non-JSON source, etc.). Override must remain `pure` per Solidity mutability
    ///      narrowing rules.
    function _buildMarketParams(string memory config, string memory label)
        internal
        pure
        virtual
        returns (IEXFactory.MarketParams memory p)
    {
        string memory pp = string.concat(DeployHelpers.marketPath(label), ".params");
        p.admin = config.readAddress(string.concat(pp, ".admin"));
        p.operator = config.readAddress(string.concat(pp, ".operator"));
        p.enclaver = config.readAddress(string.concat(pp, ".enclaver"));
        p.opBond = config.readUint(string.concat(pp, ".opBond"));
        p.validator = config.readAddress(string.concat(pp, ".validator"));
        p.gate = config.readAddress(string.concat(pp, ".gate"));
        p.lstName = config.readString(string.concat(pp, ".lstName"));
        p.lstSymbol = config.readString(string.concat(pp, ".lstSymbol"));
        p.marketTier = config.readUint(string.concat(pp, ".marketTier"));
        p.hyperCoreDeployer = config.readAddress(string.concat(pp, ".hyperCoreDeployer"));
        p.deployerTreasury = config.readAddress(string.concat(pp, ".deployerTreasury"));
        p.buybackBps = uint64(config.readUint(string.concat(pp, ".buybackBps")));
    }

    /// @dev Mirrors the factory's own `deployMarket` validations — fail fast in the script before
    ///      we send the opBond. Distinctness asserts (admin!=operator etc.) intentionally omitted
    ///      because the source contracts don't enforce them and operators may collapse roles to a
    ///      single EOA during dry-runs.
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
