// SPDX-FileCopyrightText: © 2022 Virtually Human Studio

// SPDX-License-Identifier: No-license

pragma solidity 0.8.11;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title TransferrableAdminRole
 * @notice Contract that allows to grant or revoke roles to an address, but prevents the DEFAULT_ADMIN_ROLE to be completely renounced.
 */
abstract contract TransferrableAdminRole is AccessControl {
    /// @notice holds the admins count
    uint256 public adminRoleCount;

    constructor(address adminAccount) {
        require(adminAccount != address(0), "TransferrableAdminRole: invalid admin account");
        _setupRole(DEFAULT_ADMIN_ROLE, adminAccount);
        adminRoleCount = 1;
    }

    /**
     * @notice Renounce a role. Doesn't allow the last member of DEFAULT_ADMIN_ROLE to renounce.
     * @dev Use `transferDefaultAdmin` when you want to renounce the DEFAULT_ADMIN role from the last member.
     * @param role The role to be renounced
     * @param account The account to be removed from the role
     */
    function renounceRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) {
            require(adminRoleCount > 1, "TransferrableAdminRole: Last member of DEFAULT_ADMIN_ROLE");
            adminRoleCount--;
        }
        super.renounceRole(role, account);
    }

    /**
     * @notice Grant a role to an account.
     * @param role The role to be granted
     * param account The account to grant the role to
     */
    function grantRole(bytes32 role, address account) public virtual override {
        if (role == DEFAULT_ADMIN_ROLE) {
            require(account != address(0), "TransferrableAdminRole: Cannot transfer default admin to zero address");
            require(account != _msgSender(), "TransferrableAdminRole: Cannot transfer default admin to current admin");
            adminRoleCount++;
        }

        super.grantRole(role, account);
    }

    /**
     * @notice Transfer the default admin role to another account and renounce it.
     * @param newAdminAccount The new admin account
     */
    function transferAndRenounceDefaultAdmin(address newAdminAccount) external {
        grantRole(DEFAULT_ADMIN_ROLE, newAdminAccount);
        super.renounceRole(DEFAULT_ADMIN_ROLE, _msgSender());
    }
}
