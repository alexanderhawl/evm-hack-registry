// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {BaseAccount} from './core/BaseAccount.sol';
import {ERC7779Adapter} from './core/ERC7779Adapter.sol';
import {ExecutionHelper} from './core/ExecutionHelper.sol';
import {ModuleManager} from './core/ModuleManager.sol';
import {IERC7579Account} from './interfaces/IERC7579Account.sol';
import {IValidator} from './interfaces/IERC7579Module.sol';
import {IStartaleSmartAccount} from './interfaces/IStartaleSmartAccount.sol';
import {IAccountConfig} from './interfaces/core/IAccountConfig.sol';
import {ExecutionLib} from './lib/ExecutionLib.sol';
import {Initializable} from './lib/Initializable.sol';
import {
  CALLTYPE_BATCH,
  CALLTYPE_DELEGATECALL,
  CALLTYPE_SINGLE,
  CallType,
  EXECTYPE_DEFAULT,
  EXECTYPE_TRY,
  ExecType,
  ExecutionMode,
  ModeLib
} from './lib/ModeLib.sol';
import {NonceLib} from './lib/NonceLib.sol';
import {ACCOUNT_STORAGE_LOCATION} from './types/Constants.sol';
import {
  MODULE_TYPE_EXECUTOR,
  MODULE_TYPE_FALLBACK,
  MODULE_TYPE_HOOK,
  MODULE_TYPE_MULTI,
  MODULE_TYPE_PREVALIDATION_HOOK_ERC1271,
  MODULE_TYPE_PREVALIDATION_HOOK_ERC4337,
  MODULE_TYPE_VALIDATOR,
  SUPPORTS_ERC7739,
  VALIDATION_FAILED,
  VALIDATION_SUCCESS
} from './types/Constants.sol';
import {EmergencyUninstall} from './types/Structs.sol';
import {PackedUserOperation} from '@account-abstraction/interfaces/PackedUserOperation.sol';
import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';
import {IERC1155Receiver} from '@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {SENTINEL, SentinelListLib, ZERO_ADDRESS} from 'sentinellist/SentinelList.sol';
import {UUPSUpgradeable} from 'solady/utils/UUPSUpgradeable.sol';

