// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Role {
    bytes32 public constant ROLE_ADMIN = keccak256(abi.encode("ROLE_ADMIN"));
    bytes32 public constant DATA_ADMIN = keccak256(abi.encode("DATA_ADMIN"));

    bytes32 public constant CONFIG_ADMIN = keccak256(abi.encode("CONFIG_ADMIN"));
    bytes32 public constant INFO_ADMIN = keccak256(abi.encode("INFO_ADMIN"));
    bytes32 public constant PROPOSAL_ADMIN = keccak256(abi.encode("PROPOSAL_ADMIN"));
    bytes32 public constant REWARD_ADMIN = keccak256(abi.encode("REWARD_ADMIN"));
    bytes32 public constant REFERRAL_ADMIN = keccak256(abi.encode("REFERRAL_ADMIN"));
    bytes32 public constant VEST_ADMIN = keccak256(abi.encode("VEST_ADMIN"));

    bytes32 public constant TICKET_MINTER = keccak256(abi.encode("TICKET_MINTER"));

    bytes32 public constant TOKEN_MINTER = keccak256(abi.encode("TOKEN_MINTER"));
    bytes32 public constant TOKEN_BURNER = keccak256(abi.encode("TOKEN_BURNER"));

    bytes32 public constant NFT_MINTER = keccak256(abi.encode("NFT_MINTER"));
    bytes32 public constant NFT_BURNER = keccak256(abi.encode("NFT_BURNER"));
    bytes32 public constant NFT_VAULT_MANAGER = keccak256(abi.encode("NFT_VAULT_MANAGER"));

    bytes32 public constant FEE_COLLECTOR = keccak256(abi.encode("FEE_COLLECTOR"));
    bytes32 public constant POOL_STATE_ADMIN = keccak256(abi.encode("POOL_STATE_ADMIN"));

    bytes32 public constant CALLBACK_ADMIN = keccak256(abi.encode("CALLBACK_ADMIN"));
    bytes32 public constant CALLBACK_PARENT = keccak256(abi.encode("CALLBACK_PARENT"));
}
