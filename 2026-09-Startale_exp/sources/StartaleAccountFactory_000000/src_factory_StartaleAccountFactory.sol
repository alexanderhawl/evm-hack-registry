// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IStartaleAccountFactory} from '../interfaces/IStartaleAccountFactory.sol';
import {ProxyLib} from '../lib/ProxyLib.sol';
import {Stakeable} from '../utils/Stakeable.sol';

/// @title Startale Account Factory
/// @dev Generic Account Factory which can deploy SA with more modules (multiple validation schemes, executors, hooks etc upon deployment itself)
/// @notice Manages the creation of Modular Smart Accounts compliant with ERC-7579 and ERC-4337 using a factory pattern.
/// @author Startale labs
contract StartaleAccountFactory is Stakeable, IStartaleAccountFactory {
  /// @notice Address of the implementation contract used to create new Startale Account instances.
  /// @dev This address is immutable and set upon deployment, ensuring the implementation cannot be changed.
  address public immutable ACCOUNT_IMPLEMENTATION;

  /// @notice Constructor to set the smart account implementation address and the factory owner.
  /// @param implementation_ The address of the Startale Account implementation to be used for all deployments.
  /// @param owner_ The address of the owner of the factory.
  constructor(address implementation_, address owner_) Stakeable(owner_) {
    require(implementation_ != address(0), ImplementationAddressCanNotBeZero());
    require(owner_ != address(0), ZeroAddressNotAllowed());
    require(implementation_.code.length > 0, ImplementationNotDeployed());
    ACCOUNT_IMPLEMENTATION = implementation_;
  }

  /// @notice Creates a new Startale Account with the provided initialization data.
  /// @param initData Initialization data to be called on the new Smart Account.
  /// @param salt Unique salt for the Smart Account creation.
  /// @return The address of the newly created Startale Account.
  function createAccount(bytes calldata initData, bytes32 salt) external payable override returns (address payable) {
    // Deploy the Startale Account using the ProxyLib
    (bool alreadyDeployed, address payable account) = ProxyLib.deployProxy(ACCOUNT_IMPLEMENTATION, salt, initData);
    if (!alreadyDeployed) {
      emit AccountCreated(account, initData, salt);
    }
    return account;
  }

  /// @notice Computes the expected address of a Startale Account using the factory's deterministic deployment algorithm.
  /// @param initData - Initialization data to be called on the new Smart Account.
  /// @param salt - Unique salt for the Smart Account creation.
  /// @return expectedAddress The expected address at which the Startale Account will be deployed if the provided parameters are used.
  function computeAccountAddress(
    bytes calldata initData,
    bytes32 salt
  ) external view override returns (address payable expectedAddress) {
    // Return the expected address of the Startale Account using the provided initialization data and salt
    return ProxyLib.predictProxyAddress(ACCOUNT_IMPLEMENTATION, salt, initData);
  }
}
