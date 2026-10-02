// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import "./BaseERC20MetaHandler.sol";

/**
 * @title An OpenGSN- and meta-transaction-powered HTLC handler for ERC20 tokens
 * @notice This contract allows to perform HTLC interactions with ERC20 tokens without having to acquire the chains native token first.
 * The network fee is paid using the ERC20 token, which is converted automatically using UniSwap.
 */
contract ERC20MetaHTLCHandler is BaseERC20MetaHandler {
    mapping(bytes32 => HTLCData) public htlcs;

    /// Events

    event Open(bytes32 indexed id, IERC20Meta token, uint256 amount, address recipient, bytes32 hash, uint256 timeout);
    event Redeem(bytes32 indexed id, bytes32 secret);
    event Refund(bytes32 indexed id);

    struct HTLCData {
        IERC20Meta token;
        uint256 amount;
        address refund;
        address recipient;
        bytes32 hash;
        uint256 timeout;
    }

    struct OpenRequestData {
        bytes32 id;
        HTLCData htlc;
    }

    function checkOpenPrivate(address userAddress, OpenRequestData memory requestData, FeeInformation memory feeInformation) private view onlyWithWrappedChainToken onlyRegisteredToken(requestData.htlc.token) {
        require(htlcs[requestData.id].amount == 0, "HTLC: already registered");
        require(requestData.htlc.amount > 0, "HTLC: invalid amount");
        require(requestData.htlc.token.balanceOf(userAddress) >= requestData.htlc.amount + feeInformation.fee, "HTLC: balance too low");
    }

    function checkOpen(address userAddress, OpenRequestData memory requestData, FeeInformation memory feeInformation) internal view {
        checkOpenPrivate(userAddress, requestData, feeInformation);
        require(requestData.htlc.token.allowance(userAddress, address(this)) >= requestData.htlc.amount + feeInformation.fee, "HTLC: allowance too low");
    }

    function checkOpenWithApproval(address userAddress, OpenRequestData memory requestData, FeeInformation memory feeInformation, ApprovalRequestData memory approvalRequestData) internal view {
        checkOpenPrivate(userAddress, requestData, feeInformation);
        if (requestData.htlc.token.allowance(userAddress, address(this)) < requestData.htlc.amount + feeInformation.fee) {
            require(approvalRequestData.approval >= requestData.htlc.amount + feeInformation.fee, "HTLC: approval too low");
        }
    }

    function openPrivate(address userAddress, OpenRequestData memory requestData) private {
        require(requestData.htlc.token.transferFrom(userAddress, address(this), requestData.htlc.amount), "HTLC: Deposit transfer failed");
        deposits[requestData.htlc.token] = deposits[requestData.htlc.token] + requestData.htlc.amount;
        htlcs[requestData.id] = requestData.htlc;
    }

    function open(bytes32 id, IERC20Meta token, uint256 amount, address refundAddress, address recipientAddress, bytes32 hash, uint256 timeout, uint256 fee) public {
        HTLCData memory htlc = HTLCData(token, amount, refundAddress, recipientAddress, hash, timeout);
        OpenRequestData memory requestData = OpenRequestData(id, htlc);
        FeeInformation memory feeInformation = FeeInformation(token, msg.sender, fee, 0);
        checkOpen(msg.sender, requestData, feeInformation);
        processFeeInternal(feeInformation);
        openPrivate(msg.sender, requestData);
        emit Open(requestData.id, requestData.htlc.token, requestData.htlc.amount, requestData.htlc.recipient, requestData.htlc.hash, requestData.htlc.timeout);
        finishFeeInternal(feeInformation);
    }

    function approvePrivate(address userAddress, OpenRequestData memory requestData, FeeInformation memory feeInformation, ApprovalRequestData memory approvalRequestData) private {
        approveIfRequiredInternal(userAddress, approvalRequestData, requestData.htlc.amount + feeInformation.fee);
    }

    function openWithApproval(bytes32 id, IERC20Meta token, uint256 amount, address refundAddress, address recipientAddress, bytes32 hash, uint256 timeout, uint256 fee, uint256 approval, bytes32 sigR, bytes32 sigS, uint8 sigV) public {
        OpenRequestData memory requestData = OpenRequestData(id, HTLCData(token, amount, refundAddress, recipientAddress, hash, timeout));
        FeeInformation memory feeInformation = FeeInformation(token, msg.sender, fee, 0);
        ApprovalRequestData memory approvalRequestData = ApprovalRequestData(token, approval, sigR, sigS, sigV);
        checkOpenWithApproval(msg.sender, requestData, feeInformation, approvalRequestData);
        approvePrivate(msg.sender, requestData, feeInformation, approvalRequestData);
        processFeeInternal(feeInformation);
        openPrivate(msg.sender, requestData);
        emit Open(requestData.id, requestData.htlc.token, requestData.htlc.amount, requestData.htlc.recipient, requestData.htlc.hash, requestData.htlc.timeout);
        finishFeeInternal(feeInformation);
    }

    struct CloseRequestData {
        bytes32 id;
        address target;
    }

    function checkClosePrivate(CloseRequestData memory requestData, FeeInformation memory feeInformation) private view {
        require(htlcs[requestData.id].amount > feeInformation.fee, "HTLC: Fee too high");
    }

    function checkRedeem(address userAddress, bytes32 secret, CloseRequestData memory requestData, FeeInformation memory feeInformation) private view {
        checkClosePrivate(requestData, feeInformation);
        require(userAddress == htlcs[requestData.id].recipient, "HTLC: recipient address mismatch");
        require(sha256(abi.encodePacked(secret)) == htlcs[requestData.id].hash, "HTLC: secret mismatch");
    }

    function checkRefund(address userAddress, CloseRequestData memory requestData, FeeInformation memory feeInformation) private view {
        checkClosePrivate(requestData, feeInformation);
        require(userAddress == htlcs[requestData.id].refund, "HTLC: refund address mismatch");
        require(block.timestamp >= htlcs[requestData.id].timeout, "HTLC: illegal timeout");
    }

    function closePrivate(CloseRequestData memory requestData, FeeInformation memory feeInformation) private {
        htlcs[requestData.id].token.transfer(requestData.target, htlcs[requestData.id].amount - feeInformation.fee);
        deposits[htlcs[requestData.id].token] = deposits[htlcs[requestData.id].token] - htlcs[requestData.id].amount;
        delete htlcs[requestData.id];
    }

    function redeem(bytes32 id, address target, bytes32 secret, uint256 fee) public {
        CloseRequestData memory requestData = CloseRequestData(id, target);
        FeeInformation memory feeInformation = FeeInformation(htlcs[id].token, msg.sender, fee, 0);
        checkRedeem(msg.sender, secret, requestData, feeInformation);
        processFeeInternal(feeInformation);
        closePrivate(requestData, feeInformation);
        emit Redeem(id, secret);
        finishFeeInternal(feeInformation);
    }

    /* solhint-disable-next-line no-empty-blocks */
    function redeemWithSecretInData(bytes32 id, address target, uint256 fee) public {
        // This is a placeholder, the function only works via OpenGSN
    }

    function refund(bytes32 id, address target, uint256 fee) public {
        CloseRequestData memory requestData = CloseRequestData(id, target);
        FeeInformation memory feeInformation = FeeInformation(htlcs[id].token, msg.sender, fee, 0);
        checkRefund(msg.sender, requestData, feeInformation);
        processFeeInternal(feeInformation);
        closePrivate(requestData, feeInformation);
        emit Refund(id);
        finishFeeInternal(feeInformation);
    }

    function decodeOpenRequestDataPrivate(bytes memory data) private pure returns (OpenRequestData memory requestData) {
        requestData = OpenRequestData({
            id : bytes32(GsnUtils.getParam(data, 0)),
            htlc : HTLCData({
                token : IERC20Meta(address(uint160(GsnUtils.getParam(data, 1)))),
                amount : uint256(GsnUtils.getParam(data, 2)),
                refund : address(uint160(GsnUtils.getParam(data, 3))),
                recipient : address(uint160(GsnUtils.getParam(data, 4))),
                hash: bytes32(GsnUtils.getParam(data, 5)),
                timeout : uint256(GsnUtils.getParam(data, 6))
            })
        });
    }

    function decodeCloseRequestDataPrivate(bytes memory data, uint idIndex, uint targetIndex) private pure returns (CloseRequestData memory requestData) {
        requestData = CloseRequestData({
            id : bytes32(GsnUtils.getParam(data, idIndex)),
            target : address(uint160(GsnUtils.getParam(data, targetIndex)))
        });
    }

    function decodeRequestDataPrivate(bytes4 methodId, address payer, bytes memory data, uint256 chainTokenFee) private view returns (OpenRequestData memory openRequestData, CloseRequestData memory closeRequestData, FeeInformation memory feeInformation) {
        if (methodId == this.open.selector || methodId == this.openWithApproval.selector) {
            openRequestData = decodeOpenRequestDataPrivate(data);
            feeInformation = decodeFeeInformationInternal(data, openRequestData.htlc.token, payer, 7, chainTokenFee);
        } else if (methodId == this.redeem.selector || methodId == this.redeemWithSecretInData.selector || methodId == this.refund.selector) {
            closeRequestData = decodeCloseRequestDataPrivate(data, 0, 1);
            if (methodId == this.redeem.selector) {
                feeInformation = decodeFeeInformationInternal(data, htlcs[closeRequestData.id].token, address(this), 3, chainTokenFee);
            } else {
                feeInformation = decodeFeeInformationInternal(data, htlcs[closeRequestData.id].token, address(this), 2, chainTokenFee);
            }
        } else {
            require(false, "HTLC: unsupported method");
        }
    }

    function verifyCallPrivate(IForwarder.ForwardRequest memory request, GsnTypes.RelayData calldata relayData, bytes memory signature, bytes memory approvalData) private view returns (OpenRequestData memory openRequestData, CloseRequestData memory closeRequestData, FeeInformation memory feeInformation, ApprovalRequestData memory approvalRequestData, bytes32 secret) {
        bytes memory suffixData = abi.encode(GsnEip712Library.hashRelayData(relayData));
        bytes32 _domainSeparator = GsnEip712Library.domainSeparator(relayData.forwarder);
        verifyInternal(request, _domainSeparator, GsnEip712Library.RELAY_REQUEST_TYPEHASH, suffixData, signature);

        bytes4 methodId = GsnUtils.getMethodSig(request.data);
        (openRequestData, closeRequestData, feeInformation) = decodeRequestDataPrivate(methodId, request.from, request.data, getRequiredRelayFee(relayData, methodId));

        if (methodId == this.open.selector || methodId == this.openWithApproval.selector) {
            if (methodId == this.open.selector) {
                checkOpen(request.from, openRequestData, feeInformation);
            } else {
                approvalRequestData = decodeApprovalRequestDataInternal(request.data, 1, 8, 9);
                checkOpenWithApproval(request.from, openRequestData, feeInformation, approvalRequestData);
            }
        } else if (methodId == this.redeem.selector || methodId == this.redeemWithSecretInData.selector || methodId == this.refund.selector) {
            if (methodId == this.refund.selector) {
                checkRefund(request.from, closeRequestData, feeInformation);
            } else {
                if (methodId == this.redeemWithSecretInData.selector) {
                    secret = bytes32(approvalData);
                } else {
                    secret = bytes32(GsnUtils.getParam(request.data, 2));
                }
                checkRedeem(request.from, secret, closeRequestData, feeInformation);
            }
        }
    }

    function preRelayedCall(GsnTypes.RelayRequest calldata relayRequest, bytes calldata signature, bytes calldata approvalData, uint256 maxPossibleGas) external override virtual onlyRelayHub onlyToSelf(relayRequest) returns (bytes memory context, bool revertOnRecipientRevert) {
        (relayRequest, signature, approvalData, maxPossibleGas);
        require(relayRequest.request.to == address(this), "Meta: illegal request.to");
        require(relayRequest.request.nonce == getNonce(relayRequest.request.from), "Meta: Invalid nonce");

        (OpenRequestData memory openRequestData, CloseRequestData memory closeRequestData, FeeInformation memory feeInformation, ApprovalRequestData memory approvalRequestData, bytes32 secret) = verifyCallPrivate(relayRequest.request, relayRequest.relayData, signature, approvalData);
        (closeRequestData);
        if (approvalRequestData.approval != 0) {
            approvePrivate(relayRequest.request.from, openRequestData, feeInformation, approvalRequestData);
        }
        processFeeInternal(feeInformation);

        context = abi.encode(relayRequest.request, secret, feeInformation.chainTokenFee);
        revertOnRecipientRevert = true;
    }

    function execute(ForwardRequest calldata request, bytes32 domainSeparator, bytes32 requestTypeHash, bytes calldata suffixData, bytes calldata signature) public override payable onlyRelayHub returns (bool success, bytes memory ret) {
        (request, domainSeparator, requestTypeHash, suffixData, signature);

        bytes4 methodId = GsnUtils.getMethodSig(request.data);
        // chainTokenFee is not needed here, so we just set it to 0
        (OpenRequestData memory openRequestData, CloseRequestData memory closeRequestData, FeeInformation memory feeInformation) = decodeRequestDataPrivate(methodId, request.from, request.data, 0);
        nonces[request.from] = nonces[request.from] + 1;
        if (methodId == this.open.selector || methodId == this.openWithApproval.selector) {
            openPrivate(request.from, openRequestData);
        } else {
            closePrivate(closeRequestData, feeInformation);
        }

        success = true;
        ret = "";
    }

    function postRelayedCall(bytes calldata context, bool success, uint256 gasUseWithoutPost, GsnTypes.RelayData calldata relayData) external override virtual onlyRelayHub {
        (context, success, gasUseWithoutPost, relayData);

        (IForwarder.ForwardRequest memory request, bytes32 secret, uint256 chainTokenFee) = abi.decode(context, (IForwarder.ForwardRequest, bytes32, uint256));
        bytes4 methodId = GsnUtils.getMethodSig(request.data);
        (OpenRequestData memory openRequestData, CloseRequestData memory closeRequestData, FeeInformation memory feeInformation) = decodeRequestDataPrivate(methodId, request.from, request.data, chainTokenFee);
        if (methodId == this.open.selector || methodId == this.openWithApproval.selector) {
            emit Open(openRequestData.id, openRequestData.htlc.token, openRequestData.htlc.amount, openRequestData.htlc.recipient, openRequestData.htlc.hash, openRequestData.htlc.timeout);
        } else if (methodId == this.refund.selector) {
            emit Refund(closeRequestData.id);
        } else if (methodId == this.redeem.selector || methodId == this.redeemWithSecretInData.selector) {
            emit Redeem(closeRequestData.id, secret);
        }
        finishFeeInternal(feeInformation);
    }

    function relayWithoutGsn(GsnTypes.RelayRequest calldata relayRequest, bytes calldata signature, bytes calldata approvalData, address payable relay) public {
        require(relayRequest.request.to == address(this), "Meta: illegal request.to");
        require(relayRequest.request.nonce == getNonce(relayRequest.request.from), "Meta: Invalid nonce");
        bytes4 methodId = GsnUtils.getMethodSig(relayRequest.request.data);
        (OpenRequestData memory openRequestData, CloseRequestData memory closeRequestData, FeeInformation memory feeInformation, ApprovalRequestData memory approvalRequestData, bytes32 secret) = verifyCallPrivate(relayRequest.request, relayRequest.relayData, signature, approvalData);
        if (approvalRequestData.approval != 0) {
            approvePrivate(relayRequest.request.from, openRequestData, feeInformation, approvalRequestData);
        }
        processFeeInternal(feeInformation);
        nonces[relayRequest.request.from] = nonces[relayRequest.request.from] + 1;
        if (methodId == this.open.selector || methodId == this.openWithApproval.selector) {
            openPrivate(relayRequest.request.from, openRequestData);
            emit Open(openRequestData.id, openRequestData.htlc.token, openRequestData.htlc.amount, openRequestData.htlc.recipient, openRequestData.htlc.hash, openRequestData.htlc.timeout);
        } else if (methodId == this.refund.selector) {
            closePrivate(closeRequestData, feeInformation);
            emit Refund(closeRequestData.id);
        } else if (methodId == this.redeem.selector || methodId == this.redeemWithSecretInData.selector) {
            closePrivate(closeRequestData, feeInformation);
            emit Redeem(closeRequestData.id, secret);
        }
        finishFeeWithCustomTargetInternal(feeInformation, relay);
    }

    function versionRecipient() external override virtual view returns (string memory) {
        return "2.2.6+opengsn.recipient.erc20meta.htlc.handler";
    }

    function versionPaymaster() external override virtual view returns (string memory) {
        return "2.2.6+opengsn.paymaster.erc20meta.htlc.handler";
    }

    constructor() {
        registerRequestTypeInternal(string(abi.encodePacked("ForwardRequest(", GsnEip712Library.GENERIC_PARAMS, ")")));
        registerRequestTypeInternal(GsnEip712Library.RELAY_REQUEST_NAME, GsnEip712Library.RELAY_REQUEST_SUFFIX);
        registerDomainSeparatorInternal("GSN Relayed Transaction", "2");
    }
}