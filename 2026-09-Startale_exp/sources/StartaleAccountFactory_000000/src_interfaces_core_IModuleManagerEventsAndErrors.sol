// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CallType} from '../../lib/ModeLib.sol';

/// @title ERC-7579 Module Manager Events and Errors Interface
/// @notice Provides event and error definitions for actions related to module management in smart accounts.
/// @dev Used by IModuleManager to define the events and errors associated with the installation and management of modules.
interface IModuleManagerEventsAndErrors {
  /// @notice Emitted when a module is installed onto a smart account.
  /// @param moduleTypeId The identifier for the type of module installed.
  /// @param module The address of the installed module.
  event ModuleInstalled(uint256 moduleTypeId, address module);

  /// @notice Emitted when a module is uninstalled from a smart account.
  /// @param moduleTypeId The identifier for the type of module uninstalled.
  /// @param module The address of the uninstalled module.
  event ModuleUninstalled(uint256 moduleTypeId, address module);

  /// @notice Emitted when a pre-validation hook uninstallation fails.
  /// @param hook The address of the pre-validation hook.
  /// @param data The data of the pre-validation hook.
  event PreValidationHookUninstallFailed(address hook, bytes data);

  /// @notice Emitted when a validator uninstallation fails.
  /// @param validator The address of the validator.
  /// @param data The data of the validator.
  event ValidatorUninstallFailed(address validator, bytes data);

  /// @notice Emitted when an executor uninstallation fails.
  /// @param executor The address of the executor.
  /// @param data The data of the executor.
  event ExecutorUninstallFailed(address executor, bytes data);

  /// @notice Emitted when a hook uninstallation fails.
  /// @param hook The address of the hook.
  /// @param data The data of the hook.
  event HookUninstallFailed(address hook, bytes data);

  /// @notice Emitted when an external call fails.
  /// @param target The address of the target.
  /// @param callData The data of the call.
  /// @param returnData The return data of the call.
  event ExternalCallFailed(address target, bytes callData, bytes returnData);

  /// @notice Emitted when an interface is installed.
  /// @param interfaceId The id of the interface.
  event InterfaceInstalled(bytes4 interfaceId);

  /// @notice Emitted when an interface is uninstalled.
  /// @param interfaceId The id of the interface.
  event InterfaceUninstalled(bytes4 interfaceId);

  /// @notice Thrown when attempting to remove the last validator.
  error CanNotRemoveLastValidator();

  /// @dev Thrown when the specified module address is not recognized as valid.
  error ValidatorNotInstalled(address module);

  /// @dev Thrown when there is no installed validator detected.
  error NoValidatorInstalled();

  /// @dev Thrown when the specified module address is not recognized as valid.
  error InvalidModule(address module);

  /// @dev Thrown when an invalid module type identifier is provided.
  error InvalidModuleTypeId(uint256 moduleTypeId);

  /// @dev Thrown when there is an attempt to install a module that is already installed.
  error ModuleAlreadyInstalled(uint256 moduleTypeId, address module);

  /// @dev Thrown when an operation is performed by an unauthorized operator.
  error UnauthorizedOperation(address operator);

  /// @dev Thrown when there is an attempt to uninstall a module that is not installed.
  error ModuleNotInstalled(uint256 moduleTypeId, address module);

  /// @dev Thrown when a module address is set to zero.
  error ModuleAddressCanNotBeZero();

  /// @dev Thrown when a post-check fails after hook execution.
  error HookPostCheckFailed();

  /// @dev Thrown when there is an attempt to install a hook while another is already installed.
  error HookAlreadyInstalled(address currentHook);

  /// @dev Thrown when there is an attempt to install a PreValidationHook while another is already installed.
  error PrevalidationHookAlreadyInstalled(address currentPreValidationHook);

  /// @dev Thrown when there is an attempt to install a fallback handler for a selector already having one.
  error FallbackAlreadyInstalledForSelector(bytes4 selector);

  /// @dev Thrown when there is an attempt to uninstall a fallback handler for a selector that does not have one installed.
  error FallbackNotInstalledForSelector(bytes4 selector);

  /// @dev Thrown when a fallback handler fails to uninstall properly.
  error FallbackHandlerUninstallFailed();

  /// @dev Thrown when no fallback handler is available for a given selector.
  error MissingFallbackHandler(bytes4 selector);

  /// @dev Thrown when Invalid data is provided for MultiType install flow
  error InvalidInput();

  /// @dev Thrown when unable to validate Module Enable Mode signature
  error EnableModeSigError();

  /// @dev Thrown when unable to validate Emergency Uninstall signature
  error EmergencyUninstallSigError();

  /// @notice Error thrown when an invalid nonce is used
  error InvalidNonce();

  /// Error thrown when account installs/uninstalls module with mismatched moduleTypeId
  error MismatchModuleTypeId();

  /// @dev Thrown when there is an attempt to install a forbidden selector as a fallback handler.
  error FallbackSelectorForbidden();

  /// @dev Thrown when there is an attempt to install a fallback handler with an invalid calltype for a given selector.
  error FallbackCallTypeInvalid();

  /// @notice Error thrown when an execution with an unsupported CallType was made.
  /// @param callType The unsupported call type.
  error UnsupportedCallType(CallType callType);

  /// @notice Error thrown when the default validator is already installed.
  error DefaultValidatorAlreadyInstalled();

  /// @notice Error thrown when the hook type is invalid.
  /// @param hookType The invalid hook type.
  error InvalidHookType(uint256 hookType);
}
