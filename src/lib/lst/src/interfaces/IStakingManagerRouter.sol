// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStakingManagerRouter
 * @notice Interface for modular function routing (Diamond-like pattern)
 * @dev Allows splitting large contracts into smaller, upgradeable facets
 */
interface IStakingManagerRouter {
    /* ========== STRUCTS ========== */

    /// @notice Facet information
    struct Facet {
        address facetAddress;
        bytes4[] selectors;
    }

    /// @notice Facet cut action types
    enum FacetCutAction {
        Add, // Add new selectors
        Replace, // Replace existing selectors
        Remove // Remove selectors
    }

    /// @notice Facet cut for adding/replacing/removing functions
    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] selectors;
    }

    /* ========== EVENTS ========== */

    /// @notice Emitted when facet cuts are executed
    event DiamondCut(FacetCut[] facetCuts);

    /// @notice Emitted when a facet is added
    event FacetAdded(address indexed facet, bytes4[] selectors);

    /// @notice Emitted when a facet is replaced
    event FacetReplaced(address indexed oldFacet, address indexed newFacet, bytes4[] selectors);

    /// @notice Emitted when a facet is removed
    event FacetRemoved(address indexed facet, bytes4[] selectors);

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Get facet address for a selector
    function getFacetAddress(bytes4 selector) external view returns (address);

    /// @notice Get all facets
    function getFacets() external view returns (Facet[] memory);

    /// @notice Get all selectors for a facet
    function getFacetSelectors(address facet) external view returns (bytes4[] memory);

    /// @notice Get all facet addresses
    function getFacetAddresses() external view returns (address[] memory);

    /// @notice Check if selector is supported
    function supportsSelector(bytes4 selector) external view returns (bool);

    /* ========== REGISTRY FUNCTIONS ========== */

    /// @notice Execute facet cuts (add/replace/remove) — only callable by FacetRegistry
    function diamondCut(FacetCut[] calldata cuts) external;
}
