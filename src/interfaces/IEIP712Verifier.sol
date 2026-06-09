// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC5267} from "@openzeppelin/contracts/interfaces/IERC5267.sol";

/// @title IEIP712Verifier
/// @notice Interface for the EIP712 verifier
interface IEIP712Verifier is IERC5267 {
    struct EIP712SignedData {
        bytes data; // the encoded struct of the typed data
        bytes signature; // the EIP712 signature of the typed data
    }
}
