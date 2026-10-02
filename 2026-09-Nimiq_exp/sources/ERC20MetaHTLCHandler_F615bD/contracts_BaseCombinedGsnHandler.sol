// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@opengsn/contracts/src/interfaces/IPaymaster.sol";
import "@opengsn/contracts/src/interfaces/IRelayHub.sol";
import "@opengsn/contracts/src/interfaces/IRelayRecipient.sol";
import "@opengsn/contracts/src/forwarder/IForwarder.sol";
import "@opengsn/contracts/src/utils/GsnEip712Library.sol";
import "@opengsn/contracts/src/utils/GsnUtils.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

abstract contract BaseCombinedGsnHandler is IRelayRecipient, IPaymaster, IForwarder, Ownable {
    IRelayHub internal relayHub;

    using ECDSA for bytes32;

    string public constant EIP712_DOMAIN_TYPE = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";

    mapping(bytes32 => bool) public typeHashes;
    mapping(bytes32 => bool) public domains;

    IPaymaster.GasAndDataLimits private gasAndDataLimits = IPaymaster.GasAndDataLimits({
        acceptanceBudget: 250000,
        preRelayedCallGasLimit: 250000,
        postRelayedCallGasLimit: 100000,
        calldataSizeLimit: 2048
    });

    mapping(bytes4 => uint256) private methodRequiredRelayGas;
    uint256 private maxRequiredRelayGas = 500000;

    modifier onlyToSelf(GsnTypes.RelayRequest calldata relayRequest) {
        require(relayRequest.request.to == address(this), "Base: illegal request.to");
        _;
    }

    modifier onlyRelayHub() {
        require(msg.sender == getHubAddr(), "Base: illegal msg.sender");
        _;
    }

    function verify(ForwardRequest calldata forwardRequest, bytes32 domainSeparator, bytes32 requestTypeHash, bytes calldata suffixData, bytes calldata signature) public override view {
        verifyInternal(forwardRequest, domainSeparator, requestTypeHash, suffixData, signature);
    }

    function verifyInternal(ForwardRequest memory forwardRequest, bytes32 domainSeparator, bytes32 requestTypeHash, bytes memory suffixData, bytes memory signature) internal view {
        require(domains[domainSeparator], "Base: unregistered domain sep.");
        require(typeHashes[requestTypeHash], "Base: unregistered typehash");
        bytes memory encoded = abi.encodePacked(
            requestTypeHash,
            uint256(uint160(forwardRequest.from)),
            uint256(uint160(forwardRequest.to)),
            forwardRequest.value,
            forwardRequest.gas,
            forwardRequest.nonce,
            keccak256(forwardRequest.data),
            forwardRequest.validUntil,
            suffixData
        );
        bytes32 digest = keccak256(abi.encodePacked(
                "\x19\x01", domainSeparator,
                keccak256(encoded)
            ));
        require(digest.recover(signature) == forwardRequest.from, "Base: signature mismatch");
    }

    function isTrustedForwarder(address forwarder) public override view returns (bool) {
        return forwarder == address(this);
    }

    function trustedForwarder() override(IPaymaster) public view returns (address forwarder){
        forwarder = address(this);
    }

    function getHubAddr() public override view returns (address) {
        return address(relayHub);
    }

    function getRelayHubDeposit() public override view returns (uint) {
        return relayHub.balanceOf(address(this));
    }

    function getGasAndDataLimits() public override virtual view returns (IPaymaster.GasAndDataLimits memory limits) {
        return gasAndDataLimits;
    }

    function setGasAndDataLimits(IPaymaster.GasAndDataLimits calldata limits) public onlyOwner {
        gasAndDataLimits = limits;
    }

    function setRelayHub(IRelayHub hub) public onlyOwner {
        relayHub = hub;
    }

    // @dev deprecated
    function requiredRelayGas() public view returns (uint256) {
        return maxRequiredRelayGas;
    }

    // @dev deprecated
    function setMaxRequiredRelayGas(uint256 gas) public onlyOwner {
        maxRequiredRelayGas = gas;
    }

    // @dev deprecated
    function getMinimumRelayFee(GsnTypes.RelayData calldata relayData) public view returns (uint256 amount) {
        amount = relayHub.calculateCharge(requiredRelayGas(), relayData);
    }

    function getRequiredRelayGas(bytes4 methodId) public view returns (uint256 gas) {
        gas = methodRequiredRelayGas[methodId];
        if (gas == 0) gas = maxRequiredRelayGas;
    }

    function getRequiredRelayFee(GsnTypes.RelayData calldata relayData, bytes4 methodId) public view returns (uint256 amount) {
        amount = relayHub.calculateCharge(getRequiredRelayGas(methodId), relayData);
    }

    function setRequiredRelayGas(bytes4 methodId, uint256 gas) public onlyOwner {
        methodRequiredRelayGas[methodId] = gas;
        if (gas > maxRequiredRelayGas) maxRequiredRelayGas = gas;
    }

    function _msgSender() internal view override(Context, IRelayRecipient) returns (address sender) {
        return Context._msgSender();
    }

    function _msgData() internal view override(Context, IRelayRecipient) returns (bytes calldata) {
        return Context._msgData();
    }

    function withdrawRelayHubDeposit(uint amount, address payable target) public onlyOwner {
        relayHub.withdraw(amount, target);
    }

    function registerDomainSeparator(string calldata name, string calldata version) public override {
        registerDomainSeparatorInternal(name, version);
    }

    function registerDomainSeparatorInternal(string memory name, string memory version) internal {
        uint256 chainId;
        /* solhint-disable-next-line no-inline-assembly */
        assembly {chainId := chainid()}

        bytes memory domainValue = abi.encode(
            keccak256(bytes(EIP712_DOMAIN_TYPE)),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId,
            address(this));

        bytes32 domainHash = keccak256(domainValue);

        domains[domainHash] = true;
        emit DomainRegistered(domainHash, domainValue);
    }

    function registerRequestType(string calldata typeName, string calldata typeSuffix) public override {
        registerRequestTypeInternal(typeName, typeSuffix);
    }

    function registerRequestTypeInternal(string memory typeName, string memory typeSuffix) internal {
        for (uint i = 0; i < bytes(typeName).length; i++) {
            bytes1 c = bytes(typeName)[i];
            require(c != "(" && c != ")", "Base: invalid typename");
        }

        string memory requestType = string(abi.encodePacked(typeName, "(", GsnEip712Library.GENERIC_PARAMS, ",", typeSuffix));
        registerRequestTypeInternal(requestType);
    }

    function registerRequestTypeInternal(string memory requestType) internal {
        bytes32 requestTypehash = keccak256(bytes(requestType));
        typeHashes[requestTypehash] = true;
        emit RequestTypeRegistered(requestTypehash, requestType);
    }
}