/// @title Startale Smart Account
/// @notice This contract integrates various functionalities to handle modular smart accounts compliant with ERC-7579 and ERC-4337 standards.
/// @dev Comprehensive suite of methods for managing smart accounts, integrating module management, execution management, and upgradability via UUPS.
/// @author Startale Labs
/// Special thanks to the Biconomy team for https://github.com/bcnmy/nexus/ on which this implementation is highly based on.
contract StartaleSmartAccount is
  IStartaleSmartAccount,
  IERC165,
  BaseAccount,
  ExecutionHelper,
  ModuleManager,
  ERC7779Adapter,
  UUPSUpgradeable
{
  using ModeLib for ExecutionMode;
  using ExecutionLib for bytes;
  using NonceLib for uint256;
  using SentinelListLib for SentinelListLib.SentinelList;

  /// @dev The timelock period for emergency hook uninstallation.
  uint256 internal constant _EMERGENCY_TIMELOCK = 1 days;

  /// @dev The event emitted when an emergency hook uninstallation is initiated.
  event EmergencyHookUninstallRequest(address hook, uint256 timestamp);

  /// @dev The event emitted when an emergency hook uninstallation request is reset.
  event EmergencyHookUninstallRequestReset(address hook, uint256 timestamp);

  /// @notice Initializes the smart account with the specified entry point.
  constructor(
    address anEntryPoint,
    address defaultValidator,
    bytes memory initData
  ) ModuleManager(defaultValidator, initData) {
    require(address(anEntryPoint) != address(0), EntryPointCanNotBeZero());
    _ENTRYPOINT = anEntryPoint;
  }

  /// @notice Validates a user operation against a specified validator, extracted from the operation's nonce.
  /// @param op The user operation to validate, encapsulating all transaction details.
  /// @param userOpHash Hash of the user operation data, used for signature validation.
  /// @param missingAccountFunds Funds missing from the account's deposit necessary for transaction execution.
  /// This can be zero if covered by a paymaster or if sufficient deposit exists.
  /// @return validationData Encoded validation result or failure, propagated from the validator module.
  /// - Encoded format in validationData:
  ///     - First 20 bytes: Address of the Validator module, to which the validation task is forwarded.
  ///       The validator module returns:
  ///         - `SIG_VALIDATION_SUCCESS` (0) indicates successful validation.
  ///         - `SIG_VALIDATION_FAILED` (1) indicates signature validation failure.
  /// @dev Expects the validator's address to be encoded in the upper 96 bits of the user operation's nonce.
  /// This method forwards the validation task to the extracted validator module address.
  /// @dev The entryPoint calls this function. If validation fails, it returns `VALIDATION_FAILED` (1) otherwise `0`.
  /// @dev Features Module Enable Mode.
  /// This Module Enable Mode flow is intended for the module acting as the validator
  /// for the user operation that triggers the Module Enable Flow. Otherwise, a call to
  /// `IERC7579Account.installModule` should be included in `userOp.callData`.
  function validateUserOp(
    PackedUserOperation calldata op,
    bytes32 userOpHash,
    uint256 missingAccountFunds
  ) external virtual payPrefund(missingAccountFunds) onlyEntryPoint returns (uint256 validationData) {
    address validator;
    PackedUserOperation memory userOp = op;

    if (op.nonce.isModuleEnableMode()) {
      // if it is module enable mode, we need to enable the module first
      // and get the cleaned signature
      userOp.signature = _enableMode(userOpHash, op.signature);
    }
    validator = _handleValidator(op.nonce.getValidator());
    (userOpHash, userOp.signature) = _withPreValidationHook(userOpHash, userOp, missingAccountFunds);
    validationData = IValidator(validator).validateUserOp(userOp, userOpHash);
  }

  /// @notice Executes transactions in single or batch modes as specified g by the execution mode.
  /// @param mode The execution mode detailing how transactions should be handled (single, batch, default, try/catch).
  /// @param executionCalldata The encoded transaction data to execute.
  /// @dev This function handles transaction execution flexibility and is protected by the `onlyEntryPoint` modifier.
  /// @dev This function also goes through hook checks via withHook modifier.
  function execute(ExecutionMode mode, bytes calldata executionCalldata) external payable onlyEntryPoint withHook {
    (CallType callType, ExecType execType) = mode.decodeBasic();
    if (callType == CALLTYPE_SINGLE) {
      _handleSingleExecution(executionCalldata, execType);
    } else if (callType == CALLTYPE_BATCH) {
      _handleBatchExecution(executionCalldata, execType);
    } else if (callType == CALLTYPE_DELEGATECALL) {
      _handleDelegateCallExecution(executionCalldata, execType);
    } else {
      revert UnsupportedCallType(callType);
    }
  }

  /// @notice Executes transactions from an executor module, supporting both single and batch transactions.
  /// @param mode The execution mode (single or batch, default or try).
  /// @param executionCalldata The transaction data to execute.
  /// @return returnData The results of the transaction executions, which may include errors in try mode.
  /// @dev This function is callable only by an executor module and goes through hook checks.
  function executeFromExecutor(
    ExecutionMode mode,
    bytes calldata executionCalldata
  ) external payable onlyExecutorModule withHook returns (bytes[] memory returnData) {
    (CallType callType, ExecType execType) = mode.decodeBasic();
    // check if calltype is batch or single or delegate call
    if (callType == CALLTYPE_SINGLE) {
      returnData = _handleSingleExecutionAndReturnData(executionCalldata, execType);
    } else if (callType == CALLTYPE_BATCH) {
      returnData = _handleBatchExecutionAndReturnData(executionCalldata, execType);
    } else if (callType == CALLTYPE_DELEGATECALL) {
      returnData = _handleDelegateCallExecutionAndReturnData(executionCalldata, execType);
    } else {
      revert UnsupportedCallType(callType);
    }
  }

  /// @notice Executes a user operation via a call using the contract's context.
  /// @param userOp The user operation to execute, containing transaction details.
  /// @param - Hash of the user operation.
  /// @dev Only callable by the EntryPoint. Decodes the user operation calldata, skipping the first four bytes, and executes the inner call.
  function executeUserOp(PackedUserOperation calldata userOp, bytes32) external payable virtual onlyEntryPoint withHook {
    bytes calldata callData = userOp.callData[4:];
    (bool success,) = address(this).delegatecall(callData);
    if (!success) {
      revert ExecutionFailed();
    }
  }

  /// @notice Installs a new module to the smart account.
  /// @param moduleTypeId The type identifier of the module being installed, which determines its role:
  /// - 1 for Validator
  /// - 2 for Executor
  /// - 3 for Fallback
  /// - 4 for Hook
  /// - 8 for 1271 Prevalidation Hook
  /// - 9 for 4337 Prevalidation Hook
  /// @param module The address of the module to install.
  /// @param initData Initialization data for the module.
  /// @dev This function can only be called by the EntryPoint or the account itself for security reasons.
  /// @dev This function goes through hook checks via withHook modifier through internal function _installModule.
  function installModule(
    uint256 moduleTypeId,
    address module,
    bytes calldata initData
  ) external payable onlyEntryPointOrSelf {
    _installModule(moduleTypeId, module, initData);
    emit ModuleInstalled(moduleTypeId, module);
  }

  /// @notice Installs an interface to the smart account.
  /// @param interfaceId The id of the interface to install.
  /// @dev This function can only be called by the EntryPoint or the account itself for security reasons.
  function installInterface(bytes4 interfaceId) external payable onlyEntryPointOrSelf {
    _installInterface(interfaceId);
  }

  /// @notice Installs multiple interfaces to the smart account.
  /// @param interfaceIds The ids of the interfaces to install.
  /// @dev This function can only be called by the EntryPoint or the account itself for security reasons.
  function installInterfaces(bytes4[] calldata interfaceIds) external payable onlyEntryPointOrSelf {
    _installInterfaces(interfaceIds);
  }

  /// @notice Uninstalls an interface from the smart account.
  /// @param interfaceId The id of the interface to uninstall.
  /// @dev This function can only be called by the EntryPoint or the account itself for security reasons.
  function uninstallInterface(bytes4 interfaceId) external payable onlyEntryPointOrSelf {
    _uninstallInterface(interfaceId);
  }

  /// @notice Uninstalls a module from the smart account.
  /// @param moduleTypeId The type ID of the module to be uninstalled, matching the installation type:
  /// - 1 for Validator
  /// - 2 for Executor
  /// - 3 for Fallback
  /// - 4 for Hook
  /// - 8 for 1271 Prevalidation Hook
  /// - 9 for 4337 Prevalidation Hook
  /// @notice
  /// If the module is malicious, it can prevent itself from being uninstalled by spending all gas in the onUninstall() method.
  /// @param module The address of the module to uninstall.
  /// @param deInitData De-initialization data for the module.
  /// @dev Ensures that the operation is authorized and valid before proceeding with the uninstallation.
  function uninstallModule(
    uint256 moduleTypeId,
    address module,
    bytes calldata deInitData
  ) external payable onlyEntryPointOrSelf withHook {
    require(_isModuleInstalled(moduleTypeId, module, deInitData), ModuleNotInstalled(moduleTypeId, module));

    if (moduleTypeId == MODULE_TYPE_VALIDATOR) {
      _uninstallValidator(module, deInitData);
      _checkInitializedValidators();
    } else if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
      _uninstallExecutor(module, deInitData);
    } else if (moduleTypeId == MODULE_TYPE_FALLBACK) {
      _uninstallFallbackHandler(module, deInitData);
    } else if (
      moduleTypeId == MODULE_TYPE_HOOK || moduleTypeId == MODULE_TYPE_PREVALIDATION_HOOK_ERC1271
        || moduleTypeId == MODULE_TYPE_PREVALIDATION_HOOK_ERC4337
    ) {
      _uninstallHook(module, moduleTypeId, deInitData);
    }
    emit ModuleUninstalled(moduleTypeId, module);
  }

  function emergencyUninstallHook(EmergencyUninstall calldata data, bytes calldata signature) external payable {
    // Validate the signature
    _checkEmergencyUninstallSignature(data, signature);
    // Parse uninstall data
    (uint256 hookType, address hook, bytes calldata deInitData) = (data.hookType, data.hook, data.deInitData);

    // Validate the hook is of a supported type and is installed
    require(
      hookType == MODULE_TYPE_HOOK || hookType == MODULE_TYPE_PREVALIDATION_HOOK_ERC1271
        || hookType == MODULE_TYPE_PREVALIDATION_HOOK_ERC4337,
      UnsupportedModuleType(hookType)
    );
    require(_isModuleInstalled(hookType, hook, deInitData), ModuleNotInstalled(hookType, hook));

    // Get the account storage
    AccountStorage storage accountStorage = _getAccountStorage();
    uint256 hookTimelock = accountStorage.emergencyUninstallTimelock[hook];

    if (hookTimelock == 0) {
      // if the timelock hasnt been initiated, initiate it
      accountStorage.emergencyUninstallTimelock[hook] = block.timestamp;
      emit EmergencyHookUninstallRequest(hook, block.timestamp);
    } else if (block.timestamp >= hookTimelock + 3 * _EMERGENCY_TIMELOCK) {
      // if the timelock has been left for too long, reset it
      accountStorage.emergencyUninstallTimelock[hook] = block.timestamp;
      emit EmergencyHookUninstallRequestReset(hook, block.timestamp);
    } else if (block.timestamp >= hookTimelock + _EMERGENCY_TIMELOCK) {
      // if the timelock expired, clear it and uninstall the hook
      accountStorage.emergencyUninstallTimelock[hook] = 0;
      _uninstallHook(hook, hookType, deInitData);
      emit ModuleUninstalled(hookType, hook);
    } else {
      // if the timelock is initiated but not expired, revert
      revert EmergencyTimeLockNotExpired();
    }
  }

  /// @notice Initializes the smart account with the specified initialization data.
  /// @param initData The initialization data for the smart account.
  /// @dev This function can only be called by the account itself or the proxy factory.
  /// When a 7702 account is created, the first userOp should contain self-call to initialize the account.
  function initializeAccount(bytes calldata initData) external payable virtual {
    // Protect this function to only be callable when used with the proxy factory or when
    // account calls itself
    if (msg.sender != address(this)) {
      Initializable.requireInitializable();
    }
    _initializeAccount(initData);
  }

  function _initializeAccount(bytes calldata initData) internal {
    require(initData.length >= 24, InvalidInitData());

    if (_amIERC7702()) {
      _addStorageBase(ACCOUNT_STORAGE_LOCATION);
    }

    address bootstrap;
    bytes calldata bootstrapCall;

    assembly {
      bootstrap := calldataload(initData.offset)
      let s := calldataload(add(initData.offset, 0x20))
      let u := add(initData.offset, s)
      bootstrapCall.offset := add(u, 0x20)
      bootstrapCall.length := calldataload(u)
    }

    (bool success,) = bootstrap.delegatecall(bootstrapCall);

    require(success, AccountInitializationFailed());
    if (!_amIERC7702()) {
      require(isInitialized(), AccountNotInitialized());
    }
  }

  /// @dev Uninstalls all validators, executors, hooks, fallbacks, and pre-validation hooks.
  /// @notice It is worth noting that, onRedelegation() does not obligate the account to completely wipe out it’s storage.
  /// @notice It is an optional action for the account where it could uninitialize the storage variables as much as it can to provide clean storage for new wallet.
  function _onRedelegation() internal override {
    _uninstallAllValidators();
    _uninstallAllExecutors();
    _uninstallHook(_getHook());
    _uninstallPreValidationHook(
      _getPreValidationHook(MODULE_TYPE_PREVALIDATION_HOOK_ERC1271), MODULE_TYPE_PREVALIDATION_HOOK_ERC1271
    );
    _uninstallPreValidationHook(
      _getPreValidationHook(MODULE_TYPE_PREVALIDATION_HOOK_ERC4337), MODULE_TYPE_PREVALIDATION_HOOK_ERC4337
    );
    _uninstallAllFallbacks();
    _uninstallAllInterfaces();
    _initSentinelLists();
  }

  /// @notice Validates a signature according to ERC-1271 standards.
  /// @param hash The hash of the data being validated.
  /// @param signature Signature data that needs to be validated.
  /// @return The status code of the signature validation (`0x1626ba7e` if valid).
  /// bytes4(keccak256("isValidSignature(bytes32,bytes)") = 0x1626ba7e
  /// @dev Delegates the validation to a validator module specified within the signature data.
  function isValidSignature(bytes32 hash, bytes calldata signature) external view virtual override returns (bytes4) {
    // Handle potential ERC7739 support detection request
    if (signature.length == 0) {
      // Forces the compiler to optimize for smaller bytecode size.
      // checking if the hash equals to 0x7739773977397739773977397739773977397739773977397739773977397739
      if (uint256(hash) == (~signature.length / 0xffff) * 0x7739) {
        return checkERC7739Support(hash, signature);
      }
    }
    // else proceed with normal signature verification
    // First 20 bytes of data will be validator address and rest of the bytes is complete signature.
    address validator = _handleValidator(address(bytes20(signature[0:20])));
    bytes memory signature_;
    (hash, signature_) = _withPreValidationHook(hash, signature[20:]);
    try IValidator(validator).isValidSignatureWithSender(msg.sender, hash, signature_) returns (bytes4 res) {
      return res;
    } catch {
      return bytes4(0xffffffff);
    }
  }

  /// @notice Retrieves the address of the current implementation from the EIP-1967 slot.
  /// @notice Checks the 1967 implementation slot
  /// @return implementation The address of the current contract implementation.
  function getImplementation() external view returns (address implementation) {
    assembly {
      implementation := sload(_ERC1967_IMPLEMENTATION_SLOT)
    }
  }

  /// @notice Checks if a specific module type is supported by this smart account.
  /// @param moduleTypeId The identifier of the module type to check.
  /// @return True if the module type is supported, false otherwise.
  function supportsModule(uint256 moduleTypeId) external view virtual returns (bool) {
    if (
      moduleTypeId == MODULE_TYPE_VALIDATOR || moduleTypeId == MODULE_TYPE_EXECUTOR
        || moduleTypeId == MODULE_TYPE_FALLBACK || moduleTypeId == MODULE_TYPE_HOOK
        || moduleTypeId == MODULE_TYPE_PREVALIDATION_HOOK_ERC1271
        || moduleTypeId == MODULE_TYPE_PREVALIDATION_HOOK_ERC4337 || moduleTypeId == MODULE_TYPE_MULTI
    ) {
      return true;
    }
    return false;
  }

  /// @notice Determines if a specific execution mode is supported.
  /// @param mode The execution mode to evaluate.
  /// @return isSupported True if the execution mode is supported, false otherwise.
  function supportsExecutionMode(ExecutionMode mode) external view virtual returns (bool isSupported) {
    (CallType callType, ExecType execType) = mode.decodeBasic();

    // Return true if both the call type and execution type are supported.
    return (callType == CALLTYPE_SINGLE || callType == CALLTYPE_BATCH || callType == CALLTYPE_DELEGATECALL)
      && (execType == EXECTYPE_DEFAULT || execType == EXECTYPE_TRY);
  }

  function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
    AccountStorage storage ds = _getAccountStorage();
    if (
      interfaceId == type(IERC721Receiver).interfaceId || interfaceId == type(IERC1155Receiver).interfaceId
        || interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC1271).interfaceId
        || interfaceId == type(IStartaleSmartAccount).interfaceId || interfaceId == type(IERC7579Account).interfaceId
        || interfaceId == type(IAccountConfig).interfaceId
    ) {
      return true;
    }
    return ds.supportedIfaces[interfaceId];
  }

  /// @notice Determines whether a module is installed on the smart account.
  /// @param moduleTypeId The ID corresponding to the type of module (Validator, Executor, Fallback, Hook).
  /// @param module The address of the module to check.
  /// @param additionalContext Optional context that may be needed for certain checks.
  /// @return True if the module is installed, false otherwise.
  function isModuleInstalled(
    uint256 moduleTypeId,
    address module,
    bytes calldata additionalContext
  ) external view returns (bool) {
    return _isModuleInstalled(moduleTypeId, module, additionalContext);
  }

  /// @notice Checks if the smart account is initialized.
  /// @return True if the smart account is initialized, false otherwise.
  /// @dev In case default validator is initialized, two other SLOADS from _areSentinelListsInitialized() are not checked,
  /// this method should not introduce huge gas overhead.
  function isInitialized() public view returns (bool) {
    return (IValidator(_DEFAULT_VALIDATOR).isInitialized(address(this)) || _areSentinelListsInitialized());
  }

  /// Returns the account's implementation ID.
  /// @return The unique identifier for this account implementation.
  function accountId() external pure virtual returns (string memory) {
    return _ACCOUNT_IMPLEMENTATION_ID;
  }

  /// Upgrades the contract to a new implementation and calls a function on the new contract.
  /// @notice Updates the slot ERC1967 slot
  /// @param newImplementation The address of the new contract implementation.
  /// @param data The calldata to be sent to the new implementation.
  function upgradeToAndCall(address newImplementation, bytes calldata data) public payable virtual override withHook {
    require(newImplementation != address(0), InvalidImplementationAddress());
    bool res;
    assembly {
      res := gt(extcodesize(newImplementation), 0)
    }
    if (!res) revert InvalidImplementationAddress();
    UUPSUpgradeable.upgradeToAndCall(newImplementation, data);
  }

  /// @dev For automatic detection that the smart account supports the ERC7739 workflow
  /// Iterates over all the validators but only if this is a detection request
  /// ERC-7739 spec assumes that if the account doesn't support ERC-7739
  /// it will try to handle the detection request as it was normal sig verification
  /// request and will return 0xffffffff since it won't be able to verify the 0x signature
  /// against 0x7739...7739 hash.
  /// So this approach is consistent with the ERC-7739 spec.
  /// If no validator supports ERC-7739, this function returns false
  /// thus the account will proceed with normal signature verification
  /// and return 0xffffffff as a result.
  function checkERC7739Support(bytes32 hash, bytes calldata signature) public view virtual returns (bytes4) {
    bytes4 result;
    unchecked {
      SentinelListLib.SentinelList storage validators = _getAccountStorage().validators;
      address next = validators.entries[SENTINEL];
      while (next != ZERO_ADDRESS && next != SENTINEL) {
        result = _get7739Version(next, result, hash, signature);
        next = validators.getNext(next);
      }
    }
    result = _get7739Version(_DEFAULT_VALIDATOR, result, hash, signature); // check default validator
    return result == bytes4(0) ? bytes4(0xffffffff) : result;
  }

  function _get7739Version(
    address validator,
    bytes4 prevResult,
    bytes32 hash,
    bytes calldata signature
  ) internal view returns (bytes4) {
    bytes4 support = IValidator(validator).isValidSignatureWithSender(msg.sender, hash, signature);
    if (bytes2(support) == bytes2(SUPPORTS_ERC7739) && support > prevResult) {
      return support;
    }
    return prevResult;
  }

  /// @dev Ensures that only authorized callers can upgrade the smart contract implementation.
  /// This is part of the UUPS (Universal Upgradeable Proxy Standard) pattern.
  /// @param newImplementation The address of the new implementation to upgrade to.
  function _authorizeUpgrade(address newImplementation) internal virtual override(UUPSUpgradeable) onlyEntryPointOrSelf {
    if (_amIERC7702()) {
      revert ERC7702AccountCannotBeUpgradedThisWay();
    }
  }

  // checks if there's at least one validator initialized
  function _checkInitializedValidators() internal view {
    if (!_amIERC7702() && !IValidator(_DEFAULT_VALIDATOR).isInitialized(address(this))) {
      unchecked {
        SentinelListLib.SentinelList storage validators = _getAccountStorage().validators;
        address next = validators.entries[SENTINEL];
        while (next != ZERO_ADDRESS && next != SENTINEL) {
          if (IValidator(next).isInitialized(address(this))) {
            break;
          }
          next = validators.getNext(next);
        }
        if (next == SENTINEL) {
          //went through all validators and none was initialized
          revert CanNotRemoveLastValidator();
        }
      }
    }
  }

  /// @dev EIP712 domain name and version.
  function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
    name = 'Startale';
    version = '1.0.0';
  }
}
