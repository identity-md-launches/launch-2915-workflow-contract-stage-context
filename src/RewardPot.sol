// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Burn points and weekly IMD reward pot
/// @notice Burners earn non-transferable points (1 point per UNLK2 burned, 18 decimals). The extra 1%
///         IMD swap fee the hook collects is redeemed into this pot and streamed linearly over seven
///         days into the point pot. Streamed IMD accrues to point holders pro rata; each beneficiary
///         claims their own accrued IMD at most once per weekly epoch. No owner, no withdrawal.
contract RewardPot {
    using SafeERC20 for IERC20;

    uint256 public constant STREAM_DURATION = 7 days;
    uint256 public constant EPOCH_LENGTH = 7 days;
    uint256 private constant ACC_PRECISION = 1e18;

    IERC20 public immutable imd;
    address public immutable hook;
    /// @notice Epoch 0 starts at deployment.
    uint256 public immutable startTime;

    uint256 public totalPoints;
    mapping(address => uint256) public points;
    mapping(address => uint256) private _rewardDebt;
    mapping(address => uint256) private _owed;
    /// @dev epoch + 1 of the last claim (0 = never claimed).
    mapping(address => uint256) private _lastClaimEpochPlusOne;

    /// @notice Accumulated IMD per point, scaled by 1e18.
    uint256 public accRewardPerPoint;
    /// @notice IMD streamed while nobody held points; distributed with the next checkpoint that has points.
    uint256 public undistributed;

    uint256 public streamStart;
    uint256 public streamEnd;
    uint256 public streamTotal;
    uint256 public streamReleased;

    event PointsAdded(address indexed account, uint256 amount);
    event Deposited(uint256 amount, uint256 newStreamTotal, uint256 streamEnd);
    event Claimed(address indexed account, uint256 epoch, uint256 amount);

    error NotHook();
    error NothingToClaim();
    error AlreadyClaimedThisEpoch(uint256 epoch);

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(address imd_) {
        imd = IERC20(imd_);
        hook = msg.sender;
        startTime = block.timestamp;
    }

    // ------------------------------------------------------------------ hook entry points

    /// @notice Credit burn points to `account`.
    function addPoints(address account, uint256 amount) external onlyHook {
        checkpoint();
        _settle(account);
        points[account] += amount;
        totalPoints += amount;
        _rewardDebt[account] = points[account] * accRewardPerPoint / ACC_PRECISION;
        emit PointsAdded(account, amount);
        // IMD streamed while nobody held points goes to the holders present now (the first burners).
        if (undistributed != 0) checkpoint();
    }

    /// @notice Called by the hook after it transferred `amount` IMD here. Merges the unreleased
    ///         remainder of the current stream with the new amount into a fresh seven-day stream.
    function notifyDeposit(uint256 amount) external onlyHook {
        checkpoint();
        uint256 remaining = streamTotal - streamReleased;
        streamTotal = remaining + amount;
        streamReleased = 0;
        streamStart = block.timestamp;
        streamEnd = block.timestamp + STREAM_DURATION;
        emit Deposited(amount, streamTotal, streamEnd);
    }

    // ------------------------------------------------------------------ public

    /// @notice IMD released by the stream since the last checkpoint.
    function pendingStream() public view returns (uint256) {
        if (streamTotal == 0 || streamEnd == streamStart) return 0;
        uint256 until = block.timestamp < streamEnd ? block.timestamp : streamEnd;
        uint256 released = streamTotal * (until - streamStart) / (streamEnd - streamStart);
        return released - streamReleased;
    }

    /// @notice Moves streamed IMD into the point pot. Anyone may call.
    function checkpoint() public {
        uint256 newly = pendingStream();
        if (newly != 0) streamReleased += newly;
        uint256 toDistribute = newly + undistributed;
        if (toDistribute == 0) return;
        if (totalPoints == 0) {
            undistributed = toDistribute;
            return;
        }
        accRewardPerPoint += toDistribute * ACC_PRECISION / totalPoints;
        undistributed = 0;
    }

    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - startTime) / EPOCH_LENGTH;
    }

    function lastClaimEpoch(address account) external view returns (bool claimed, uint256 epoch) {
        uint256 v = _lastClaimEpochPlusOne[account];
        return (v != 0, v == 0 ? 0 : v - 1);
    }

    /// @notice IMD `account` could claim right now (includes stream not yet checkpointed).
    function claimable(address account) external view returns (uint256) {
        uint256 acc = accRewardPerPoint;
        if (totalPoints != 0) {
            uint256 newly = pendingStream();
            if (newly != 0 || undistributed != 0) acc += (newly + undistributed) * ACC_PRECISION / totalPoints;
        }
        return _owed[account] + points[account] * acc / ACC_PRECISION - _rewardDebt[account];
    }

    /// @notice Claim the caller's accrued IMD. Once per weekly epoch per beneficiary.
    function claim() external returns (uint256 amount) {
        uint256 epoch = currentEpoch();
        if (_lastClaimEpochPlusOne[msg.sender] == epoch + 1) revert AlreadyClaimedThisEpoch(epoch);
        checkpoint();
        _settle(msg.sender);
        amount = _owed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _owed[msg.sender] = 0;
        _lastClaimEpochPlusOne[msg.sender] = epoch + 1;
        imd.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, epoch, amount);
    }

    function _settle(address account) internal {
        uint256 accrued = points[account] * accRewardPerPoint / ACC_PRECISION;
        _owed[account] += accrued - _rewardDebt[account];
        _rewardDebt[account] = accrued;
    }
}
