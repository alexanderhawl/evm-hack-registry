// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAllStorage} from '../interfaces/core/IAllStorage.sol';

/// @title Startale - Storage
/// @notice Manages isolated storage spaces for Modular Smart Account in compliance with ERC-7201 standard to ensure collision-resistant storage.
/// @dev Implements the ERC-7201 namespaced storage pattern to maintain secure and isolated storage sections for different states within Startale suite.
/// @author Startale Labs
contract AllStorage is IAllStorage {
  /// @custom:storage-location erc7201:startale.account.storage
  /// ERC-7201 namespaced via `keccak256(abi.encode(uint256(keccak256(bytes("startale.account.storage"))) - 1)) & ~bytes32(uint256(0xff));`
  bytes32 private constant _STORAGE_LOCATION = 0x9195d48440658ac27f13a7bd256a2e74da1f2416f468d66228b37e6ac4790c00;

  /// @dev Utilizes ERC-7201's namespaced storage pattern for isolated storage access. This method computes
  /// the storage slot based on a predetermined location, ensuring collision-resistant storage for contract states.
  /// @custom:storage-location ERC-7201 formula applied to "startale.account.storage", facilitating unique
  /// namespace identification and storage segregation, as detailed in the specification.
  /// @return $ The proxy to the `AccountStorage` struct, providing a reference to the namespaced storage slot.
  function _getAccountStorage() internal pure returns (AccountStorage storage $) {
    assembly {
      $.slot := _STORAGE_LOCATION
    }
  }
}
