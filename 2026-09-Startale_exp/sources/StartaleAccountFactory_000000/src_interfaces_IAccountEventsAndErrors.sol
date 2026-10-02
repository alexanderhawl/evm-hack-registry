// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PackedUserOperation} from '@account-abstraction/interfaces/PackedUserOperation.sol';

/// @title Events and Errors
/// @notice Defines common errors for the the smart account.
interface IAccountEventsAndErrors {
  /// @notice Error thrown when an unsupported ModuleType is requested.
  /// @param moduleTypeId The ID of the unsupported module type.
  error UnsupportedModuleType(uint256 moduleTypeId);

  /// @notice Error thrown on failed execution.
  error ExecutionFailed();

  /// @notice Error thrown when the Factory fails to initialize the account with posted bootstrap data.
  error AccountInitializationFailed();

  /// @notice Error thrown when a zero address is provided as the Entry Point address.
  error EntryPointCanNotBeZero();

  /// @notice Error thrown when the provided implementation address is invalid.
  error InvalidImplementationAddress();

  /// @notice Error thrown when the provided implementation address is not a contract.
  error ImplementationIsNotAContract();

  /// @notice Error thrown when an inner call fails.
  error InnerCallFailed();

  /// @notice Error thrown when attempted to emergency-uninstall a hook
  error EmergencyTimeLockNotExpired();

  /// @notice Error thrown when attempted to upgrade an ERC7702 account via UUPS proxy upgrade mechanism
  error ERC7702AccountCannotBeUpgradedThisWay();

  /// @notice Error thrown when the provided initData is invalid.
  error InvalidInitData();

  /// @notice Error thrown when the account is already initialized.
  error AccountAlreadyInitialized();

  /// @notice Error thrown when the account is not initialized but expected to be.
  error AccountNotInitialized();
}
