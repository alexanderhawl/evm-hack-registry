// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./RoleStore.sol";

contract RoleModule {
    RoleStore public immutable roleStore;

    constructor(RoleStore _roleStore) {
        roleStore = _roleStore;
    }

    modifier onlyRole(bytes32 role) {
        roleStore.checkRole(msg.sender, role);
        _;
    }

    modifier onlyDataAdmin() {
        roleStore.checkRole(msg.sender, Role.DATA_ADMIN);
        _;
    }
}
