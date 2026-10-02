// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ExecType, ExecutionMode} from '../../lib/ModeLib.sol';

/// @title IExecutionHelper
/// @notice Interface for executing transactions on behalf of smart account.
/// @author Startale Labs
/// Special thanks to the ERC7579 authors and reference implementation on which this implementation is highly based on.
interface IExecutionHelper {
  /// @notice Event emitted when a transaction fails to execute successfully.
  event TryExecuteUnsuccessful(address target, bytes callData, bytes result);

  /// @notice Event emitted when a transaction fails to execute successfully.
  event TryDelegateCallUnsuccessful(bytes callData, bytes result);

  /// @notice Error thrown when an execution with an unsupported ExecType was made.
  /// @param execType The unsupported execution type.
  error UnsupportedExecType(ExecType execType);

  /// @notice Executes a transaction with specified execution mode and calldata.
  /// @param mode The execution mode, defining how the transaction is processed.
  /// @param executionCalldata The calldata to execute.
  /// @dev This function ensures that the execution complies with smart account execution policies and handles errors appropriately.
  function execute(ExecutionMode mode, bytes calldata executionCalldata) external payable;

  /// @notice Allows an executor module to perform transactions on behalf of the account.
  /// @param mode The execution mode that details how the transaction should be handled.
  /// @param executionCalldata The transaction data to be executed.
  /// @return returnData The result of the execution, allowing for error handling and results interpretation by the executor module.
  function executeFromExecutor(
    ExecutionMode mode,
    bytes calldata executionCalldata
  ) external payable returns (bytes[] memory returnData);
}
