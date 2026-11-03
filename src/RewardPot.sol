// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IRewardFeeSource} from "./interfaces/IRewardFeeSource.sol";

/// @title Burn points and weekly IMD reward pot
/// @notice Every UNLK2 burned (gate contribution or voluntary burn) earns one non-transferable point
///         (18-decimal precision, never spent, never transferable). The hook's extra 1% IMD reward fee
///         is attributed here at the moment it is earned in a swap, even though the IMD itself stays an
///         ERC-6909 claim in the PoolManager until someone redeems it.
///
///         * Fees earned while no point exists go to a separate pre-point pot. The first point starts a
///           linear seven-day release of that pot; each elapsed slice is split pro rata among the points
///           that existed during that slice (the pot is checkpointed before every point change), so the
///           first burner never receives the whole pot at once.
///         * Fees earned after the first point exists are split immediately among the points present
///           at that moment. Later points only dilute later fees; there are no retroactive rewards and
///           no end-of-week balance snapshot.
///         * Entitlements mature in fixed seven-day epochs counted from the hook's activation. Whatever
///           accrued in a closed epoch is claimable by its beneficiary at any later time; unclaimed
///           rewards never expire.
///
///         Gas is O(1) per action: a global accumulator (IMD per point) plus the accumulator value at
///         the start of the current epoch; no loop over holders or epochs.
///
///         The pot has no owner and no withdrawal other than `claim()`, which pays the caller's own
///         matured entitlement. IMD is never converted. Nothing is promised: rewards depend only on
///         future trading fees.
contract RewardPot {
    using SafeERC20 for IERC20;

    /// @notice Linear release period of the pre-point pot, starting at the first point.
    uint256 public constant RELEASE_DURATION = 7 days;
    /// @notice Maturity epoch length; epoch 0 starts at hook activation.
    uint256 public constant EPOCH_LENGTH = 7 days;
    /// @notice Scale of `accRewardPerPoint`.
    uint256 public constant ACC_PRECISION = 1e36;

    IERC20 public immutable imd;
    /// @notice The UNLOCK V2 hook: the only caller of the bookkeeping entry points and the fee source.
    address public immutable hook;

    // ------------------------------------------------------------------ epochs

    /// @notice Start of epoch 0 (hook activation time); 0 until activation.
    uint256 public epochStart;
    /// @notice Epoch of the latest global checkpoint.
    uint256 public lastCheckpointEpoch;
    /// @notice Accumulator value at the start of each epoch that has been checkpointed.
    mapping(uint256 => uint256) public accAtEpochStart;

    // ------------------------------------------------------------------ points

    uint256 public totalPoints;
    /// @notice Accumulated IMD per point, scaled by ACC_PRECISION. Never decreases.
    uint256 public accRewardPerPoint;

    // ------------------------------------------------------------------ pre-point pot

    /// @notice Fees earned before the first point existed (fixed once the first point exists).
    uint256 public prePointPot;
    /// @notice Timestamp of the first point; starts the pre-point release. 0 while no point exists.
    uint256 public firstPointTime;
    /// @notice Part of `prePointPot` already split among points.
    uint256 public prePointReleased;

    // ------------------------------------------------------------------ solvency counters

    /// @notice Every reward fee attributed to this pot, at the time it was earned in a swap.
    uint256 public totalAccrued;
    /// @notice Part of `totalAccrued` already allocated to points (direct fees plus released pre-point pot).
    uint256 public totalVested;
    /// @notice IMD actually moved from the PoolManager into this contract.
    uint256 public totalRedeemed;
    /// @notice IMD paid out to beneficiaries.
    uint256 public totalPaid;

    struct Account {
        uint256 points;
        /// accumulator value at the last settlement
        uint256 debt;
        /// accrued in closed epochs, claimable now
        uint256 matured;
        /// accrued in `lastEpoch`, which was still open at the last settlement
        uint256 pending;
        uint256 lastEpoch;
        uint256 claimed;
    }

    mapping(address => Account) internal _accounts;

    bool private _locked;

    event Activated(uint256 epochStart);
    event PointsAdded(address indexed account, uint256 amount, uint256 totalPoints);
    event PrePointReleaseStarted(uint256 amount, uint256 start, uint256 end);
    event FeeAccrued(uint256 amount, bool prePoint);
    event Redeemed(uint256 amount);
    event Claimed(address indexed account, uint256 epoch, uint256 amount);

    error NotHook();
    error NotActive();
    error AlreadyActive();
    error NothingToClaim();
    error Reentrancy();
    error RedeemExceedsAccrued();

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @dev Deployed by the hook's constructor.
    constructor(address imd_) {
        imd = IERC20(imd_);
        hook = msg.sender;
    }

    // ------------------------------------------------------------------ hook entry points

    /// @notice Starts epoch 0. Called once by the hook in `activate()`.
    function activate() external onlyHook {
        if (epochStart != 0) revert AlreadyActive();
        _checkpoint();
        epochStart = block.timestamp;
        emit Activated(block.timestamp);
    }

    /// @notice Credits `amount` points (one per burned UNLK2 wei) to `account`. Checkpoints first so
    ///         the new points share only rewards released or earned from now on.
    function addPoints(address account, uint256 amount) external onlyHook {
        if (amount == 0) return;
        _checkpoint();
        _settle(account);
        if (totalPoints == 0) {
            firstPointTime = block.timestamp;
            emit PrePointReleaseStarted(prePointPot, block.timestamp, block.timestamp + RELEASE_DURATION);
        }
        _accounts[account].points += amount;
        totalPoints += amount;
        emit PointsAdded(account, amount, totalPoints);
    }

    /// @notice Attributes a reward fee the hook earned in the current swap. Before the first point it
    ///         joins the pre-point pot; afterwards it is split immediately among the present points.
    function onFeeAccrued(uint256 amount) external onlyHook {
        if (amount == 0) return;
        _checkpoint();
        totalAccrued += amount;
        if (totalPoints == 0) {
            prePointPot += amount;
            emit FeeAccrued(amount, true);
        } else {
            accRewardPerPoint += FullMath.mulDiv(amount, ACC_PRECISION, totalPoints);
            totalVested += amount;
            emit FeeAccrued(amount, false);
        }
    }

    /// @notice Records IMD the hook just transferred here from the PoolManager.
    function onRedeemed(uint256 amount) external onlyHook {
        totalRedeemed += amount;
        if (totalRedeemed > totalAccrued) revert RedeemExceedsAccrued();
        emit Redeemed(amount);
    }

    // ------------------------------------------------------------------ public

    /// @notice Releases the elapsed part of the pre-point pot and records the epoch boundary. Anyone may call.
    function checkpoint() external {
        _checkpoint();
    }

    /// @notice Pays the caller's matured (closed-epoch) entitlement in IMD. If the pot does not yet hold
    ///         enough redeemed IMD it first redeems the hook's pending claims (permissionless redemption).
    function claim() external nonReentrant returns (uint256 amount) {
        if (epochStart == 0) revert NotActive();
        _checkpoint();
        _settle(msg.sender);
        Account storage a = _accounts[msg.sender];
        amount = a.matured;
        if (amount == 0) revert NothingToClaim();
        a.matured = 0;
        a.claimed += amount;
        totalPaid += amount;
        if (imd.balanceOf(address(this)) < amount && IRewardFeeSource(hook).pendingFees() != 0) {
            IRewardFeeSource(hook).redeemFees();
        }
        imd.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, currentEpoch(), amount);
    }

    // ------------------------------------------------------------------ views

    function isActive() external view returns (bool) {
        return epochStart != 0;
    }

    /// @notice Current epoch (0 before activation).
    function currentEpoch() public view returns (uint256) {
        if (epochStart == 0) return 0;
        return (block.timestamp - epochStart) / EPOCH_LENGTH;
    }

    /// @notice Start timestamp of epoch `epoch` (0 before activation).
    function epochStartTime(uint256 epoch) external view returns (uint256) {
        if (epochStart == 0) return 0;
        return epochStart + epoch * EPOCH_LENGTH;
    }

    function points(address account) external view returns (uint256) {
        return _accounts[account].points;
    }

    /// @notice Total of the pre-point pot released by `timestamp` (linear over RELEASE_DURATION).
    function prePointReleasedAt(uint256 timestamp) public view returns (uint256) {
        uint256 start = firstPointTime;
        if (start == 0 || timestamp <= start) return 0;
        uint256 elapsed = timestamp - start;
        if (elapsed >= RELEASE_DURATION) return prePointPot;
        return prePointPot * elapsed / RELEASE_DURATION;
    }

    /// @notice (claimable now, accrued in the still-open epoch and claimable once it closes).
    function rewardsOf(address account) public view returns (uint256 claimableNow, uint256 maturing) {
        (uint256 accNow, uint256 accB, uint256 epoch) = _virtualAcc();
        Account memory a = _accounts[account];
        if (a.lastEpoch < epoch) {
            claimableNow = a.matured + a.pending + FullMath.mulDiv(a.points, accB - a.debt, ACC_PRECISION);
            maturing = FullMath.mulDiv(a.points, accNow - accB, ACC_PRECISION);
        } else {
            claimableNow = a.matured;
            maturing = a.pending + FullMath.mulDiv(a.points, accNow - a.debt, ACC_PRECISION);
        }
        if (epochStart == 0) {
            maturing += claimableNow;
            claimableNow = 0;
        }
    }

    /// @notice IMD `account` could claim right now.
    function claimable(address account) external view returns (uint256 amount) {
        (amount,) = rewardsOf(account);
    }

    function accountOf(address account) external view returns (Account memory) {
        return _accounts[account];
    }

    /// @notice Bookkeeping split. Liabilities (`accrued - paid`) are always covered by the IMD held here
    ///         plus the hook's not yet redeemed claims, because every fee is attributed only when the hook
    ///         receives its claim and leaves only through `claim()`.
    function solvency()
        external
        view
        returns (
            uint256 accrued,
            uint256 vested,
            uint256 redeemed,
            uint256 paid,
            uint256 unredeemed,
            uint256 held,
            uint256 prePointUnreleased
        )
    {
        accrued = totalAccrued;
        vested = totalVested + (prePointReleasedAt(block.timestamp) - prePointReleased);
        redeemed = totalRedeemed;
        paid = totalPaid;
        unredeemed = IRewardFeeSource(hook).pendingFees();
        held = imd.balanceOf(address(this));
        prePointUnreleased = prePointPot - prePointReleasedAt(block.timestamp);
    }

    /// @notice True when held IMD plus unredeemed claims cover every unpaid attributed fee.
    function isSolvent() external view returns (bool) {
        return imd.balanceOf(address(this)) + IRewardFeeSource(hook).pendingFees() >= totalAccrued - totalPaid;
    }

    // ------------------------------------------------------------------ internals

    function _checkpoint() internal {
        uint256 epoch = currentEpoch();
        if (epoch > lastCheckpointEpoch) {
            _release(epochStart + epoch * EPOCH_LENGTH);
            accAtEpochStart[epoch] = accRewardPerPoint;
            lastCheckpointEpoch = epoch;
        }
        _release(block.timestamp);
    }

    /// @dev Splits the pre-point pot released up to `until` among the current points.
    function _release(uint256 until) internal {
        if (totalPoints == 0) return;
        uint256 target = prePointReleasedAt(until);
        uint256 released = prePointReleased;
        if (target <= released) return;
        uint256 amount = target - released;
        prePointReleased = target;
        accRewardPerPoint += FullMath.mulDiv(amount, ACC_PRECISION, totalPoints);
        totalVested += amount;
    }

    /// @dev Must run right after `_checkpoint()`.
    function _settle(address account) internal {
        Account storage a = _accounts[account];
        uint256 epoch = lastCheckpointEpoch;
        uint256 acc = accRewardPerPoint;
        uint256 p = a.points;
        if (a.lastEpoch < epoch) {
            uint256 accB = accAtEpochStart[epoch];
            a.matured += a.pending + FullMath.mulDiv(p, accB - a.debt, ACC_PRECISION);
            a.pending = FullMath.mulDiv(p, acc - accB, ACC_PRECISION);
            a.lastEpoch = epoch;
        } else {
            a.pending += FullMath.mulDiv(p, acc - a.debt, ACC_PRECISION);
        }
        a.debt = acc;
    }

    /// @dev Accumulator now and at the start of the current epoch, as `_checkpoint()` would compute them.
    function _virtualAcc() internal view returns (uint256 accNow, uint256 accB, uint256 epoch) {
        epoch = currentEpoch();
        accNow = accRewardPerPoint;
        uint256 released = prePointReleased;
        uint256 tp = totalPoints;
        if (epoch > lastCheckpointEpoch) {
            uint256 target = prePointReleasedAt(epochStart + epoch * EPOCH_LENGTH);
            if (tp != 0 && target > released) {
                accNow += FullMath.mulDiv(target - released, ACC_PRECISION, tp);
                released = target;
            }
            accB = accNow;
        } else {
            accB = accAtEpochStart[epoch];
        }
        uint256 targetNow = prePointReleasedAt(block.timestamp);
        if (tp != 0 && targetNow > released) {
            accNow += FullMath.mulDiv(targetNow - released, ACC_PRECISION, tp);
        }
    }
}
