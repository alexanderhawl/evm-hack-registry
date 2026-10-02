// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IBaseAccount} from '../interfaces/core/IBaseAccount.sol';
import {IEntryPoint} from '@account-abstraction/interfaces/IEntryPoint.sol';

/// @title BaseAccount
/// @notice Implements ERC-4337 and ERC-7579 standards for account management and access control.
/// @dev Manages entry points and configurations as specified in the ERC-4337 and ERC-7579 documentation.
/// @author Startale Labs
/// Special thanks to the Biconomy team for https://github.com/bcnmy/nexus/ and ERC7579 reference implementation on which this implementation is highly based on.
contract BaseAccount is IBaseAccount {
  /// @notice Identifier for this implementation on the network
  string internal constant _ACCOUNT_IMPLEMENTATION_ID = 'startale.smart-account.1.0.0';

  /// @notice The canonical address for the ERC4337 EntryPoint contract, version 0.7.
  /// This address is consistent across all supported networks.
  address internal immutable _ENTRYPOINT;

  /// @dev Ensures the caller is either the EntryPoint or this account itself.
  /// Reverts with AccountAccessUnauthorized if the check fails.
  modifier onlyEntryPointOrSelf() {
    require(msg.sender == _ENTRYPOINT || msg.sender == address(this), AccountAccessUnauthorized());
    _;
  }

  /// @dev Ensures the caller is the EntryPoint.
  /// Reverts with AccountAccessUnauthorized if the check fails.
  modifier onlyEntryPoint() {
    require(msg.sender == _ENTRYPOINT, AccountAccessUnauthorized());
    _;
  }

  /// @dev Sends to the EntryPoint (i.e. `msg.sender`) the missing funds for this transaction.
  /// Subclass MAY override this modifier for better funds management.
  /// (e.g. send to the EntryPoint more than the minimum required, so that in future transactions
  /// it will not be required to send again)
  ///
  /// `missingAccountFunds` is the minimum value this modifier should send the EntryPoint,
  /// which MAY be zero, in case there is enough deposit, or the userOp has a paymaster.
  modifier payPrefund(uint256 missingAccountFunds) virtual {
    _;
    /// @solidity memory-safe-assembly
    assembly {
      if missingAccountFunds {
        // Ignore failure (it's EntryPoint's job to verify, not the account's).
        pop(call(gas(), caller(), missingAccountFunds, 0, 0, 0, 0))
      }
    }
  }

  /// @notice Adds deposit to the EntryPoint to fund transactions.
  function addDeposit() external payable virtual {
    address entryPointAddress = _ENTRYPOINT;
    /// @solidity memory-safe-assembly
    assembly {
      // The EntryPoint has balance accounting logic in the `receive()` function.
      if iszero(call(gas(), entryPointAddress, callvalue(), codesize(), 0x00, codesize(), 0x00)) {
        revert(codesize(), 0x00)
      } // For gas estimation.
    }
  }

  /// @notice Withdraws ETH from the EntryPoint to a specified address.
  /// @param to The address to receive the withdrawn funds.
  /// @param amount The amount to withdraw.
  function withdrawDepositTo(address to, uint256 amount) external payable virtual onlyEntryPointOrSelf {
    address entryPointAddress = _ENTRYPOINT;
    assembly {
      let freeMemPtr := mload(0x40) // Store the free memory pointer.

      mstore(freeMemPtr, shl(224, 0x205c2878)) // `withdrawTo(address,uint256)` selector
      mstore(add(freeMemPtr, 0x04), to) // Store the `to` argument.
      mstore(add(freeMemPtr, 0x24), amount) // Store the `amount` argument.

      if iszero(call(gas(), entryPointAddress, 0, freeMemPtr, 0x44, 0, 0)) {
        let rdsize := returndatasize()
        returndatacopy(freeMemPtr, 0, rdsize)
        revert(freeMemPtr, rdsize)
      }

      // Update the free memory pointer (ptr + 0x44)
      mstore(0x40, add(freeMemPtr, 0x44))
    }
  }

  /// @notice Gets the nonce for a particular key.
  /// @param key The nonce key.
  /// @return The nonce associated with the key.
  function nonce(uint192 key) external view virtual returns (uint256) {
    return IEntryPoint(_ENTRYPOINT).getNonce(address(this), key);
  }

  /// @notice Returns the current deposit balance of this account on the EntryPoint.
  /// @return result The current balance held at the EntryPoint.
  function getDeposit() external view virtual returns (uint256 result) {
    address entryPointAddress = _ENTRYPOINT;
    /// @solidity memory-safe-assembly
    assembly {
      mstore(0x20, address()) // Store the `account` argument.
      mstore(0x00, 0x70a08231) // `balanceOf(address)`.
      result :=
        mul(
          // Returns 0 if the EntryPoint does not exist.
          mload(0x20),
          and(
            // The arguments of `and` are evaluated from right to left.
            gt(returndatasize(), 0x1f), // At least 32 bytes returned.
            staticcall(gas(), entryPointAddress, 0x1c, 0x24, 0x20, 0x20)
          )
        )
    }
  }

  /// @notice Retrieves the address of the EntryPoint contract, currently using version 0.7.
  /// @dev This function returns the address of the canonical ERC4337 EntryPoint contract.
  /// It can be overridden to return a different EntryPoint address if needed.
  /// @return The address of the EntryPoint contract.
  function entryPoint() external view returns (address) {
    return _ENTRYPOINT;
  }
}
