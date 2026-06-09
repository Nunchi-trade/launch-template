// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {MinimalImplementation} from "@kinetiq/lst/src/lib/MinimalImplementation.sol";

import {IEXFactory} from "@kinetiq/launch/src/interfaces/IEXFactory.sol";

/// @title DeployHelpers
/// @notice Internal-only library used by DeployCore / DeployFirstMarket / SmokeTest. Wraps the
///         common forge-script idioms — TUP deployment via CREATE2 with config-keyed salt,
///         atomic `upgradeAndCall`, ProxyAdmin extraction + handover, and JSON read/write
///         helpers with `keyExists` fallbacks. Patterned on the V1 deploy scripts (branch
///         `feature/kntq-874-deploy-scripts-deposit-and-fund`) but ported to the V2 protocol
///         surface.
library DeployHelpers {
    using stdJson for string;

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Raised by `networkNameToChainId` when the deployer's marketConfig
    ///         names a network this script has no chainId mapping for.
    error UnknownNetwork(string name);

    /// @notice Raised when the marketConfig's `network.chainId` value does not
    ///         match what `networkNameToChainId(network.name)` resolves to.
    error NetworkChainIdMismatch(string name, uint256 expected, uint256 claimed);

    /// @notice Raised when the RPC's `block.chainid` does not match the marketConfig's
    ///         `network.chainId`. Catches running a marketConfig against the wrong RPC.
    error RpcChainIdMismatch(uint256 rpcChainId, uint256 marketConfigChainId);

    /// @notice Raised by `buildMarketParams` when a MarketParams field is absent from
    ///         both the deployer's marketConfig and the resolved globalConfig.
    error MissingMarketParam(string field);

    /// @notice Deploys a TUP pointing at the caller-supplied `minimalImpl` so the proxy address can
    ///         be pinned before its real implementation is known. The proxy's auto-created
    ///         ProxyAdmin is owned by `owner` (typically the script's broadcasting EOA).
    /// @dev    Uses CREATE2 with salt = keccak256(configKey) + saltShift. Determinism lets us
    ///         predict addresses for circular bootstraps (factory ↔ controller ↔ deployer) before
    ///         either is initialized. The deployed address is written back to
    ///         `.deployed.<configKey>` immediately so resume-after-failure works.
    /// @param  configPath  Path to the network JSON config (used by vm.writeJson).
    /// @param  configKey   Unique key under `.deployed.*` (e.g., "EXFactory").
    /// @param  owner       ProxyAdmin owner during deploy + init (script EOA).
    /// @param  saltShift   Numeric offset baked into the CREATE2 salt (lets re-runs bump fresh).
    /// @param  minimalImpl Shared MinimalImplementation deployed once per script run.
    /// @return proxy       The new TUP.
    /// @return proxyAdmin  The auto-created ProxyAdmin owned by `owner`.
    function deployProxy(
        string memory configPath,
        string memory configKey,
        address owner,
        uint256 saltShift,
        MinimalImplementation minimalImpl
    ) internal returns (TransparentUpgradeableProxy proxy, address proxyAdmin) {
        bytes32 salt = bytes32(uint256(keccak256(bytes(configKey))) + saltShift);
        proxy = new TransparentUpgradeableProxy{salt: salt}(address(minimalImpl), owner, "");
        proxyAdmin = getProxyAdmin(address(proxy));
        writeJsonAddress(configPath, string.concat(".deployed.", configKey), address(proxy));
    }

    /// @notice Atomically swaps a TUP's implementation and invokes its `initialize` in one tx.
    /// @dev    Closes the front-run window between proxy deploy and init — `initialize` cannot
    ///         be hijacked because impl swap + init are inseparable from `ProxyAdmin`'s
    ///         perspective.
    function upgradeAndInit(address proxyAdmin, address proxy, address impl, bytes memory initData) internal {
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, initData);
    }

    /// @notice Reads `ERC1967Utils.ADMIN_SLOT` on a TUP to recover its ProxyAdmin.
    /// @dev    OZ's TUP auto-creates a ProxyAdmin inside its constructor; there is no
    ///         constructor argument exposing it, so we read the EIP-1967 slot directly.
    function getProxyAdmin(address proxy) internal view returns (address admin) {
        bytes32 adminSlot = vm.load(proxy, ERC1967Utils.ADMIN_SLOT);
        admin = address(uint160(uint256(adminSlot)));
    }

    /// @notice Transfers ownership of a ProxyAdmin to the network admin (final handover step).
    function transferProxyAdminOwnership(address proxyAdmin, address newOwner) internal {
        ProxyAdmin(proxyAdmin).transferOwnership(newOwner);
    }

    /* ========== JSON READ HELPERS ========== */

    /// @notice Reads an address at `key`; returns address(0) if the key is missing.
    function readOptionalAddress(string memory config, string memory key) internal view returns (address) {
        if (!config.keyExists(key)) return address(0);
        return config.readAddress(key);
    }

    /// @notice Reads a uint at `key`; returns 0 if the key is missing.
    function readOptionalUint(string memory config, string memory key) internal view returns (uint256) {
        if (!config.keyExists(key)) return 0;
        return config.readUint(key);
    }

    /// @notice Returns true if `.deployed.<configKey>` is already populated (skip-if-deployed gate).
    function isAlreadyDeployed(string memory config, string memory configKey) internal view returns (bool) {
        string memory key = string.concat(".deployed.", configKey);
        if (!config.keyExists(key)) return false;
        return config.readAddress(key) != address(0);
    }

    /// @notice Reads `.deployed.<configKey>` (reverts if missing — for required prerequisites).
    function readDeployedAddress(string memory config, string memory configKey) internal view returns (address) {
        return config.readAddress(string.concat(".deployed.", configKey));
    }

    /// @notice Iterates `keyExists("<path>[<i>].<probeField>")` from i=0 until first miss; returns
    ///         the discovered length. V1 pattern — handles dynamic JSON arrays of nested objects
    ///         since stdJson doesn't expose `parseJsonArrayLength` for nested-object paths.
    function arrayLength(string memory config, string memory arrayPath, string memory probeField)
        internal
        view
        returns (uint256 len)
    {
        for (uint256 i = 0; i < 1000; i++) {
            string memory probe = string.concat(arrayPath, "[", uintToString(i), "].", probeField);
            if (!config.keyExists(probe)) return i;
        }
        revert("DeployHelpers: array too long (>1000)");
    }

    /// @notice Returns the JSON path prefix `.markets.<label>` for a per-market lookup.
    /// @dev    `markets` is a keyed object (not an array) in the JSON config — keyed by label —
    ///         because forge's `vm.writeJson` only supports dot-separated object key paths
    ///         (array-index syntax like `.markets[i]` gets interpreted as a literal key
    ///         and `.markets.<i>` errors out as "not an object"). Reverts in the caller
    ///         (via stdJson) if the label doesn't exist in the JSON.
    function marketPath(string memory label) internal pure returns (string memory) {
        return string.concat(".markets.", label);
    }

    /// @notice Returns true if `.markets.<label>` exists in the config.
    function hasMarket(string memory config, string memory label) internal view returns (bool) {
        return config.keyExists(marketPath(label));
    }

    /* ========== JSON WRITE HELPERS ========== */

    /// @notice Writes a deployed address back to the config file under `.deployed.<key>`.
    /// @dev    `vm.writeJson` does a read-modify-write on the JSON file. Each call rewrites the
    ///         file, so failures between writes preserve previously-recorded addresses.
    function writeJsonAddress(string memory configPath, string memory key, address value) internal {
        vm.writeJson(vm.toString(value), configPath, key);
    }

    function writeJsonBytes32(string memory configPath, string memory key, bytes32 value) internal {
        vm.writeJson(vm.toString(value), configPath, key);
    }

    function writeJsonBool(string memory configPath, string memory key, bool value) internal {
        vm.writeJson(value ? "true" : "false", configPath, key);
    }

    /* ========== MARKET CONFIG + NETWORK ========== */

    /// @notice Maps a network name (as stored under `.network.name` in the deployer's
    ///         marketConfig) to its expected EVM chain id. Reverts `UnknownNetwork(name)`
    ///         when the name is not in the static mapping.
    function networkNameToChainId(string memory name) internal pure returns (uint256) {
        bytes32 nameHash = keccak256(bytes(name));
        if (nameHash == keccak256("mainnet")) return 999;
        if (nameHash == keccak256("mainnet-dryrun")) return 999;
        if (nameHash == keccak256("testnet")) return 998;
        if (nameHash == keccak256("local")) return 31337;
        revert UnknownNetwork(name);
    }

    /// @notice Pre-flights a deployer's marketConfig + resolves the matching globalConfig.
    ///         Asserts (1) the marketConfig's claimed chainId matches the static mapping
    ///         for its network name, and (2) the RPC's `block.chainid` matches the
    ///         marketConfig's chainId. Returns the loaded JSON strings + the resolved
    ///         network name for downstream callers.
    /// @dev    `globalConfigPath` is optional: pass an empty string to use the network-
    ///         derived default (`script/config/globals/<networkName>.json`); pass an
    ///         explicit path to override. The override knob lets a deployer point at a
    ///         custom globalConfig (fork tests, alternate deployments, etc.) without
    ///         forking the script.
    /// @return marketConfigJson  Contents of `marketConfigPath` (read once).
    /// @return globalConfigJson  Contents of the resolved globalConfig path.
    /// @return networkName       The network name extracted from the marketConfig.
    function preflightMarketConfig(string memory marketConfigPath, string memory globalConfigPath)
        internal
        returns (string memory marketConfigJson, string memory globalConfigJson, string memory networkName)
    {
        marketConfigJson = vm.readFile(marketConfigPath);
        networkName = marketConfigJson.readString(".network.name");
        uint256 marketConfigChainId = marketConfigJson.readUint(".network.chainId");
        uint256 expectedChainId = networkNameToChainId(networkName);
        if (marketConfigChainId != expectedChainId) {
            revert NetworkChainIdMismatch(networkName, expectedChainId, marketConfigChainId);
        }
        if (block.chainid != marketConfigChainId) {
            revert RpcChainIdMismatch(block.chainid, marketConfigChainId);
        }
        if (bytes(globalConfigPath).length == 0) {
            globalConfigPath = string.concat("script/config/globals/", networkName, ".json");
        }
        globalConfigJson = vm.readFile(globalConfigPath);
    }

    /// @notice Builds a MarketParams struct by reading each field from the deployer's
    ///         marketConfig first (under `.evm.marketParams.<field>`); falls back to the
    ///         globalConfig (under `.markets.<field>`) for any field the deployer didn't
    ///         supply. Reverts `MissingMarketParam(field)` if a field is absent from both.
    /// @dev    The deployer-vs-pinned split is driven entirely by what's present in the
    ///         deployer's marketConfig — no hardcoded field categories in this helper.
    function buildMarketParams(string memory marketConfigJson, string memory globalConfigJson)
        internal
        view
        returns (IEXFactory.MarketParams memory p)
    {
        p.admin = _resolveAddressField(marketConfigJson, globalConfigJson, "admin");
        p.operator = _resolveAddressField(marketConfigJson, globalConfigJson, "operator");
        p.enclaver = _resolveAddressField(marketConfigJson, globalConfigJson, "enclaver");
        p.opBond = _resolveUintField(marketConfigJson, globalConfigJson, "opBond");
        p.validator = _resolveAddressField(marketConfigJson, globalConfigJson, "validator");
        p.gate = _resolveAddressField(marketConfigJson, globalConfigJson, "gate");
        p.lstName = _resolveStringField(marketConfigJson, globalConfigJson, "lstName");
        p.lstSymbol = _resolveStringField(marketConfigJson, globalConfigJson, "lstSymbol");
        p.marketTier = _resolveUintField(marketConfigJson, globalConfigJson, "marketTier");
        p.hyperCoreDeployer = _resolveAddressField(marketConfigJson, globalConfigJson, "hyperCoreDeployer");
        p.deployerTreasury = _resolveAddressField(marketConfigJson, globalConfigJson, "deployerTreasury");
        p.buybackBps = uint64(_resolveUintField(marketConfigJson, globalConfigJson, "buybackBps"));
    }

    function _resolveAddressField(string memory marketConfig, string memory globalConfig, string memory field)
        private
        view
        returns (address)
    {
        string memory mp = string.concat(".evm.marketParams.", field);
        if (marketConfig.keyExists(mp)) return marketConfig.readAddress(mp);
        string memory gp = string.concat(".markets.", field);
        if (globalConfig.keyExists(gp)) return globalConfig.readAddress(gp);
        revert MissingMarketParam(field);
    }

    function _resolveUintField(string memory marketConfig, string memory globalConfig, string memory field)
        private
        view
        returns (uint256)
    {
        string memory mp = string.concat(".evm.marketParams.", field);
        if (marketConfig.keyExists(mp)) return marketConfig.readUint(mp);
        string memory gp = string.concat(".markets.", field);
        if (globalConfig.keyExists(gp)) return globalConfig.readUint(gp);
        revert MissingMarketParam(field);
    }

    function _resolveStringField(string memory marketConfig, string memory globalConfig, string memory field)
        private
        view
        returns (string memory)
    {
        string memory mp = string.concat(".evm.marketParams.", field);
        if (marketConfig.keyExists(mp)) return marketConfig.readString(mp);
        string memory gp = string.concat(".markets.", field);
        if (globalConfig.keyExists(gp)) return globalConfig.readString(gp);
        revert MissingMarketParam(field);
    }

    /* ========== TRACE LABELING ========== */

    /// @notice Label every DeployCore-produced address in the JSON config so `-vvvv` traces
    ///         show friendly names (e.g., "EXFactory", "AdminFacet") instead of raw 20-byte
    ///         hex. Covers the 8 protocol singletons + 11 beacon impls + 7 facet impls.
    /// @dev    Idempotent — `vm.label(addr, name)` is a no-op-write when called twice with
    ///         the same name, so it is safe to invoke this at the top of every script
    ///         entrypoint even when an outer entrypoint (e.g., `LifecycleRehearsal.run()`)
    ///         already labeled the same addresses and then delegates into inherited
    ///         entrypoints that re-call this. The only cost of repeated calls is trace
    ///         noise (`VM::label(...)` lines in `-vvvv`); on-chain state is untouched.
    ///         Per-market labels (`getMarketContracts(marketId)` outputs) are NOT handled
    ///         here — those are per-market and labeled by the caller after market resolution.
    ///         Caller must remove `view` from the entry function since `vm.label` is mutating.
    function labelDeployed(string memory config) internal {
        // ---- Protocol singletons (.deployed.<Key>) ----
        _labelIfDeployed(config, "GlobalConfig");
        _labelIfDeployed(config, "PauserRegistry");
        _labelIfDeployed(config, "FacetRegistry");
        _labelIfDeployed(config, "UpgradeableBeaconRegistry");
        _labelIfDeployed(config, "ProtocolRolesController");
        _labelIfDeployed(config, "EXDeployer");
        _labelIfDeployed(config, "EXFactory");
        _labelIfDeployed(config, "EXRouter");
        _labelIfDeployed(config, "MinimalImplementation");

        // ---- Beacon impls (.deployed.beaconImpls.<Name>) — labeled with "Impl" suffix ----
        _labelBeaconImpl(config, "StakingManagerRouter");
        _labelBeaconImpl(config, "EXManager");
        _labelBeaconImpl(config, "EXLST");
        _labelBeaconImpl(config, "StakingAccountant");
        _labelBeaconImpl(config, "ValidatorManager");
        _labelBeaconImpl(config, "OracleManager");
        _labelBeaconImpl(config, "RewardShareTracker");
        _labelBeaconImpl(config, "GhostLST");
        _labelBeaconImpl(config, "BlockedWithdrawalQueue");
        _labelBeaconImpl(config, "LaunchFeeSplitter");
        _labelBeaconImpl(config, "StakeFeesThrottle");

        // ---- Facet impls (.deployed.facets.<Name>) ----
        _labelFacet(config, "StakingFacet");
        _labelFacet(config, "AdminFacet");
        _labelFacet(config, "SlashingAwareWithdrawalFacet");
        _labelFacet(config, "L1OperationsFacet");
        _labelFacet(config, "WhitelistFacet");
        _labelFacet(config, "RewardShareFacet");
        _labelFacet(config, "HIP3ConfigFacet");
    }

    function _labelIfDeployed(string memory config, string memory key) private {
        string memory path = string.concat(".deployed.", key);
        if (!config.keyExists(path)) return;
        address a = config.readAddress(path);
        if (a != address(0)) vm.label(a, key);
    }

    function _labelBeaconImpl(string memory config, string memory name) private {
        string memory path = string.concat(".deployed.beaconImpls.", name);
        if (!config.keyExists(path)) return;
        address a = config.readAddress(path);
        if (a != address(0)) vm.label(a, string.concat(name, "Impl"));
    }

    function _labelFacet(string memory config, string memory name) private {
        string memory path = string.concat(".deployed.facets.", name);
        if (!config.keyExists(path)) return;
        address a = config.readAddress(path);
        if (a != address(0)) vm.label(a, name);
    }

    /* ========== INTERNAL ========== */

    function uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 temp = v;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(v % 10)));
            v /= 10;
        }
        return string(buffer);
    }
}
