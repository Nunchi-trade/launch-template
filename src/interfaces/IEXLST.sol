// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IPauserRegistry} from "@kinetiq/lst/src/interfaces/IPauserRegistry.sol";

import {IHyperCoreAsset} from "@kinetiq/launch/src/interfaces/IHyperCoreAsset.sol";

/// @title IEXLST
/// @notice Interface for the EXLST token
interface IEXLST is IERC20, IAccessControl, IHyperCoreAsset {
    /// @notice The maximum exLST supply (initialized from tier at deploy, may increase on tier upgrade)
    function supplyCap() external view returns (uint256);

    /// @notice Raises the supply cap (increase only, MINTER_ROLE)
    /// @dev Called by EXManager during the tier upgrade flow
    /// @param newSupplyCap The new supply cap (must be > current)
    function setSupplyCap(uint256 newSupplyCap) external;

    /// @notice Emitted when the supply cap is raised during a tier upgrade
    event SupplyCapUpdated(uint256 indexed oldSupplyCap, uint256 indexed newSupplyCap);

    /// @notice The pauser registry contract
    function pauserRegistry() external view returns (IPauserRegistry);

    /// @notice The role allowed to mint new exLST tokens
    function MINTER_ROLE() external view returns (bytes32);

    /// @notice The role allowed to burn exLST tokens
    function BURNER_ROLE() external view returns (bytes32);

    /// @notice Mints tokens to an address
    /// @dev This function is only callable by the MINTER_ROLE
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external;

    /// @notice Burns tokens from an address
    /// @dev This function is only callable by the BURNER_ROLE
    /// @param from The address to burn tokens from
    /// @param amount The amount of tokens to burn
    function burn(address from, uint256 amount) external;
}
