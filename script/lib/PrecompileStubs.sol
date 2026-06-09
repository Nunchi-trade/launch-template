// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {IL1Read} from "@kinetiq/launch/src/interfaces/IL1Read.sol";

/// @title PrecompileStubs
/// @notice Local-only `vm.etch` stubs for the HyperCore L1Read precompiles that the Launch
///         protocol invokes. Foundry's in-memory EVM (used by `forge script` Phase 1 — the local
///         execution that determines planned txs) has no bytecode at precompile addresses like
///         `0x080C` (tokenInfo) or `0x0810` (coreUserExists), so any staticcall to them reverts
///         with "call to non-contract address". These stubs return shape-correct, non-reverting
///         responses so Phase 1 completes; the actual broadcasted txs hit the chain's native
///         precompile handlers (Hyperliquid nodes route those natively — `vm.etch` is purely a
///         local cheatcode and does not generate broadcast txs).
///
/// @dev    Coverage matches `grep "l1Read\." src/`:
///         - `0x0801` SpotBalance      — `StakeFeesThrottle.execute()` (`src/fee-distribution/StakeFeesThrottle.sol:90`)
///         - `0x080C` TokenInfo        — `GlobalConfig._loadTokenInfo` (`src/GlobalConfig.sol:474`)
///         - `0x080F` AccountMarginSummary — `LaunchFeeSplitter.viewSplits/split` (`src/fee-distribution/LaunchFeeSplitter.sol:160`)
///         - `0x0810` CoreUserExists   — `HyperCoreActivatable.activated` (`src/base/HyperCoreActivatable.sol:52`) + `EXManager.activated` (`src/EXManager.sol:879`)
///
/// @dev    Usage from any forge script:
///         ```solidity
///         import {PrecompileStubs} from "./lib/PrecompileStubs.sol";
///         function run(...) external {
///             PrecompileStubs.etchAll();  // call once at the very top, before any precompile-touching code
///             ...
///         }
///         ```
library PrecompileStubs {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address internal constant TOKEN_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080C;
    address internal constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;
    address internal constant CORE_USER_EXISTS_PRECOMPILE = 0x0000000000000000000000000000000000000810;

    /// @notice Etch all four L1Read precompile stubs at their canonical addresses.
    /// @dev    Call once at the top of any `run()` / external entry that may trigger an L1Read call
    ///         downstream. Idempotent — `vm.etch` overwrites.
    function etchAll() internal {
        vm.etch(SPOT_BALANCE_PRECOMPILE, address(new _SpotBalanceStub()).code);
        vm.etch(TOKEN_INFO_PRECOMPILE, address(new _TokenInfoStub()).code);
        vm.etch(ACCOUNT_MARGIN_SUMMARY_PRECOMPILE, address(new _AccountMarginSummaryStub()).code);
        vm.etch(CORE_USER_EXISTS_PRECOMPILE, address(new _CoreUserExistsStub()).code);
    }
}

/* ============================================================================
   Precompile stubs (private to this file — instantiated by PrecompileStubs.etchAll)

   Each stub responds via fallback() to the raw precompile calldata (no function
   selector — HC precompiles take raw abi.encode(args)). Returns shape-correct
   non-reverting data so downstream `abi.decode` + protocol-side `require` checks
   pass. Real precompile semantics are NOT reproduced — these stubs exist only to
   keep Phase 1 local execution from reverting.
   ============================================================================ */

contract _SpotBalanceStub {
    fallback() external {
        // SpotBalance{uint64 total, uint64 hold, uint64 entryNtl} — return zeros (96 bytes).
        // StakeFeesThrottle reads `.total`; zero means "nothing to drip" which is a clean no-op.
        assembly {
            mstore(0, 0)
            mstore(0x20, 0)
            mstore(0x40, 0)
            return(0, 0x60)
        }
    }
}

contract _TokenInfoStub {
    fallback() external {
        // Return TokenInfo with evmContract = address(1) so `_loadTokenInfo`'s
        // `if (info.evmContract == address(0)) revert InvalidTokenInfo()` passes.
        // Other fields zero; weiDecimals + evmExtraWeiDecimals = 0 keeps the
        // `decimals_ <= type(uint8).max` check trivially satisfied.
        IL1Read.TokenInfo memory info;
        info.evmContract = address(1);
        bytes memory ret = abi.encode(info);
        assembly {
            return(add(ret, 0x20), mload(ret))
        }
    }
}

contract _AccountMarginSummaryStub {
    fallback() external {
        // AccountMarginSummary{int64 accountValue, uint64 marginUsed, uint64 ntlPos, int64 rawUsd}
        // — return zeros (128 bytes). LaunchFeeSplitter.viewSplits reads `.rawUsd`; zero means
        // "no fees accrued on this dex" which is a clean no-op for the deploy-time view.
        assembly {
            mstore(0, 0)
            mstore(0x20, 0)
            mstore(0x40, 0)
            mstore(0x60, 0)
            return(0, 0x80)
        }
    }
}

contract _CoreUserExistsStub {
    fallback() external {
        // CoreUserExists{bool exists} — return true. Makes `activated()` return true so
        // `bondMarket`'s `IHyperCoreActivatable.activated()` precondition passes in Phase 1.
        // (The real broadcast still routes through the live precompile, which on testnet
        // returns the actual HC user-existence state.)
        assembly {
            mstore(0, 1)
            return(0, 0x20)
        }
    }
}
