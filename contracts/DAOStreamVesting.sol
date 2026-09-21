// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DAOStreamVesting
/// @notice Standalone linear token vesting with cliff and optional revocation.
/// @dev No roles and no governance coupling: each schedule's trust boundary is just
///      funder <-> beneficiary. The funder (`msg.sender` at creation) pulls tokens in
///      via allowance, optionally retains revocation rights over the UNVESTED portion,
///      and vested-but-unclaimed tokens always remain claimable by the beneficiary —
///      revocation can never claw back what has vested. A DAO funds a schedule either
///      directly from a multisig or through a treasury package batch
///      (approve-then-create, see docs/INTEGRATION.md).
contract DAOStreamVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Schedule {
        address beneficiary;
        IERC20 token;
        uint256 totalAmount;
        uint256 released;
        uint48 start;
        uint48 cliff;
        uint48 duration;
        bool revocable;
        bool revoked;
        address revoker;
    }

    uint256 public nextScheduleId = 1;
    mapping(uint256 scheduleId => Schedule schedule) private _schedules;

    event VestingCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        address indexed token,
        uint256 totalAmount,
        uint48 start,
        uint48 cliff,
        uint48 duration,
        bool revocable
    );
    event VestedClaimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event VestingRevoked(uint256 indexed scheduleId, uint256 unvestedReturned);

    error InvalidBeneficiary();
    error InvalidZeroAmount();
    error InvalidTimeRange(uint48 start, uint48 cliff, uint48 duration);
    error ScheduleNotFound(uint256 scheduleId);
    error NothingToClaim(uint256 scheduleId);
    error NotRevocable(uint256 scheduleId);
    error AlreadyRevoked(uint256 scheduleId);
    error CallerNotRevoker(uint256 scheduleId, address caller);

    /// @notice Create a schedule, pulling `totalAmount` from the caller via allowance.
    /// @dev Requires `start <= cliff`, `duration > 0`, and timestamps that fit `uint48`
    ///      (reverts otherwise instead of silently truncating). The schedule records the
    ///      tokens ACTUALLY RECEIVED (balance delta), so fee-on-transfer tokens vest
    ///      exactly what arrived instead of stranding phantom allocations.
    function create(
        address beneficiary,
        IERC20 token,
        uint256 totalAmount,
        uint48 start,
        uint48 cliff,
        uint48 duration,
        bool revocable
    ) external nonReentrant returns (uint256 scheduleId) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (totalAmount == 0) revert InvalidZeroAmount();
        if (duration == 0 || cliff < start || uint256(duration) + start > type(uint48).max) {
            revert InvalidTimeRange(start, cliff, duration);
        }

        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), totalAmount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received == 0) revert InvalidZeroAmount();

        scheduleId = nextScheduleId++;
        _schedules[scheduleId] = Schedule({
            beneficiary: beneficiary,
            token: token,
            totalAmount: received,
            released: 0,
            start: start,
            cliff: cliff,
            duration: duration,
            revocable: revocable,
            revoked: false,
            revoker: msg.sender
        });

        emit VestingCreated(scheduleId, beneficiary, address(token), received, start, cliff, duration, revocable);
    }

    /// @notice Release all currently vested tokens to the beneficiary. Permissionless.
    function claim(uint256 scheduleId) external nonReentrant {
        Schedule storage s = _schedule(scheduleId);
        uint256 target = _vested(s, uint48(block.timestamp));
        if (target <= s.released) revert NothingToClaim(scheduleId);
        uint256 amount = target - s.released;
        s.released += amount;
        s.token.safeTransfer(s.beneficiary, amount);
        emit VestedClaimed(scheduleId, s.beneficiary, amount);
    }

    /// @notice Revoke a revocable schedule: vested stays claimable, unvested returns.
    /// @dev Only the original funder. Revocation freezes vesting at the current
    ///      timestamp: `totalAmount` is reduced to the vested amount AND `revoked`
    ///      is set, which makes `_vested` return that frozen amount unconditionally.
    ///      Both halves are required — reducing `totalAmount` alone left
    ///      `start`/`duration` in place, so `_vested` re-applied the elapsed-time
    ///      fraction to an already-fractional amount and the curve re-vested after
    ///      revocation (AUDIT: vesting-revoke-double-fraction).
    function revoke(uint256 scheduleId) external nonReentrant {
        Schedule storage s = _schedule(scheduleId);
        if (!s.revocable) revert NotRevocable(scheduleId);
        if (s.revoked) revert AlreadyRevoked(scheduleId);
        if (msg.sender != s.revoker) revert CallerNotRevoker(scheduleId, msg.sender);

        uint256 vestedAmount = _vested(s, uint48(block.timestamp));
        uint256 unvested = s.totalAmount - vestedAmount;
        s.revoked = true;
        s.totalAmount = vestedAmount; // freeze: nothing more can ever vest
        if (unvested > 0) s.token.safeTransfer(s.revoker, unvested);
        emit VestingRevoked(scheduleId, unvested);
    }

    /// @notice Total vested to date (capped at the schedule total, frozen on revoke).
    function vested(uint256 scheduleId) external view returns (uint256) {
        return _vested(_schedule(scheduleId), uint48(block.timestamp));
    }

    /// @notice Currently claimable by the beneficiary (vested minus already released).
    function claimable(uint256 scheduleId) external view returns (uint256) {
        Schedule storage s = _schedule(scheduleId);
        return _vested(s, uint48(block.timestamp)) - s.released;
    }

    function getSchedule(uint256 scheduleId) external view returns (Schedule memory) {
        Schedule memory s = _schedules[scheduleId];
        if (s.beneficiary == address(0)) revert ScheduleNotFound(scheduleId);
        return s;
    }

    function scheduleExists(uint256 scheduleId) external view returns (bool) {
        return _schedules[scheduleId].beneficiary != address(0);
    }

    function _schedule(uint256 scheduleId) private view returns (Schedule storage s) {
        s = _schedules[scheduleId];
        if (s.beneficiary == address(0)) revert ScheduleNotFound(scheduleId);
    }

    /// @dev Linear release between `start` and `start + duration`, gated on `cliff`.
    ///      Before the cliff nothing is vested; at/after the end everything is.
    ///      A revoked schedule is frozen: it always reports its (already reduced)
    ///      `totalAmount`, regardless of `at`. Without this branch the elapsed-time
    ///      fraction would be applied a second time to the frozen amount.
    function _vested(Schedule storage s, uint48 at) private view returns (uint256) {
        if (s.revoked) return s.totalAmount;
        if (at < s.cliff) return 0;
        if (at >= s.start + s.duration) return s.totalAmount;
        return (s.totalAmount * (at - s.start)) / s.duration;
    }
}
