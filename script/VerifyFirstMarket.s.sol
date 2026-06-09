// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";
import {IEXManager} from "@kinetiq/launch/src/interfaces/IEXManager.sol";
import {IHyperCoreActivatable} from "@kinetiq/launch/src/interfaces/IHyperCoreActivatable.sol";
import {IL1Read} from "@kinetiq/launch/src/interfaces/IL1Read.sol";
import {ILaunchFeeSplitter} from "@kinetiq/launch/src/interfaces/ILaunchFeeSplitter.sol";
import {IStakeFeesThrottle} from "@kinetiq/launch/src/interfaces/IStakeFeesThrottle.sol";
import {IStakingManagerState} from "@kinetiq/launch/src/interfaces/IStakingManagerState.sol";

import {IStakingManager} from "@kinetiq/lst/src/interfaces/IStakingManager.sol";

import {DeployHelpers} from "./lib/DeployHelpers.sol";

/// @title VerifyFirstMarket
/// @notice Read-only per-phase verification harness for `DeployFirstMarket`. Mirrors the
///         `SmokeTest.s.sol` pattern at the per-market layer — one external entry per
///         DeployFirstMarket phase, takes (configPath, label), asserts the full set of
///         EVM + HC invariants for that phase, reverts loudly on first mismatch.
///
/// @dev    Pure reads — no broadcasts, no JSON writes, no state mutation. The HC-side checks
///         (`coreUserExists`, `spotBalance`, `delegatorSummary`) use `vm.rpc` to query the
///         L1Read precompiles directly via JSON-RPC, bypassing forge's local EVM which has no
///         bytecode at precompile addresses like `0x0810`. All four entrypoints are non-view
///         (vm.rpc + vm.label are non-view in forge-std) — still purely read-only semantically.
///
/// @dev    Usage:
///         forge script script/VerifyFirstMarket.s.sol:VerifyFirstMarket \
///           --sig 'verifyDeployMarket(string,string)' $CONFIG_JSON firstMarket \
///           --rpc-url $RPC_URL
contract VerifyFirstMarket is Script {
    using stdJson for string;
    using DeployHelpers for string;

    /* ========== Role constants ========== */

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
    bytes32 internal constant SENTINEL_ROLE = keccak256("SENTINEL_ROLE");
    bytes32 internal constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");
    bytes32 internal constant WALLET_ROLE = keccak256("WALLET_ROLE");
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /* ========== PHASE 1: verifyDeployMarket ========== */

    /// @notice Asserts that the market was deployed correctly. Idempotent + re-runnable on any
    ///         deployed market regardless of subsequent phase (activated/bonded/cancelled). Only
    ///         checks deployment validity — does NOT assert phase-transient state like
    ///         `bonded == false`. Run phase-specific verifies (verifyBondMarket, verifyCancelMarket)
    ///         for downstream phases.
    function verifyDeployMarket(string memory configPath, string memory label) external {
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        _requireMarket(config, label);

        console.log("================ verifyDeployMarket ================");
        console.log("label:", label);

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        string memory base = DeployHelpers.marketPath(label);

        // ---- 1. JSON state ----
        bytes32 marketId = config.readBytes32(string.concat(base, ".deployed.marketId"));
        address exManager = config.readAddress(string.concat(base, ".deployed.exManager"));
        require(marketId != bytes32(0), "verify: JSON marketId is zero");
        require(exManager != address(0), "verify: JSON exManager is zero");

        // If cancelled, market is deleted from factory — verifyCancelMarket handles that case.
        require(
            !config.readBool(string.concat(base, ".deployed.cancelled")),
            "verify: market is cancelled, use verifyCancelMarket instead"
        );

        // ---- 2. Factory MarketInfo (skip checks that mutate post-bond) ----
        IEXFactory.MarketInfo memory info = f.getMarket(marketId);
        require(info.exManager == exManager, "verify: factory.exManager != JSON.exManager");
        require(info.exManager != address(0), "verify: market not registered in factory");
        require(info.cancelEligibleAt > 0, "verify: cancelEligibleAt should be set at deploy time");

        // ---- 3. Identity params match JSON (admin/operator/enclaver). Skip opBond — that's
        //         verified by verifyBondMarket since opBondEscrowed mutates post-bond.
        address adminParam = config.readAddress(string.concat(base, ".params.admin"));
        address operatorParam = config.readAddress(string.concat(base, ".params.operator"));
        address enclaverParam = config.readAddress(string.concat(base, ".params.enclaver"));
        require(info.admin == adminParam, "verify: MarketInfo.admin != params.admin");
        require(info.operator == operatorParam, "verify: MarketInfo.operator != params.operator");
        require(info.enclaver == enclaverParam, "verify: MarketInfo.enclaver != params.enclaver");

        // ---- 4. Reverse mapping + isMarket ----
        require(f.exManagerToMarketId(exManager) == marketId, "verify: factory.exManagerToMarketId reverse mismatch");
        require(f.isMarket(exManager), "verify: factory.isMarket(exManager) is false");

        // ---- 5. MarketContracts: all 13 fields non-zero, exManager matches ----
        IEXFactory.MarketContracts memory mc = f.getMarketContracts(marketId);
        require(mc.router != address(0), "verify: mc.router is zero");
        require(mc.exManager == exManager, "verify: mc.exManager != JSON.exManager");
        require(mc.exLST != address(0), "verify: mc.exLST is zero");
        require(mc.stakingAccountant != address(0), "verify: mc.stakingAccountant is zero");
        require(mc.validatorManager != address(0), "verify: mc.validatorManager is zero");
        require(mc.oracleManager != address(0), "verify: mc.oracleManager is zero");
        require(mc.rewardShareTracker != address(0), "verify: mc.rewardShareTracker is zero");
        require(mc.ghostLST != address(0), "verify: mc.ghostLST is zero");
        require(mc.bwq != address(0), "verify: mc.bwq is zero");
        require(mc.defaultOracle != address(0), "verify: mc.defaultOracle is zero");
        require(mc.oracleAdapter != address(0), "verify: mc.oracleAdapter is zero");
        require(mc.launchFeeSplitter != address(0), "verify: mc.launchFeeSplitter is zero");
        require(mc.stakeFeesThrottle != address(0), "verify: mc.stakeFeesThrottle is zero");

        // ---- 6. opBondEscrowed (lifecycle-aware): pre-bond == params.opBond; post-bond == 0
        uint256 opBondParam = config.readUint(string.concat(base, ".params.opBond"));
        if (!info.bonded) {
            require(info.opBondEscrowed == opBondParam, "verify: pre-bond opBondEscrowed != params.opBond");
        } else {
            require(info.opBondEscrowed == 0, "verify: post-bond opBondEscrowed should be 0");
        }

        // ---- 7. LST + Launch wiring (Router refs + EXManager refs + LFS/Throttle refs) ----
        _verifyLstWiring(f, mc);
        _verifyLaunchWiring(config, base, f, mc, info);

        // ---- 8. Role assignments (controller-held + factory-held + per-market identifiers) ----
        _verifyRoles(config, mc, info);

        console.log("[verifyDeployMarket] PASSED  marketId:", vm.toString(marketId));
        console.log("[verifyDeployMarket]         exManager:", exManager);
        console.log("[verifyDeployMarket]         opBondEscrowed:", info.opBondEscrowed);
    }

    /// @dev Verify Router (KIP-2 diamond) refs match the per-market contract suite. Other LST
    ///      contracts (ValidatorManager / OracleManager / RewardShareTracker / StakingAccountant)
    ///      get their cross-references checked transitively via Router.* — fewer assertions, same
    ///      coverage if Router is wired correctly.
    function _verifyLstWiring(IEXFactory f, IEXFactory.MarketContracts memory mc) internal view {
        IStakingManagerState router = IStakingManagerState(mc.router);
        require(address(router.validatorManager()) == mc.validatorManager, "verify: Router.validatorManager mismatch");
        require(
            address(router.stakingAccountant()) == mc.stakingAccountant, "verify: Router.stakingAccountant mismatch"
        );
        require(address(router.tokenAddress()) == mc.ghostLST, "verify: Router.tokenAddress != ghostLST");
        require(router.treasury() == mc.exManager, "verify: Router.treasury != exManager");
        require(
            address(router.pauserRegistry()) == address(f.pauserRegistry()), "verify: Router.pauserRegistry mismatch"
        );
        require(router.whitelistEnabled(), "verify: Router whitelist not enabled");
    }

    /// @dev Verify Launch-layer contract wiring: EXManager refs to per-market suite, fee-distribution
    ///      contracts (LFS + Throttle), and JSON params (gate, marketTier, opBond, deployerTreasury,
    ///      buybackBps) all flow through correctly.
    function _verifyLaunchWiring(
        string memory config,
        string memory base,
        IEXFactory f,
        IEXFactory.MarketContracts memory mc,
        IEXFactory.MarketInfo memory info
    ) internal view {
        address globalConfig = address(f.globalConfig());
        address pauserRegistry = address(f.pauserRegistry());

        // EXManager wiring
        IEXManager exMgr = IEXManager(mc.exManager);
        require(exMgr.factory() == address(f), "verify: EXManager.factory mismatch");
        require(address(exMgr.exStakingManager()) == mc.router, "verify: EXManager.exStakingManager != Router");
        require(address(exMgr.exLST()) == mc.exLST, "verify: EXManager.exLST mismatch");
        require(
            address(exMgr.exStakingAccountant()) == mc.stakingAccountant,
            "verify: EXManager.exStakingAccountant mismatch"
        );
        require(address(exMgr.blockedWithdrawalQueue()) == mc.bwq, "verify: EXManager.blockedWithdrawalQueue mismatch");
        require(address(exMgr.globalConfig()) == globalConfig, "verify: EXManager.globalConfig mismatch");
        require(address(exMgr.pauserRegistry()) == pauserRegistry, "verify: EXManager.pauserRegistry mismatch");
        require(
            address(exMgr.gate()) == config.readAddress(string.concat(base, ".params.gate")),
            "verify: EXManager.gate mismatch"
        );
        require(
            exMgr.marketTier() == config.readUint(string.concat(base, ".params.marketTier")),
            "verify: EXManager.marketTier mismatch"
        );
        require(exMgr.deployer() == info.deployer, "verify: EXManager.deployer != MarketInfo.deployer");

        // LaunchFeeSplitter wiring
        ILaunchFeeSplitter lfs = ILaunchFeeSplitter(mc.launchFeeSplitter);
        require(address(lfs.globalConfig()) == globalConfig, "verify: LFS.globalConfig mismatch");
        require(
            lfs.deployerTreasury() == config.readAddress(string.concat(base, ".params.deployerTreasury")),
            "verify: LFS.deployerTreasury != params.deployerTreasury"
        );
        require(
            uint256(lfs.buybackBps()) == config.readUint(string.concat(base, ".params.buybackBps")),
            "verify: LFS.buybackBps != params.buybackBps"
        );

        // StakeFeesThrottle wiring
        IStakeFeesThrottle throttle = IStakeFeesThrottle(mc.stakeFeesThrottle);
        require(address(throttle.globalConfig()) == globalConfig, "verify: Throttle.globalConfig mismatch");
        require(address(throttle.exManager()) == mc.exManager, "verify: Throttle.exManager mismatch");
        require(
            uint256(throttle.hypeTokenId()) == config.readUint(".hyperliquid.hypeTokenId"),
            "verify: Throttle.hypeTokenId mismatch"
        );
    }

    /// @dev Verify role assignments per the KDD-9 model:
    ///      - Controller holds DEFAULT_ADMIN_ROLE on all 6 per-market LST contracts (Router,
    ///        ValidatorManager, StakingAccountant, OracleManager, RewardShareTracker, GhostLST)
    ///        + EXLST + DefaultOracle. Factory has renounced its admin on all of these.
    ///      - Router additionally has TREASURY_ROLE + SENTINEL_ROLE granted to controller.
    ///      - GhostLST.MINTER_ROLE + BURNER_ROLE held by Router.
    ///      - EXLST.MINTER_ROLE + BURNER_ROLE held by EXManager.
    ///      - EXManager: factory RETAINS DEFAULT_ADMIN_ROLE (used by transferOperator/Admin/Enclaver).
    ///        params.operator holds OPERATOR_ROLE; controller holds RECOVERY_ROLE (via params.recoverer);
    ///        params.enclaver holds WALLET_ROLE.
    function _verifyRoles(string memory config, IEXFactory.MarketContracts memory mc, IEXFactory.MarketInfo memory info)
        internal
        view
    {
        address controller = config.readDeployedAddress("ProtocolRolesController");
        address factory = config.readDeployedAddress("EXFactory");

        // ---- LST contracts: controller holds DEFAULT_ADMIN_ROLE; factory renounced ----
        address[6] memory lst = [
            mc.router, mc.validatorManager, mc.stakingAccountant, mc.oracleManager, mc.rewardShareTracker, mc.ghostLST
        ];
        for (uint256 i = 0; i < lst.length; i++) {
            require(
                IAccessControl(lst[i]).hasRole(DEFAULT_ADMIN_ROLE, controller),
                "verify: controller missing DEFAULT_ADMIN on LST contract"
            );
            require(
                !IAccessControl(lst[i]).hasRole(DEFAULT_ADMIN_ROLE, factory),
                "verify: factory still has DEFAULT_ADMIN on LST contract"
            );
        }
        // Router-only extra roles
        require(
            IAccessControl(mc.router).hasRole(TREASURY_ROLE, controller),
            "verify: controller missing TREASURY_ROLE on Router"
        );
        require(
            IAccessControl(mc.router).hasRole(SENTINEL_ROLE, controller),
            "verify: controller missing SENTINEL_ROLE on Router"
        );

        // ---- EXLST: controller admin + EXManager mint/burn ----
        require(
            IAccessControl(mc.exLST).hasRole(DEFAULT_ADMIN_ROLE, controller),
            "verify: controller missing DEFAULT_ADMIN on EXLST"
        );
        require(
            !IAccessControl(mc.exLST).hasRole(DEFAULT_ADMIN_ROLE, factory),
            "verify: factory still has DEFAULT_ADMIN on EXLST"
        );
        require(
            IAccessControl(mc.exLST).hasRole(MINTER_ROLE, mc.exManager),
            "verify: EXManager missing MINTER_ROLE on EXLST"
        );
        require(
            IAccessControl(mc.exLST).hasRole(BURNER_ROLE, mc.exManager),
            "verify: EXManager missing BURNER_ROLE on EXLST"
        );

        // ---- GhostLST: Router mint/burn ----
        require(
            IAccessControl(mc.ghostLST).hasRole(MINTER_ROLE, mc.router),
            "verify: Router missing MINTER_ROLE on GhostLST"
        );
        require(
            IAccessControl(mc.ghostLST).hasRole(BURNER_ROLE, mc.router),
            "verify: Router missing BURNER_ROLE on GhostLST"
        );

        // ---- DefaultOracle: controller admin ----
        require(
            IAccessControl(mc.defaultOracle).hasRole(DEFAULT_ADMIN_ROLE, controller),
            "verify: controller missing DEFAULT_ADMIN on DefaultOracle"
        );

        // ---- EXManager: factory retains DEFAULT_ADMIN; operator/enclaver/recoverer per init ----
        require(
            IAccessControl(mc.exManager).hasRole(DEFAULT_ADMIN_ROLE, factory),
            "verify: factory missing DEFAULT_ADMIN on EXManager"
        );
        require(
            IAccessControl(mc.exManager).hasRole(OPERATOR_ROLE, info.operator),
            "verify: operator missing OPERATOR_ROLE on EXManager"
        );
        require(
            IAccessControl(mc.exManager).hasRole(RECOVERY_ROLE, controller),
            "verify: controller missing RECOVERY_ROLE on EXManager"
        );
        require(
            IAccessControl(mc.exManager).hasRole(WALLET_ROLE, info.enclaver),
            "verify: enclaver missing WALLET_ROLE on EXManager"
        );
    }

    /* ========== PHASE 2: verifyActivateMarket ========== */

    /// @notice Asserts HC-side state after the activation token bridge settles (~1 HyperEVM block ~1s).
    /// @dev    Uses `vm.rpc` to query L1Read precompiles directly via JSON-RPC. Non-view since
    ///         `vm.rpc` is non-view in forge-std. Still purely read-only semantically.
    function verifyActivateMarket(string memory configPath, string memory label) external {
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        _requireMarket(config, label);

        console.log("================ verifyActivateMarket ================");
        console.log("label:", label);

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        string memory base = DeployHelpers.marketPath(label);
        bytes32 marketId = config.readBytes32(string.concat(base, ".deployed.marketId"));
        require(marketId != bytes32(0), "verify: JSON marketId is zero (run verifyDeployMarket first)");

        IEXFactory.MarketContracts memory mc = f.getMarketContracts(marketId);
        uint64 usdcTokenId = uint64(config.readUint(string.concat(base, ".activation.tokenId")));
        address l1Read = config.readAddress(".hyperliquid.l1Read");

        // ---- HC-side coreUserExists for the 3 activation targets ----
        require(_coreUserExistsRPC(l1Read, mc.router), "verify: Router not HC-active");
        require(_coreUserExistsRPC(l1Read, mc.launchFeeSplitter), "verify: LaunchFeeSplitter not HC-active");
        require(_coreUserExistsRPC(l1Read, mc.stakeFeesThrottle), "verify: StakeFeesThrottle not HC-active");

        // ---- Launch-side activated() on every HyperCoreActivatable inheritor ----
        // Calls `.activated()` via vm.rpc so the contract's internal `l1Read.coreUserExists` precompile
        // call executes on the live HyperEVM (forge's local EVM can't run precompiles).
        // EXManager.activated() reads coreUserExists(exStakingManager); LFS + Throttle read self.
        require(_activatedRPC(mc.exManager), "verify: EXManager.activated() returned false");
        require(_activatedRPC(mc.launchFeeSplitter), "verify: LaunchFeeSplitter.activated() returned false");
        require(_activatedRPC(mc.stakeFeesThrottle), "verify: StakeFeesThrottle.activated() returned false");

        // ---- USDC spot balance on HC for each activation target ----
        uint64 routerTotal = _spotBalanceTotalRPC(l1Read, mc.router, usdcTokenId);
        uint64 lfsTotal = _spotBalanceTotalRPC(l1Read, mc.launchFeeSplitter, usdcTokenId);
        uint64 throttleTotal = _spotBalanceTotalRPC(l1Read, mc.stakeFeesThrottle, usdcTokenId);
        require(routerTotal > 0, "verify: Router HC USDC spot balance is zero");
        require(lfsTotal > 0, "verify: LaunchFeeSplitter HC USDC spot balance is zero");
        require(throttleTotal > 0, "verify: StakeFeesThrottle HC USDC spot balance is zero");

        console.log("[verifyActivateMarket] PASSED");
        console.log("  Router HC USDC spot.total:   ", routerTotal);
        console.log("  LFS HC USDC spot.total:      ", lfsTotal);
        console.log("  Throttle HC USDC spot.total: ", throttleTotal);
    }

    /* ========== PHASE 3: verifyBondMarket ========== */

    /// @notice Asserts EVM + HC state after `factory.bondMarket(marketId)` lands. Accepts both
    ///         pre-processL1Operations (`undelegated == opBond, delegated == 0`) and post-
    ///         processL1Operations (`undelegated == 0, delegated == opBond`) states — both are
    ///         valid bondMarket-passed states.
    function verifyBondMarket(string memory configPath, string memory label) external {
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        _requireMarket(config, label);

        console.log("================ verifyBondMarket ================");
        console.log("label:", label);

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        string memory base = DeployHelpers.marketPath(label);
        bytes32 marketId = config.readBytes32(string.concat(base, ".deployed.marketId"));
        require(marketId != bytes32(0), "verify: JSON marketId is zero");

        IEXFactory.MarketContracts memory mc = f.getMarketContracts(marketId);
        IEXFactory.MarketInfo memory info = f.getMarket(marketId);
        uint256 opBondParam = config.readUint(string.concat(base, ".params.opBond"));

        // ---- Factory MarketInfo ----
        require(info.bonded, "verify: MarketInfo.bonded should be true");
        require(info.opBondEscrowed == 0, "verify: MarketInfo.opBondEscrowed should be 0 (escrow moved out)");

        // ---- JSON ----
        require(config.readBool(string.concat(base, ".deployed.bonded")), "verify: JSON .bonded should be true");

        // ---- EXManager state ----
        IEXManager exMgr = IEXManager(mc.exManager);
        require(uint8(exMgr.exPhase()) == 1, "verify: EXManager.exPhase != FUNDING (1)");
        require(exMgr.opBond() == opBondParam, "verify: EXManager.opBond != params.opBond");

        // ---- exLST + ghostLST: 1:1 initial mint to EXManager (operator's escrowed share) ----
        IERC20 exLST = IERC20(mc.exLST);
        IERC20 ghost = IERC20(mc.ghostLST);
        require(exLST.totalSupply() == opBondParam, "verify: exLST.totalSupply != params.opBond");
        require(exLST.balanceOf(mc.exManager) == opBondParam, "verify: exLST.balanceOf(EXManager) != params.opBond");
        require(ghost.totalSupply() == opBondParam, "verify: ghostLST.totalSupply != params.opBond");
        require(ghost.balanceOf(mc.exManager) == opBondParam, "verify: ghostLST.balanceOf(EXManager) != params.opBond");
        require(ghost.balanceOf(mc.router) == 0, "verify: ghostLST.balanceOf(Router) should be 0");

        // ---- Router LST state (delegatecalls AdminFacet via fallback) ----
        require(IStakingManager(mc.router).totalStaked() == opBondParam, "verify: Router.totalStaked != params.opBond");

        // ---- HC Router delegator summary (via vm.rpc) ----
        address l1Read = config.readAddress(".hyperliquid.l1Read");
        IL1Read.DelegatorSummary memory ds = _delegatorSummaryRPC(l1Read, mc.router);
        uint256 expectedTotal8 = opBondParam / 1e10; // 18-decimal HYPE -> 8-decimal HC representation
        // Accept pre- or post-processL1Operations state. Use `>=` to tolerate validator-reward
        // accrual over time (delegated stake grows continuously while bonded).
        require(
            uint256(ds.delegated) + uint256(ds.undelegated) >= expectedTotal8,
            "verify: Router HC delegated+undelegated < params.opBond/1e10 (HYPE bridge may not have settled)"
        );

        // ---- Router queue (admin facet getQueueInfo, accessed via Router fallback) ----
        (,, uint256 depositLength, uint256 depositIndex,, uint256 unprocessedDeposits) =
            IStakingManager(mc.router).getQueueInfo();
        bool preProcess = depositLength == 1 && depositIndex == 0 && unprocessedDeposits == 1;
        bool postProcess = unprocessedDeposits == 0;
        require(
            preProcess || postProcess,
            "verify: Router queue state unexpected (neither pre- nor post-processL1Operations)"
        );

        console.log("[verifyBondMarket] PASSED");
        console.log("  HC delegated:    ", ds.delegated);
        console.log("  HC undelegated:  ", ds.undelegated);
        console.log("  queue unprocessedDeposits:", unprocessedDeposits);
    }

    /* ========== PHASE 4: verifyCancelMarket ========== */

    /// @notice Asserts factory registry cleanup after `factory.cancelMarket(marketId, recipient)` lands.
    function verifyCancelMarket(string memory configPath, string memory label) external {
        string memory config = vm.readFile(configPath);
        DeployHelpers.labelDeployed(config);
        _requireMarket(config, label);

        console.log("================ verifyCancelMarket ================");
        console.log("label:", label);

        IEXFactory f = IEXFactory(config.readDeployedAddress("EXFactory"));
        string memory base = DeployHelpers.marketPath(label);
        bytes32 marketId = config.readBytes32(string.concat(base, ".deployed.marketId"));
        address exManagerJson = config.readAddress(string.concat(base, ".deployed.exManager"));
        require(marketId != bytes32(0), "verify: JSON marketId is zero");
        require(exManagerJson != address(0), "verify: JSON exManager is zero");

        // ---- JSON ----
        require(config.readBool(string.concat(base, ".deployed.cancelled")), "verify: JSON .cancelled should be true");

        // ---- Factory registry cleared ----
        IEXFactory.MarketInfo memory info = f.getMarket(marketId);
        require(info.exManager == address(0), "verify: MarketInfo.exManager not cleared");
        require(!info.bonded, "verify: MarketInfo.bonded should be false (all-zeros)");
        require(info.opBondEscrowed == 0, "verify: MarketInfo.opBondEscrowed should be 0");
        require(f.exManagerToMarketId(exManagerJson) == bytes32(0), "verify: reverse mapping not cleared");
        require(!f.isMarket(exManagerJson), "verify: factory.isMarket(exManager) should be false");

        // ---- Recipient address must be non-zero ----
        address recipient = config.readAddress(string.concat(base, ".cancelRecipient"));
        require(recipient != address(0), "verify: cancelRecipient is zero");

        console.log("[verifyCancelMarket] PASSED");
        console.log("  recipient:", recipient);
    }

    /* ========== HELPERS ========== */

    function _requireMarket(string memory config, string memory label) internal view {
        require(config.hasMarket(label), string.concat("verify: no market entry with label '", label, "' in .markets"));
    }

    /// @dev `vm.rpc("eth_call", params)` returns the raw return data from a remote eth_call,
    ///      bypassing forge's local EVM. Critical for L1Read precompile queries since the
    ///      precompiles have no bytecode for forge to fetch.
    function _ethCallRPC(address to, bytes memory data) internal returns (bytes memory) {
        string memory params =
            string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"latest"]');
        return vm.rpc("eth_call", params);
    }

    /// @dev Calls the L1Read **wrapper contract** (`.hyperliquid.l1Read` from config — a Solidity
    ///      contract that internally translates selector-style ABI calls into the raw-encoded
    ///      format the underlying precompile expects). Calling the raw precompile (0x0810) with
    ///      a selector-prefixed payload returns PrecompileError.
    function _coreUserExistsRPC(address l1Read, address user) internal returns (bool) {
        bytes memory cd = abi.encodeWithSelector(IL1Read.coreUserExists.selector, user);
        bytes memory ret = _ethCallRPC(l1Read, cd);
        IL1Read.CoreUserExists memory r = abi.decode(ret, (IL1Read.CoreUserExists));
        return r.exists;
    }

    function _spotBalanceTotalRPC(address l1Read, address user, uint64 token) internal returns (uint64) {
        bytes memory cd = abi.encodeWithSelector(IL1Read.spotBalance.selector, user, token);
        bytes memory ret = _ethCallRPC(l1Read, cd);
        IL1Read.SpotBalance memory r = abi.decode(ret, (IL1Read.SpotBalance));
        return r.total;
    }

    function _delegatorSummaryRPC(address l1Read, address user) internal returns (IL1Read.DelegatorSummary memory) {
        bytes memory cd = abi.encodeWithSelector(IL1Read.delegatorSummary.selector, user);
        bytes memory ret = _ethCallRPC(l1Read, cd);
        return abi.decode(ret, (IL1Read.DelegatorSummary));
    }

    /// @dev Call `.activated()` on a HyperCoreActivatable inheritor via vm.rpc. Bypasses forge's
    ///      local EVM so the contract's internal `l1Read.coreUserExists(...)` precompile call
    ///      executes natively on HyperEVM. Returns the real activation state.
    function _activatedRPC(address ctrt) internal returns (bool) {
        bytes memory cd = abi.encodeWithSelector(IHyperCoreActivatable.activated.selector);
        bytes memory ret = _ethCallRPC(ctrt, cd);
        return abi.decode(ret, (bool));
    }
}
