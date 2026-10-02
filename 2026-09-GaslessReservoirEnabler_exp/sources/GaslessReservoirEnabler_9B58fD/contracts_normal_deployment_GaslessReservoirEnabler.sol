// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Context } from "@openzeppelin/contracts/utils/Context.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { EIP712MetaTransaction } from "../base/EIP712/EIP712MetaTransaction.sol";
import { TransferrableAdminRole } from "../base/TransferrableAdminRole.sol";

/**
 * @title GaslessReservoirEnabler
 * @dev A contract that enables gasless execution of batched orders by transferring ERC20 tokens and executing specified modules.
 * It offers EIP712 meta-transaction support and has a module whitelisting functionality to control which contracts can be executed.
 */
contract GaslessReservoirEnabler is ReentrancyGuard, TransferrableAdminRole, EIP712MetaTransaction {
    using Address for address;
    using SafeERC20 for IERC20;

    // --- Structs ---

    struct ERC20Transfer {
        IERC20 token;
        uint256 amount;
    }

    struct ExecutionInfo {
        address module;
        bytes data;
        uint256 value;
    }

    // --- Errors ---

    error UnsuccessfulExecution();

    error UnchangedWhitelistStatus();

    error NonWhitelistedModule();

    error InvalidInput();

    // --- Fields ---
    mapping(address => bool) public moduleWhitelist;

    // --- Constructor ---

    /**
     * @dev Initializes the GaslessReservoirEnabler contract with the specified admin address.
     * @param admin The address of the contract admin.
     */
    constructor(address admin) TransferrableAdminRole(admin) {}

    // --- Public methods ---

    /**
     * @dev Transfers ERC20 tokens and executes specified modules.
     * @param erc20sTransfers An array of ERC20Transfer structs containing the ERC20 token and amount to transfer.
     * @param executionInfos An array of ExecutionInfo structs containing the module address, data, and value to execute.
     */
    function erc20WithTransfersAndExecute(
        ERC20Transfer[] calldata erc20sTransfers,
        ExecutionInfo[] calldata executionInfos
    ) external nonReentrant {
        uint256 executionInfosLength = executionInfos.length;
        if (executionInfosLength == 0) {
            revert InvalidInput();
        }
        uint256 erc20sTransfersLength = erc20sTransfers.length;
        for (uint256 i = 0; i < erc20sTransfersLength; ) {
            ERC20Transfer memory erc20Transfer = erc20sTransfers[i];
            IERC20 token = erc20Transfer.token;
            token.safeTransferFrom(_msgSender(), address(this), erc20Transfer.amount);

            unchecked {
                ++i;
            }
        }

        for (uint256 i = 0; i < executionInfos.length; i++) {
            _executeInternal(executionInfos[i]);
        }
    }

    /**
     * @dev Sets the whitelist status of a module.
     * @param module The address of the module.
     * @param status The whitelist status to set.
     */
    function setModuleWhitelistStatus(address module, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (module == address(0)) {
            revert InvalidInput();
        }
        bool currentStatus = moduleWhitelist[module];
        if (currentStatus == status) {
            revert UnchangedWhitelistStatus();
        }
        moduleWhitelist[module] = status;
    }

    // --- Internal ---

    function _executeInternal(ExecutionInfo calldata executionInfo) internal {
        address module = executionInfo.module;

        // Ensure the target is whitelisted
        if (!moduleWhitelist[module]) {
            revert NonWhitelistedModule();
        }

        // Ensure the target is a contract
        if (!module.isContract()) {
            revert UnsuccessfulExecution();
        }

        (bool success, ) = module.call{ value: executionInfo.value }(executionInfo.data);
        if (!success) {
            revert UnsuccessfulExecution();
        }
    }

    /// @dev returns the message sender of a transaction, not the relayer
    /// @return sender representing the message sender
    function _msgSender() internal view override returns (address sender) {
        sender = EIP712MetaTransaction.msgSender();
    }
}
