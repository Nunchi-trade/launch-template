// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IL1Read
/// @notice Interface for Hyperliquid L1Read precompile to query HyperCore spot balances
interface IL1Read {
    struct Position {
        int64 szi;
        uint64 entryNtl;
        int64 isolatedRawUsd;
        uint32 leverage;
        bool isIsolated;
    }

    /// @notice Get the position for a user and perp on HyperCore
    /// @param user The address to query position for
    /// @param perp The perp ID on HyperCore
    /// @return pos The position struct containing szi, entryNtl, isolatedRawUsd, leverage, and isIsolated
    function position(address user, uint16 perp) external view returns (Position memory pos);

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    /// @notice Get the spot balance for a user and asset on HyperCore
    /// @param user The address to query balance for
    /// @param token The token ID on HyperCore
    /// @return balance The spot balance struct containing total, hold, and entryNtl
    function spotBalance(address user, uint64 token) external view returns (SpotBalance memory balance);

    struct UserVaultEquity {
        uint64 equity;
        uint64 lockedUntilTimestamp;
    }

    /// @notice Get the user vault equity for a user and vault on HyperCore
    /// @param user The address to query equity for
    /// @param vault The vault address on HyperCore
    /// @return uve The user vault equity struct containing equity and lockedUntilTimestamp
    function userVaultEquity(address user, address vault) external view returns (UserVaultEquity memory uve);

    struct Withdrawable {
        uint64 withdrawable;
    }

    /// @notice Get the withdrawable amount for a user on HyperCore
    /// @param user The address to query withdrawable amount for
    /// @return wd The withdrawable struct containing withdrawable amount
    function withdrawable(address user) external view returns (Withdrawable memory wd);

    struct Delegation {
        address validator;
        uint64 amount;
        uint64 lockedUntilTimestamp;
    }

    /// @notice Get the delegations for a user on HyperCore
    /// @param user The address to query delegations for
    /// @return dels The delegations struct containing validator, amount, and lockedUntilTimestamp
    function delegations(address user) external view returns (Delegation[] memory dels);

    struct DelegatorSummary {
        uint64 delegated;
        uint64 undelegated;
        uint64 totalPendingWithdrawal;
        uint64 nPendingWithdrawals;
    }

    /// @notice Get the delegator summary for a user on HyperCore
    /// @param user The address to query delegator summary for
    /// @return summary The delegator summary struct containing delegated, undelegated, totalPendingWithdrawal, and nPendingWithdrawals
    function delegatorSummary(address user) external view returns (DelegatorSummary memory summary);

    /// @notice Get the mark px for a index on HyperCore
    /// @param index The index to query mark px for
    /// @return mpx The mark px for the index
    function markPx(uint32 index) external view returns (uint64 mpx);

    /// @notice Get the oracle px for a index on HyperCore
    /// @param index The index to query oracle px for
    /// @return opx The oracle px for the index
    function oraclePx(uint32 index) external view returns (uint64 opx);

    /// @notice Get the spot px for a index on HyperCore
    /// @param index The index to query spot px for
    /// @return spx The spot px for the index
    function spotPx(uint32 index) external view returns (uint64 spx);

    /// @notice Get the l1 block number on HyperCore
    /// @return number The l1 block number
    function l1BlockNumber() external view returns (uint64 number);

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    /// @notice Get the perp asset info for a perp on HyperCore
    /// @param perp The perp ID on HyperCore
    /// @return perpInfo The perp asset info struct containing coin, marginTableId, szDecimals, maxLeverage, and onlyIsolated
    function perpAssetInfo(uint32 perp) external view returns (PerpAssetInfo memory perpInfo);

    struct SpotInfo {
        string name;
        uint64[2] tokens;
    }

    /// @notice Get the spot info for a spot on HyperCore
    /// @param spot The spot ID on HyperCore
    /// @return spotInfo The spot info struct containing name and tokens
    function spotInfo(uint32 spot) external view returns (SpotInfo memory spotInfo);

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    /// @notice Get the token info for a token on HyperCore
    /// @param token The token ID on HyperCore
    /// @return info The token info struct containing name, spots, deployerTradingFeeShare, deployer, evmContract, szDecimals, weiDecimals, and evmExtraWeiDecimals
    function tokenInfo(uint32 token) external view returns (TokenInfo memory info);

    struct UserBalance {
        address user;
        uint64 balance;
    }

    struct TokenSupply {
        uint64 maxSupply;
        uint64 totalSupply;
        uint64 circulatingSupply;
        uint64 futureEmissions;
        UserBalance[] nonCirculatingUserBalances;
    }

    /// @notice Get the token supply for a token on HyperCore
    /// @param token The token ID on HyperCore
    /// @return supply The token supply struct containing maxSupply, totalSupply, circulatingSupply, futureEmissions, and nonCirculatingUserBalances
    function tokenSupply(uint32 token) external view returns (TokenSupply memory supply);

    struct Bbo {
        uint64 bid;
        uint64 ask;
    }

    /// @notice Get the bbo for a asset on HyperCore
    /// @param asset The asset ID on HyperCore
    /// @return bbo The bbo struct containing bid and ask
    function bbo(uint32 asset) external view returns (Bbo memory bbo);

    struct AccountMarginSummary {
        int64 accountValue;
        uint64 marginUsed;
        uint64 ntlPos;
        int64 rawUsd;
    }

    /// @notice Get the account margin summary for a perp and user on HyperCore
    /// @param perp_dex_index The perp dex index on HyperCore
    /// @param user The user to query account margin summary for
    /// @return summary The account margin summary struct containing accountValue, marginUsed, ntlPos, and rawUsd
    function accountMarginSummary(uint32 perp_dex_index, address user)
        external
        view
        returns (AccountMarginSummary memory summary);

    struct CoreUserExists {
        bool exists;
    }

    /// @notice Check if a user exists on HyperCore
    /// @param user The user to check if exists
    /// @return coreUserExists The core user exists struct containing exists
    function coreUserExists(address user) external view returns (CoreUserExists memory coreUserExists);
}
