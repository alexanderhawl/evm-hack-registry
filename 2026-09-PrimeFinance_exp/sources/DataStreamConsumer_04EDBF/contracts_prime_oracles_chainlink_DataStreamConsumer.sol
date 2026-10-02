// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Common} from "@chainlink/contracts/src/v0.8/llo-feeds/libraries/Common.sol";
import {IVerifierFeeManager} from "@chainlink/contracts/src/v0.8/llo-feeds/v0.3.0/interfaces/IVerifierFeeManager.sol";
import {IERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/utils/SafeERC20.sol";

interface IVerifierProxy {
	/**
	 * @notice Route a report to the correct verifier and (optionally) bill fees.
	 * @param payload           Full report payload (header + signed report).
	 * @param parameterPayload  ABI-encoded fee metadata.
	 */
	function verify(
		bytes calldata payload,
		bytes calldata parameterPayload
	) external payable returns (bytes memory verifierResponse);

	function verifyBulk(
		bytes[] calldata payloads,
		bytes calldata parameterPayload
	) external payable returns (bytes[] memory verifiedReports);

	function s_feeManager() external view returns (IVerifierFeeManager);
}

interface IFeeManager {
	/**
	 * @return fee, reward, totalDiscount
	 */
	function getFeeAndReward(
		address subscriber,
		bytes memory unverifiedReport,
		address quoteAddress
	) external returns (Common.Asset memory, Common.Asset memory, uint256);

	function i_linkAddress() external view returns (address);

	function i_nativeAddress() external view returns (address);

	function i_rewardManager() external view returns (address);
}

contract DataStreamConsumer {
	using SafeERC20 for IERC20;

	// ----------------- Errors -----------------
	error NothingToWithdraw();
	error NotOwner(address caller);
	error InvalidReportVersion(uint16 version);
	error NotImplemented();
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);

	// ----------------- Report schemas -----------------
	// More info: https://docs.chain.link/data-streams/reference/report-schema

	struct ReportV2 {
		bytes32 feedId;
		uint32 validFromTimestamp;
		uint32 observationsTimestamp;
		uint192 nativeFee;
		uint192 linkFee;
		uint32 expiresAt;
		int192 benchmarkPrice;
	}

	/**
	 * @dev Data Streams report schema v3 (crypto streams).
	 *      Prices, bids and asks use 8 or 18 decimals depending on the stream.
	 */
	struct ReportV3 {
		bytes32 feedId;
		uint32 validFromTimestamp;
		uint32 observationsTimestamp;
		uint192 nativeFee;
		uint192 linkFee;
		uint32 expiresAt;
		int192 price;
		int192 bid;
		int192 ask;
	}

	/**
	 * @dev Data Streams report schema v4 (RWA streams).
	 */
	struct ReportV4 {
		bytes32 feedId;
		uint32 validFromTimestamp;
		uint32 observationsTimestamp;
		uint192 nativeFee;
		uint192 linkFee;
		uint32 expiresAt;
		int192 price;
		uint32 marketStatus;
	}

	struct OracleData {
		uint80 roundId;
		int256 answer;
		uint256 startedAt;
		uint256 updatedAt;
		uint80 answeredInRound;
	}

	// ----------------- Storage -----------------
	IVerifierProxy public immutable verifierProxy;
	uint256 public constant version = 100;
	address internal _owner;
	mapping(bytes32 => OracleData) private oracleData;
	mapping(address => bytes32) private feedIdByMiddleware;

	// ----------------- Events -----------------
	event DecodedPrice(bytes32 indexed feedId, int256 price);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

	// ----------------- Constructor / modifier -----------------
	/**
	 * @param _verifierProxy Address of the VerifierProxy on the target network.
	 *        Addresses: https://docs.chain.link/data-streams/crypto-streams
	 */
	constructor(address _verifierProxy) {
		verifierProxy = IVerifierProxy(_verifierProxy);
		_owner = msg.sender;
	}

	/**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view virtual returns (address) {
        return _owner;
    }

    /**
     * @dev Throws if the sender is not the owner.
     */
    function _checkOwner() internal view virtual {
        if (owner() != msg.sender) {
            revert OwnableUnauthorizedAccount(msg.sender);
        }
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Can only be called by the current owner.
     */
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }

    /**
     * @dev Transfers ownership of the contract to a new account (`newOwner`).
     * Internal function without access restriction.
     */
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

	// ----------------- Public API -----------------

	/**
	 * @notice Verify a Data Streams report (schema v3 or v4).
	 *
	 * @dev Steps:
	 *  1. Decode the unverified report to get `reportData`.
	 *  2. Read the first two bytes → schema version (`0x0003` or `0x0004`).
	 *     - Revert if the version is unsupported.
	 *  3. Fee handling:
	 *     - Query `s_feeManager()` on the proxy.
	 *       – Non-zero → quote the fee, approve the RewardManager,
	 *         ABI-encode the fee token address for `verify()`.
	 *       – Zero     → no FeeManager; skip quoting/approval and pass `""`.
	 *  4. Call `VerifierProxy.verify()`.
	 *  5. Decode the verified report into the correct struct and emit the price.
	 *
	 *  @param unverifiedReport Full payload returned by Streams Direct.
	 *  @custom:reverts InvalidReportVersion when schema ≠ v3/v4.
	 */
	function verifyReport(bytes memory unverifiedReport) external {
		// ─── 1. & 2. Extract reportData and schema version ──
		(, bytes memory reportData) = abi.decode(unverifiedReport, (bytes32[3], bytes));

		uint16 reportVersion = (uint16(uint8(reportData[0])) << 8) | uint16(uint8(reportData[1]));
		if (reportVersion != 2 &&reportVersion != 3 && reportVersion != 4) revert InvalidReportVersion(reportVersion);

		// ─── 3. Fee handling ──
		IFeeManager feeManager = IFeeManager(address(verifierProxy.s_feeManager()));

		bytes memory parameterPayload;
		if (address(feeManager) != address(0)) {
			// FeeManager exists — always quote & approve
			address feeToken = feeManager.i_linkAddress();

			(Common.Asset memory fee, , ) = feeManager.getFeeAndReward(address(this), reportData, feeToken);

			IERC20(feeToken).approve(feeManager.i_rewardManager(), fee.amount);
			parameterPayload = abi.encode(feeToken);
		} else {
			// No FeeManager deployed on this chain
			parameterPayload = bytes("");
		}

		// ─── 4. Verify through the proxy ──
		bytes memory verified = verifierProxy.verify(unverifiedReport, parameterPayload);

		// ─── 5. Decode & store price ──
		if (reportVersion == 2) {
			// Schema v2 is not supported by this contract
			ReportV2 memory report = abi.decode(verified, (ReportV2));
			bytes32 feedId = report.feedId;
			OracleData storage data = oracleData[feedId];
			data.roundId = uint80(block.timestamp);
			data.answer = int256(report.benchmarkPrice);
			data.startedAt = report.validFromTimestamp;
			data.updatedAt = report.observationsTimestamp;
			data.answeredInRound = uint80(block.timestamp);

			emit DecodedPrice(feedId, int256(report.benchmarkPrice));
		} else if (reportVersion == 3) {
			ReportV3 memory report = abi.decode(verified, (ReportV3));
			bytes32 feedId = report.feedId;
			OracleData storage data = oracleData[feedId];
			data.roundId = uint80(block.timestamp);
			data.answer = report.price;
			data.startedAt = report.validFromTimestamp;
			data.updatedAt = report.observationsTimestamp;
			data.answeredInRound = uint80(block.timestamp);

			emit DecodedPrice(feedId, report.price);
		} else {
			ReportV4 memory report = abi.decode(verified, (ReportV4));
			bytes32 feedId = report.feedId;
			OracleData storage data = oracleData[feedId];
			data.roundId = uint80(block.timestamp);
			data.answer = report.price;
			data.startedAt = report.validFromTimestamp;
			data.updatedAt = report.observationsTimestamp;
			data.answeredInRound = uint80(block.timestamp);

			emit DecodedPrice(feedId, report.price);
		}
	}

	function description() external pure returns (string memory) {
		return "Chainlink Middleware for Data Streams";
	}

	function setFeedIdByMiddleware(address middleware, bytes32 feedId) external onlyOwner {
		feedIdByMiddleware[middleware] = feedId;
	}

	/**
	 * @notice Get data about a round
	 * @param _roundId the requested round ID
	 * @return roundId is the round ID from the aggregator for which the data was retrieved.
	 * @return answer is the answer for the given round
	 * @return startedAt is the timestamp when the round was started.
	 * @return updatedAt is the timestamp when the round last was updated.
	 * @return answeredInRound is the round ID of the round in which the answer was computed.
	 */
	function getRoundData(
		uint80 _roundId
	)
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		// This function is not implemented in this contract.
		revert NotImplemented();
	}

	function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
		address middleware = msg.sender;
		bytes32 feedId = feedIdByMiddleware[middleware];

		OracleData storage data = oracleData[feedId];
		return (data.roundId, data.answer, data.startedAt, data.updatedAt, data.answeredInRound);
	}

	/**
	 * @notice Withdraw all balance of an ERC-20 token held by this contract.
	 * @param _beneficiary Address that receives the tokens.
	 * @param _token       ERC-20 token address.
	 */
	function withdrawToken(address _beneficiary, address _token) external onlyOwner {
		uint256 amount = IERC20(_token).balanceOf(address(this));
		if (amount == 0) revert NothingToWithdraw();
		IERC20(_token).safeTransfer(_beneficiary, amount);
	}
}
