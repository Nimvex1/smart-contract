// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAOStaking} from "../../contracts/DAOStaking.sol";

contract Mintable is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Audit PoCs for DAOStaking. Deterministic, emitted numbers.
contract AuditPoCStaking is Test {
    Mintable internal stakeTok;
    Mintable internal rewardTok;
    DAOStaking internal staking;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DURATION = 30 days;

    function setUp() public {
        stakeTok = new Mintable("Stake", "STK");
        rewardTok = new Mintable("Reward", "RWD");
        staking = new DAOStaking(IERC20(address(stakeTok)), IERC20(address(rewardTok)), owner, DURATION);
    }

    // ==================================================================
    // A. Reward-rate truncation under-funds the epoch; last claimers lose
    // ==================================================================

    /// @dev notifyRewardAmount computes rewardRate = reward / rewardsDuration (floor).
    ///      The epoch therefore pays rewardRate * rewardsDuration <= reward.
    ///      The deficit (reward mod duration) is NOT carried forward: _rewardBudget
    ///      is credited with the full `reward`, and `rewardPerToken` never accrues
    ///      the shortfall. Every staker is short-changed and the difference is
    ///      permanently stranded in the contract, unreachable by recoverERC20
    ///      (that path is capped ABOVE _rewardBudget).
    function test_A_rewardRateTruncation_ShortsEveryStaker() public {
        stakeTok.mint(alice, 1_000e18);
        vm.prank(alice);
        stakeTok.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(1_000e18);

        // Pick a reward that does not divide evenly by DURATION (30 days == 2_592_000).
        uint256 reward = DURATION + 1; // 1 wei of truncation
        rewardTok.mint(address(staking), reward);
        vm.prank(owner);
        staking.notifyRewardAmount(reward);

        emit log_named_uint("funded reward     ", reward);
        emit log_named_uint("rewardRate        ", staking.rewardRate());
        uint256 maxPayout = staking.rewardRate() * DURATION;
        emit log_named_uint("max epoch payout  ", maxPayout);
        emit log_named_uint("stranded shortfall", reward - maxPayout);
        assertLt(maxPayout, reward, "truncation always short-changes the epoch");

        vm.warp(block.timestamp + DURATION + 1);
        uint256 earnedAmt = staking.earned(alice);
        emit log_named_uint("alice earned      ", earnedAmt);
        assertEq(earnedAmt, maxPayout, "stakers only ever receive rewardRate*duration");

        vm.prank(alice);
        staking.getReward();
        emit log_named_uint("alice balance     ", rewardTok.balanceOf(alice));
        emit log_named_uint("contract residual ", rewardTok.balanceOf(address(staking)));
        emit log_named_uint("rewardBudget left ", staking.rewardBudget());

        // The residual is not rescuable: available = balance - _rewardBudget = 0.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DAOStaking.RescueExceedsWithdrawable.selector, 0, reward - maxPayout));
        staking.recoverERC20(address(rewardTok), reward - maxPayout);
    }

    /// @dev Quantified at a realistic magnitude: 1-day epoch, reward funded to the wei.
    function test_A2_truncation_quantified() public {
        vm.prank(owner);
        staking.setRewardsDuration(1 days);
        uint256 duration = 1 days; // 86_400

        stakeTok.mint(alice, 1_000e18);
        vm.prank(alice);
        stakeTok.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(1_000e18);

        uint256 reward = 1_000_000e18 + (duration - 1);
        rewardTok.mint(address(staking), reward);
        vm.prank(owner);
        staking.notifyRewardAmount(reward);

        uint256 maxPayout = staking.rewardRate() * duration;
        emit log_named_uint("reward funded", reward);
        emit log_named_uint("max payout   ", maxPayout);
        emit log_named_uint("stranded     ", reward - maxPayout);
        assertLt(maxPayout, reward);
    }

    // ==================================================================
    // B. notifyRewardAmount double-counts rollover against the budget
    // ==================================================================

    /// @dev KILLED CANDIDATE (kept as a regression guard). Hypothesis was that
    ///      `notifyRewardAmount` double-counts the live-epoch leftover against
    ///      `_rewardBudget`, over-promising. Measurement disproves it: the rate is
    ///      floored (`(reward + leftover) / duration`), so the epoch promises
    ///      slightly LESS than the funded amount, never more. The ledger delta is
    ///      exactly the new funding. This is sound.
    function test_B_rolloverDoesNotOverPromise() public {
        stakeTok.mint(alice, 1_000e18);
        vm.prank(alice);
        stakeTok.approve(address(staking), type(uint256).max);
        vm.prank(alice);
        staking.stake(1_000e18);

        uint256 r = 3_000e18;
        rewardTok.mint(address(staking), r);
        vm.prank(owner);
        staking.notifyRewardAmount(r);

        vm.warp(block.timestamp + 15 days);

        uint256 oldRate = staking.rewardRate();
        uint256 remaining = staking.periodFinish() - block.timestamp;
        uint256 leftover = remaining * oldRate;
        uint256 accrued = staking.earned(alice);

        rewardTok.mint(address(staking), r);
        vm.prank(owner);
        staking.notifyRewardAmount(r);

        emit log_named_uint("leftover folded in", leftover);
        emit log_named_uint("budget delta      ", staking.rewardBudget() - r);
        emit log_named_uint("accrued + promised", accrued + staking.rewardRate() * DURATION);
        emit log_named_uint("total funded      ", 2 * r);

        assertEq(staking.rewardBudget() - r, r, "ledger grows by exactly the new funding");
        assertLe(
            accrued + staking.rewardRate() * DURATION, 2 * r, "epoch never promises more than the total funded amount"
        );
        emit log_string("KILLED: rollover accounting is conservative, not over-promising");
    }

    // ==================================================================
    // C. Same-token recovery: reward surplus can never be recovered
    // ==================================================================

    /// @dev Config where stakingToken == rewardsToken. `recoverERC20` first hits the
    ///      `CannotRecoverStakingToken` guard, so *no* surplus is recoverable even
    ///      when the contract holds far more than stakes + budget. Combined with A,
    ///      stranded dust accumulates with no exit path.
    function test_C_sameTokenResidualIsUnrecoverable() public {
        Mintable t = new Mintable("Both", "BTH");
        DAOStaking s = new DAOStaking(IERC20(address(t)), IERC20(address(t)), owner, DURATION);

        t.mint(alice, 1_000e18);
        vm.prank(alice);
        t.approve(address(s), type(uint256).max);
        vm.prank(alice);
        s.stake(1_000e18);

        uint256 reward = DURATION + 999;
        t.mint(address(s), reward);
        vm.prank(owner);
        s.notifyRewardAmount(reward);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(alice);
        s.getReward();
        emit log_named_uint("staker balance ", t.balanceOf(alice));
        emit log_named_uint("contract holds ", t.balanceOf(address(s)));
        emit log_named_uint("budget left    ", s.rewardBudget());

        // There is a real surplus (reward - paid), yet recovery is impossible.
        vm.prank(owner);
        vm.expectRevert(DAOStaking.CannotRecoverStakingToken.selector);
        s.recoverERC20(address(t), 1);
    }
}
