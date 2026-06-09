// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFacet
 * @notice Interface for self-describing facets in the Diamond pattern
 * @dev Facets implementing this interface can report their own selectors
 */
interface IFacet {
    /**
     * @notice Returns the function selectors this facet exposes
     * @return selectors Array of function selectors
     */
    function getSelectors() external pure returns (bytes4[] memory selectors);

    /**
     * @notice Returns the name of this facet
     * @return name Human-readable facet name
     */
    function facetName() external pure returns (string memory name);

    /**
     * @notice Returns whether this facet can be safely unwired (removed)
     * @return True if facet can be unwired, false if it's critical and should only be replaced
     * @dev Critical facets that other contracts depend on should return false
     *      Examples: L1OperationsFacet (KHYPE transfers), RewardShareFacet (oracle updates)
     */
    function canUnwire() external pure returns (bool);
}
