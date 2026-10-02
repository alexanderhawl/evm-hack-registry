// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccountConfig} from './core/IAccountConfig.sol';
import {IExecutionHelper} from './core/IExecutionHelper.sol';
import {IModuleManager} from './core/IModuleManager.sol';

/// @title IERC7579Account
/// @notice This interface integrates the functionalities required for a modular smart account compliant with ERC-7579 and ERC-4337 standards.
/// @dev Combines configurations and operational management for smart accounts, bridging IAccountConfig, IExecutionHelper, and IModuleManager.
/// Interfaces designed to support the comprehensive management of smart account operations including execution management and modular configurations.
/// @author Startale
interface IERC7579Account is IAccountConfig, IExecutionHelper, IModuleManager {
  /// @dev Validates a smart account signature according to ERC-1271 standards.
  /// This method may delegate the call to a validator module to check the signature.
  /// @param hash The hash of the data being validated.
  /// @param data The signed data to validate.
  function isValidSignature(bytes32 hash, bytes calldata data) external view returns (bytes4);
}
