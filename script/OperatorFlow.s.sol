// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";
import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";
import {IEIP712Verifier} from "@kinetiq/launch/src/interfaces/IEIP712Verifier.sol";

import {IStakingManager} from "@kinetiq/lst/src/interfaces/IStakingManager.sol";
import {IStakingAccountant} from "@kinetiq/lst/src/interfaces/IStakingAccountant.sol";

import {DeployHelpers} from "./lib/DeployHelpers.sol";
import {PrecompileStubs} from "./lib/PrecompileStubs.sol";

/// @title OperatorFlow
/// @notice Four operator-facing action phases against the per-market `EXManager`:
///         `fund | launch | setUnwindPhase | unwind`. Each phase reads the market via
///         `marketConfig.deployed.marketId` + the `EXFactory` address pinned in the
///         network's globalConfig. The `launch` phase takes the Kinetiq-signed
///         EIP712 wallet payload's `data` and `signature` fields as separate CLI args
///         so the operator never needs to encode the struct by hand.
///
/// @dev    Mirrors the UserFlow pattern: PrecompileStubs.etchAll() at every entry,
///         scope-blocked preamble that drops JSON strings off the stack before the body
///         runs, vm.startBroadcast/stopBroadcast around the EXManager call, and inline
///         pre-flight + post-broadcast delta verification with operator-readable revert
///         messages.
///
/// @dev    Usage (pass `""` for `globalConfigPath` to auto-resolve from the marketConfig's
///         `network.name`):
///         forge script script/OperatorFlow.s.sol:OperatorFlow \
///           --sig 'fund(string,string)' $MARKET_CONFIG_JSON "" \
///           --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
contract OperatorFlow is Script {
    using stdJson for string;
    using DeployHelpers for string;

    /* ========== PHASE 1: fund ========== */

    /// @notice Lock in the per-market reserve and transition FUNDING -> LAUNCHING.
    /// @dev    Pre-flight: phase == FUNDING, unwind not queued, ghost LST reserve >= tier
    ///         minHypeStake. `msg.sender` should hold OPERATOR_ROLE (soft-checked).
    function fund(string memory marketConfigPath, string memory globalConfigPath) public returns (uint256 hypeAmount) {
        PrecompileStubs.etchAll();
        IEXManager exMgr;
        {
            (string memory marketConfig, string memory globalConfig,) =
                DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
            DeployHelpers.labelDeployed(globalConfig);
            exMgr = _getExManager(marketConfig, IEXFactory(globalConfig.readDeployedAddress("EXFactory")));
        }

        uint256 minHype = _fundPreflight(exMgr);

        vm.startBroadcast();
        hypeAmount = exMgr.fund();
        vm.stopBroadcast();

        // ---- Inline verify ----
        // `hypeAmount` is the total HYPE stake backing the per-market EXLST; the contract
        // validates `hypeAmount >= minHype` internally before transitioning, so this assert
        // mirrors that guarantee and surfaces it to the operator's trace.
        require(hypeAmount >= minHype, "verify: fund() returned hypeAmount below tier minHypeStake (must be >= floor)");
        require(exMgr.exPhase() == IEXManager.EXPhase.LAUNCHING, "verify: phase not LAUNCHING after fund");

        console.log("[fund] tier minHypeStake floor (wei):", minHype);
        console.log("[fund] HYPE total stake (wei):       ", hypeAmount);
        console.log("[fund] phase transition:              FUNDING -> LAUNCHING");
        console.log("[fund] verify PASSED");
    }

    /// @dev Pre-broadcast intrinsic + phase + reserve check for `fund`. Returns the tier's
    ///      `minHypeStake` so the caller can reuse it for the post-broadcast assertion that
    ///      `fund()`'s returned `hypeAmount` (= total backing stake) meets the floor.
    /// @dev The reserve check converts the EXManager's ghost LST balance to its HYPE-denominated
    ///      value via `accountant.kHYPEToHYPE(...)` and compares against the tier floor in HYPE
    ///      units — same units on both sides for clarity in logs + revert messages.
    function _fundPreflight(IEXManager exMgr) internal view returns (uint256 minHype) {
        require(exMgr.exPhase() == IEXManager.EXPhase.FUNDING, "operatorflow: market not in FUNDING phase");
        require(exMgr.unwindEligibleAt() == 0, "operatorflow: unwind queued, cannot fund");

        IStakingManager routerLst = IStakingManager(address(exMgr.exStakingManager()));
        IStakingAccountant accountant = IStakingAccountant(address(exMgr.exStakingAccountant()));
        IERC20 ghostLST = IERC20(_ghostLST(routerLst));
        uint256 ghostBal = ghostLST.balanceOf(address(exMgr));
        uint256 reserveHype = accountant.kHYPEToHYPE(ghostBal);

        minHype = exMgr.globalConfig().marketTiers(exMgr.marketTier()).minHypeStake;
        require(reserveHype >= minHype, "operatorflow: HYPE reserve below tier minHypeStake floor");

        console.log("[preflight] tier minHypeStake (HYPE wei):", minHype);
        console.log("[preflight] current reserve (HYPE wei):  ", reserveHype);

        _operatorSoftCheck(exMgr);
    }

    /* ========== PHASE 2: launch ========== */

    /// @notice Submit Kinetiq's EIP712-signed wallet payload and register the HC API wallet.
    ///         Transitions LAUNCHING -> LIVE.
    /// @param walletData       The EIP712-encoded `walletData` bytes from Kinetiq.
    /// @param walletSignature  The EIP712 signature (65 bytes) from `globalConfig.exWalletAdmin`.
    /// @dev    Pre-flight: phase == LAUNCHING, unwind not queued, both bytes args non-empty
    ///         + signature length sanity-checked. On-chain `EXManager.launch` does the full
    ///         EIP712 verification against `globalConfig.exWalletAdmin`.
    function launch(
        string memory marketConfigPath,
        string memory globalConfigPath,
        bytes memory walletData,
        bytes memory walletSignature
    ) public returns (address wallet) {
        PrecompileStubs.etchAll();
        IEXManager exMgr;
        {
            (string memory marketConfig, string memory globalConfig,) =
                DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
            DeployHelpers.labelDeployed(globalConfig);
            exMgr = _getExManager(marketConfig, IEXFactory(globalConfig.readDeployedAddress("EXFactory")));
        }

        _launchPreflight(exMgr, walletData, walletSignature);

        IEIP712Verifier.EIP712SignedData memory walletSignedData =
            IEIP712Verifier.EIP712SignedData({data: walletData, signature: walletSignature});

        vm.startBroadcast();
        wallet = exMgr.launch(walletSignedData);
        vm.stopBroadcast();

        // ---- Inline verify ----
        require(exMgr.exPhase() == IEXManager.EXPhase.LIVE, "verify: phase not LIVE after launch");
        require(wallet != address(0), "verify: launch returned zero wallet address");

        console.log("[launch] HC API wallet registered:", wallet);
        console.log("[launch] phase transition:         LAUNCHING -> LIVE");
        console.log("[launch] verify PASSED");
    }

    /// @dev Pre-broadcast checks for `launch`. Phase + unwind + simple payload-length sanity.
    function _launchPreflight(IEXManager exMgr, bytes memory walletData, bytes memory walletSignature) internal view {
        require(exMgr.exPhase() == IEXManager.EXPhase.LAUNCHING, "operatorflow: market not in LAUNCHING phase");
        require(exMgr.unwindEligibleAt() == 0, "operatorflow: unwind queued, cannot launch");
        require(walletData.length > 0, "operatorflow: walletData is empty");
        require(walletSignature.length == 65, "operatorflow: walletSignature must be 65 bytes (ECDSA r,s,v)");
        _operatorSoftCheck(exMgr);
    }

    /* ========== PHASE 3: setUnwindPhase ========== */

    /// @notice Queue (`windingDown = true`) or cancel (`windingDown = false`) a voluntary
    ///         wind-down. Allowed in any active phase (FUNDING, LAUNCHING, LIVE).
    /// @dev    Queueing snapshots `unwindEligibleAt = block.timestamp + globalConfig.unwindDelay()`
    ///         and immediately freezes the operator's lifecycle calls; depositors stay open.
    ///         Cancelling clears `unwindEligibleAt` and unfreezes the operator surface.
    function setUnwindPhase(string memory marketConfigPath, string memory globalConfigPath, bool windingDown) public {
        PrecompileStubs.etchAll();
        IEXManager exMgr;
        {
            (string memory marketConfig, string memory globalConfig,) =
                DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
            DeployHelpers.labelDeployed(globalConfig);
            exMgr = _getExManager(marketConfig, IEXFactory(globalConfig.readDeployedAddress("EXFactory")));
        }

        // Pre-flight
        IEXManager.EXPhase phase = exMgr.exPhase();
        require(
            phase == IEXManager.EXPhase.FUNDING || phase == IEXManager.EXPhase.LAUNCHING
                || phase == IEXManager.EXPhase.LIVE,
            "operatorflow: setUnwindPhase only allowed in FUNDING/LAUNCHING/LIVE"
        );
        uint256 eligibleBefore = exMgr.unwindEligibleAt();
        if (windingDown) {
            require(eligibleBefore == 0, "operatorflow: unwind already queued");
        } else {
            require(eligibleBefore != 0, "operatorflow: no unwind queued to cancel");
        }
        uint256 unwindDelay = exMgr.globalConfig().unwindDelay();
        _operatorSoftCheck(exMgr);

        vm.startBroadcast();
        exMgr.setUnwindPhase(windingDown);
        vm.stopBroadcast();

        // ---- Inline verify ----
        uint256 eligibleAfter = exMgr.unwindEligibleAt();
        if (windingDown) {
            require(
                eligibleAfter == block.timestamp + unwindDelay,
                "verify: unwindEligibleAt != block.timestamp + unwindDelay"
            );
        } else {
            require(eligibleAfter == 0, "verify: unwindEligibleAt != 0 after cancel");
        }
        require(exMgr.exPhase() == phase, "verify: phase changed unexpectedly during setUnwindPhase");

        console.log("[setUnwindPhase] windingDown:               ", windingDown);
        console.log("[setUnwindPhase] unwindEligibleAt after:    ", eligibleAfter);
        console.log("[setUnwindPhase] verify PASSED");
    }

    /* ========== PHASE 4: unwind ========== */

    /// @notice Finalize a queued wind-down. The `opBond` shares escrowed in `EXManager` sweep
    ///         back to the deployer and the market enters terminal WOUND_DOWN.
    /// @dev    Pre-flight: unwind queued, `unwindEligibleAt` elapsed.
    ///         **LIVE-phase additional gate** (enforced on-chain, not in this preflight):
    ///         Kinetiq's HC attestation (`release(true)`) must have fired AND the
    ///         `minLinkAgeForUnwind` cliff must have elapsed since the market's HC link
    ///         (183 days on mainnet). The on-chain call will revert if either condition
    ///         isn't met; this script logs a reminder when entering from LIVE.
    function unwind(string memory marketConfigPath, string memory globalConfigPath) public {
        PrecompileStubs.etchAll();
        IEXManager exMgr;
        IEXFactory.MarketInfo memory info;
        {
            (string memory marketConfig, string memory globalConfig,) =
                DeployHelpers.preflightMarketConfig(marketConfigPath, globalConfigPath);
            DeployHelpers.labelDeployed(globalConfig);
            IEXFactory f = IEXFactory(globalConfig.readDeployedAddress("EXFactory"));
            bytes32 marketId = marketConfig.readBytes32(".deployed.marketId");
            require(marketId != bytes32(0), "operatorflow: marketId is zero (market not deployed)");
            info = f.getMarket(marketId);
            require(info.exManager != address(0), "operatorflow: market not registered in factory");
            exMgr = IEXManager(info.exManager);
        }

        // Pre-flight
        uint256 eligibleAt = exMgr.unwindEligibleAt();
        require(eligibleAt != 0, "operatorflow: no unwind queued");
        require(block.timestamp >= eligibleAt, "operatorflow: unwindEligibleAt has not elapsed");

        IEXManager.EXPhase phaseBefore = exMgr.exPhase();
        if (phaseBefore == IEXManager.EXPhase.LIVE) {
            console.log("[note] LIVE-phase unwind finalize additionally requires:");
            console.log("       - Kinetiq HC attestation (release(true)) recorded on-chain");
            console.log("       - minLinkAgeForUnwind cliff elapsed since HC link timestamp");
            console.log("       On-chain call will revert if either condition isn't met.");
        }
        _operatorSoftCheck(exMgr);

        // Snapshot opBond shares: EXManager holds the deployer's bonded EXLST; finalize sweeps to deployer.
        IERC20 exLST = IERC20(address(exMgr.exLST()));
        address deployer = info.deployer;
        uint256 deployerSharesBefore = exLST.balanceOf(deployer);
        uint256 exMgrSharesBefore = exLST.balanceOf(address(exMgr));

        vm.startBroadcast();
        exMgr.unwind();
        vm.stopBroadcast();

        // ---- Inline verify ----
        require(exMgr.exPhase() == IEXManager.EXPhase.WOUND_DOWN, "verify: phase not WOUND_DOWN after unwind");
        require(exMgr.unwindEligibleAt() == 0, "verify: unwindEligibleAt not cleared on finalize");

        uint256 deployerSharesAfter = exLST.balanceOf(deployer);
        uint256 exMgrSharesAfter = exLST.balanceOf(address(exMgr));
        uint256 deployerDelta = deployerSharesAfter - deployerSharesBefore;
        uint256 exMgrDelta = exMgrSharesBefore - exMgrSharesAfter;
        require(deployerDelta > 0, "verify: deployer did not receive any opBond shares back");
        require(
            deployerDelta == exMgrDelta, "verify: opBond share sweep doesn't conserve (EXManager out != deployer in)"
        );

        console.log("[unwind] phase transition:               -> WOUND_DOWN");
        console.log("[unwind] deployer:                       ", deployer);
        console.log("[unwind] opBond EXLST shares swept (wei):", deployerDelta);
        console.log("[unwind] verify PASSED");
    }

    /* ========== HELPERS ========== */

    /// @dev Soft check: warn (don't revert) when msg.sender isn't the operator. On-chain
    ///      `EXManager` will revert anyway; warning helps the operator notice a misconfigured
    ///      `--sender` / `--private-key` before incurring gas.
    function _operatorSoftCheck(IEXManager exMgr) internal view {
        if (msg.sender != exMgr.operator()) {
            console.log("[warn] msg.sender is not the registered operator for this market;");
            console.log("       the on-chain call will revert. Check --sender / --private-key.");
            console.log("       msg.sender:", msg.sender);
            console.log("       operator:  ", exMgr.operator());
        }
    }

    function _getExManager(string memory marketConfig, IEXFactory f) internal view returns (IEXManager) {
        bytes32 marketId = marketConfig.readBytes32(".deployed.marketId");
        require(marketId != bytes32(0), "operatorflow: marketId is zero (market not deployed)");
        IEXFactory.MarketInfo memory info = f.getMarket(marketId);
        require(info.exManager != address(0), "operatorflow: market not registered in factory");
        return IEXManager(info.exManager);
    }

    /// @dev Reads the auto-generated `tokenAddress()` getter on the LST router's storage layout.
    function _ghostLST(IStakingManager routerLst) internal view returns (address) {
        (bool ok, bytes memory ret) = address(routerLst).staticcall(abi.encodeWithSignature("tokenAddress()"));
        require(ok && ret.length == 32, "operatorflow: Router.tokenAddress() reverted");
        return abi.decode(ret, (address));
    }
}
