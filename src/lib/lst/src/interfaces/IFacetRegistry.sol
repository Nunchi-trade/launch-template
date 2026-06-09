// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IFacetRegistry
 * @notice Interface for FacetRegistry — central registry for managing facets
 *         across multiple StakingManagerRouter instances
 */
interface IFacetRegistry {
    /* ========== STRUCTS ========== */

    /// @notice Alignment status for a single facet on an instance
    struct FacetAlignmentStatus {
        address facet;
        address instance;
        address actualImplementation;
        bool isAligned;
    }

    /* ========== EVENTS ========== */

    event InstanceRegistered(address indexed instance);
    event InstanceRemoved(address indexed instance);
    event FacetSet(bytes32 indexed facetName, address indexed implementation, bytes4[] selectors);
    event FacetRemoved(bytes32 indexed facetName);
    event AllInstancesUpgraded(bytes32 indexed facetName, address indexed implementation, uint256 instanceCount);
    event InstanceUpgraded(address indexed instance, bytes32 indexed facetName, address indexed implementation);
    event BatchUpgradeCompleted(bytes32 indexed facetName, uint256 startIndex, uint256 endIndex);
    event RegistryDeployed(address indexed deployer, address indexed admin, uint256 timestamp);
    event FacetDeployed(bytes32 indexed facetName, address indexed implementation, bytes32 salt);
    event DeploymentStepCompleted(uint8 indexed step, string stepName);

    /* ========== INSTANCE MANAGEMENT ========== */

    /// @notice Register one or more StakingManagerRouter instances
    /// @param instances_ Array of router instance addresses
    function registerInstances(address[] calldata instances_) external;

    /// @notice Remove one or more registered instances
    /// @param instances_ Array of router instance addresses to remove
    function removeInstances(address[] calldata instances_) external;

    /* ========== FACET MANAGEMENT ========== */

    /// @notice Register one or more facets using self-reporting (IFacet interface)
    /// @param facets_ Array of facet implementation addresses (must implement IFacet)
    function registerFacets(address[] calldata facets_) external;

    /// @notice Remove one or more facets from the registry
    /// @param facets_ Array of facet implementation addresses to remove
    function removeFacets(address[] calldata facets_) external;

    /* ========== INSTANCE-FACET WIRING ========== */

    /// @notice Wire specific facet implementations to an instance using batched diamondCut
    /// @param instance The instance to wire facets to
    /// @param facets_ Array of facet implementations to wire
    /// @param force If true, replaces existing facets; if false, only adds new ones
    function wire(address instance, address[] calldata facets_, bool force) external;

    /// @notice Wire latest version of each facet type to an instance
    /// @param instance The instance to wire all facets to
    /// @param force If true, replaces existing facets; if false, only adds new ones
    function wireAll(address instance, bool force) external;

    /// @notice Unwire specific facets from an instance using batched diamondCut
    /// @param instance The instance to unwire facets from
    /// @param facets_ Array of facet implementations to unwire
    function unwire(address instance, address[] calldata facets_) external;

    /// @notice Add a facet implementation to specific instances
    /// @param facet The facet implementation to add
    /// @param instances_ Array of instances to add the facet to
    function add(address facet, address[] calldata instances_) external;

    /// @notice Remove a facet from specific instances
    /// @param facet The facet implementation to remove
    /// @param instances_ Array of instances to remove the facet from
    function remove(address facet, address[] calldata instances_) external;

    /// @notice Replace an old facet implementation with a new one across all instances using it
    /// @param oldFacet The facet implementation to replace
    /// @param newFacet The new facet implementation to use
    function replace(address oldFacet, address newFacet) external;

    /* ========== SYNC ========== */

    /// @notice Upgrade an instance to match the registry's latest facet implementations
    /// @param instance The instance to upgrade
    function upgradeInstanceToLatest(address instance) external;

    /* ========== VIEW FUNCTIONS ========== */

    /// @notice Check if an instance is registered
    /// @param instance Address to check
    /// @return true if the instance is registered
    function isInstance(address instance) external view returns (bool);

    /// @notice Get the number of registered instances
    function getInstanceCount() external view returns (uint256);

    /// @notice Get all registered instances
    function getAllInstances() external view returns (address[] memory);

    /// @notice Check if a facet is registered
    /// @param implementation Address of the facet implementation
    /// @return true if the facet is registered
    function isFacetRegistered(address implementation) external view returns (bool);

    /// @notice Check if any instance has this facet wired
    /// @param facet Address of the facet implementation
    /// @return true if at least one instance has this facet wired
    function isFacetWired(address facet) external view returns (bool);

    /// @notice Get the number of registered facets
    function getFacetCount() external view returns (uint256);

    /// @notice Get all registered facet implementations
    function getAllFacets() external view returns (address[] memory);

    /// @notice Get facet selectors
    /// @param facet Address of the facet implementation
    /// @return selectors Function selectors for this facet
    function getFacetSelectors(address facet) external view returns (bytes4[] memory selectors);

    /* ========== RELATIONSHIP QUERIES ========== */

    /// @notice Get all facets wired to an instance
    /// @param instance The instance address
    /// @return facets_ Array of facet addresses wired to this instance
    function getInstanceFacets(address instance) external view returns (address[] memory facets_);

    /// @notice Get all instances using a specific facet
    /// @param facet The facet implementation address
    /// @return instances_ Array of instance addresses using this facet
    function getFacetInstances(address facet) external view returns (address[] memory instances_);

    /* ========== ALIGNMENT CHECKS ========== */

    /// @notice Check if instances using a facet have the correct implementation
    /// @param facet Address of the facet implementation to check
    /// @return aligned True if all instances using this facet have the correct implementation
    /// @return misaligned Array of instance addresses with wrong implementation
    function checkFacetAlignment(address facet) external view returns (bool aligned, address[] memory misaligned);

    /// @notice Check alignment of ALL registered facets across ALL instances
    /// @return allAligned True if all instances have all facets aligned
    /// @return totalMisaligned Total count of misaligned facet-instance pairs
    /// @return misalignedDetails Array of misaligned facet-instance details
    function checkAllFacetsAlignment()
        external
        view
        returns (bool allAligned, uint256 totalMisaligned, FacetAlignmentStatus[] memory misalignedDetails);

    /// @notice Get alignment status for a specific instance across wired facets
    /// @param instance The instance to check
    /// @return alignedCount Number of correctly aligned facets
    /// @return wiredCount Number of facets wired to this instance
    /// @return statuses Alignment status for each wired facet
    function checkInstanceAlignment(address instance)
        external
        view
        returns (uint256 alignedCount, uint256 wiredCount, FacetAlignmentStatus[] memory statuses);
}
