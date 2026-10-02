// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CallType} from '../../lib/ModeLib.sol';
import {IHook, IPreValidationHookERC1271, IPreValidationHookERC4337} from '../IERC7579Module.sol';
import {SentinelListLib} from 'sentinellist/SentinelList.sol';

/// @title IStorage Interface
/// @dev This interface utilizes ERC-7201 storage location practices to ensure isolated and collision-resistant storage spaces within smart contracts.
/// @custom:storage-location erc7201:startale.account.storage
/// @author Startale Labs
interface IAllStorage {
  /// @notice Struct storing validators and executors using Sentinel lists, and fallback handlers via mapping.
  struct AccountStorage {
    ///< List of validators, initialized upon contract deployment.
    SentinelListLib.SentinelList validators;
    ///< List of executors, similarly initialized.
    SentinelListLib.SentinelList executors;
    ///< Mapping of selectors to their respective fallback handlers.
    mapping(bytes4 => FallbackHandler) fallbacks;
    ///< List of fallback selectors, initialized upon contract deployment.
    bytes4[] fallbackSelectors;
    ///< ERC-165 interfaces installed on the account.
    mapping(bytes4 => bool) supportedIfaces;
    ///< List of installed interfaces, initialized upon contract deployment.
    bytes4[] installedIfaces;
    ///< Current hook module associated with this account.
    IHook hook;
    ///< Mapping of hooks to requested timelocks.
    mapping(address hook => uint256) emergencyUninstallTimelock;
    ///< PreValidation hook for validateUserOp
    IPreValidationHookERC4337 preValidationHookERC4337;
    ///< PreValidation hook for isValidSignature
    IPreValidationHookERC1271 preValidationHookERC1271;
    ///< Mapping of used nonces for replay protection.
    mapping(uint256 => bool) nonces;
  }

  /// @notice Defines a fallback handler with an associated handler address and a call type.
  struct FallbackHandler {
    ///< The address of the fallback function handler.
    address handler;
    ///< The type of call this handler supports (e.g., static or call).
    CallType calltype;
  }
}
