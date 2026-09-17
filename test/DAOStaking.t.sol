// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DAOStaking} from "../contracts/DAOStaking.sol";

contract StakeMint is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Staking tests: stake/withdraw accounting, epoch accrual and payout, rollover,
///      owner limits (rates/duration/rescue — never user stakes), and reward solvency.
contract DAOStakingTest is Test {
    StakeMint internal stakingToken;
    StakeMint internal rewardsToken;
    DAOStaking internal staking;

    address internal owner = makeAddr("owner"); // stands in for the timelock
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant DURATION = 30 days;

    function setUp() public {
        stakingToken = new StakeMint("Stake", "STK");
        rewardsToken = new StakeMint("Reward", "RWD");
        staking = new DAOStaking(IERC20(address(stakingToken)), IERC20(address(rewardsToken)), owner, DURATION);
        stakingToken.mint(alice, 10_000e18);
        stakingToken.mint(bob, 10_000e18);
        vm.prank(alice);
        stakingToken.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        stakingToken.approve(address(staking), type(uint256).max);
    }

    function _fundEpoch(uint256 amount) internal {
        rewardsToken.mint(address(staking), amount);
        vm.prank(owner);
        staking.notifyRewardAmount(amount);
    }

    function test_Stake_UpdatesBalancesAndEmits() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit DAOStaking.Staked(alice, 1_000e18);
        vm.prank(alice);
        staking.stake(1_000e18);
        assertEq(staking.balanceOf(alice), 1_000e18);
        assertEq(staking.totalSupply(), 1_000e18);
    }

    function test_Stake_RevertsWhen_Zero() public {
        vm.prank(alice);
        vm.expectRevert(DAOStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.prank(alice);
        vm.expectRevert(DAOStaking.ZeroAmount.selector);
        staking.withdraw(0);
    }

    function test_Rewards_AccrueAndPay() public {
        vm.prank(alice);
        staking.stake(1_000e18);
        _fundEpoch(3_000e18); // 100e18/day over 30 days

        vm.warp(block.timestamp + 15 days);
        assertApproxEqAbs(staking.earned(alice), 1_500e18, 1e12, "half epoch ~= half rewards");

        vm.warp(block.timestamp + 15 days + 1);
        uint256 due = staking.earned(alice);
        assertApproxEqAbs(due, 3_000e18, 1e12, "full epoch ~= full rewards (dust from rate rounding)");
        vm.prank(alice);
        vm.expectEmit(true, false, false, true, address(staking));
        emit DAOStaking.RewardPaid(alice, due);
        staking.getReward();
        assertEq(rewardsToken.balanceOf(alice), due);
        assertEq(staking.earned(alice), 0);
    }

    function test_Exit_WithdrawsAndClaims() public {
        vm.prank(alice);
        staking.stake(1_000e18);
        _fundEpoch(3_000e18);
        vm.warp(block.timestamp + DURATION + 1);
        uint256 due = staking.earned(alice);
        vm.prank(alice);
        staking.exit();
        assertEq(stakingToken.balanceOf(alice), 10_000e18, "principal back in full");
        assertApproxEqAbs(rewardsToken.balanceOf(alice), 3_000e18, 1e12, "rewards paid in full (dust)");
        assertEq(staking.totalSupply(), 0);
        assertEq(due, rewardsToken.balanceOf(alice));
    }

    function test_Rewards_SplitProportionally() public {
        vm.prank(alice);
        staking.stake(3_000e18);
        vm.prank(bob);
        staking.stake(1_000e18);
        _fundEpoch(4_000e18);
        vm.warp(block.timestamp + DURATION + 1);
        assertApproxEqAbs(staking.earned(alice), 3_000e18, 1e12);
        assertApproxEqAbs(staking.earned(bob), 1_000e18, 1e12);
    }

    function test_NotifyReward_RollsOverLeftover() public {
        vm.prank(alice);
        staking.stake(1_000e18);
        _fundEpoch(3_000e18);
        vm.warp(block.timestamp + 15 days); // ~1,500 unspent

        rewardsToken.mint(address(staking), 3_000e18);
        // NOTE: read expectations BEFORE prank — even view calls consume it.
        uint256 oldRate = staking.rewardRate();
        uint256 remaining = staking.periodFinish() - block.timestamp;
        uint256 expectedRate = (3_000e18 + remaining * oldRate) / DURATION;
        uint256 expectedFinish = block.timestamp + DURATION;
        vm.expectEmit(true, false, false, false, address(staking));
        emit DAOStaking.RewardAdded(3_000e18, expectedRate, expectedFinish);
        vm.prank(owner);
        staking.notifyRewardAmount(3_000e18);

        // New epoch covers fresh 3,000 + ~1,500 leftover over a full duration.
        assertEq(staking.rewardRate(), expectedRate);
        assertApproxEqAbs(staking.rewardRate(), 4_500e18 / DURATION, 1e6);
    }

    function test_NotifyReward_OnlyOwner() public {
        rewardsToken.mint(address(staking), 1_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.notifyRewardAmount(1_000e18);
    }

    function test_NotifyReward_RevertsWhen_Undercollateralized() public {
        uint256 required = 1_000e18;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DAOStaking.InsufficientRewardBudget.selector, 0, required));
        staking.notifyRewardAmount(1_000e18); // nothing funded
    }

    function test_SetDuration_OnlyBetweenEpochs() public {
        _fundEpoch(3_000e18);
        vm.prank(owner);
        vm.expectRevert(DAOStaking.PeriodActive.selector);
        staking.setRewardsDuration(7 days);

        vm.warp(block.timestamp + DURATION + 1);
        vm.prank(owner);
        staking.setRewardsDuration(7 days);
        assertEq(staking.rewardsDuration(), 7 days);
    }

    function test_Recover_RescuesOnlyNonStaked() public {
        StakeMint stray = new StakeMint("Stray", "STR");
        stray.mint(address(staking), 100e18);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(staking));
        emit DAOStaking.Recovered(address(stray), 100e18);
        staking.recoverERC20(address(stray), 100e18);
        assertEq(stray.balanceOf(owner), 100e18);

        vm.prank(alice);
        staking.stake(1_000e18);
        vm.prank(owner);
        vm.expectRevert(DAOStaking.CannotRecoverStakingToken.selector);
        staking.recoverERC20(address(stakingToken), 1_000e18);
        // Owner has no path to user stakes: balances untouched by every owner op.
        assertEq(staking.balanceOf(alice), 1_000e18);
        assertEq(staking.totalSupply(), 1_000e18);
    }

    function test_RecoverRewardToken_OnlySurplusAboveBudget() public {
        vm.prank(alice);
        staking.stake(1_000e18);
        _fundEpoch(1_000e18);
        vm.warp(block.timestamp + DURATION);
        uint256 due = staking.earned(alice);

        rewardsToken.mint(address(staking), 5e18);
        vm.prank(owner);
        staking.recoverERC20(address(rewardsToken), 5e18);
        assertEq(rewardsToken.balanceOf(owner), 5e18);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DAOStaking.RescueExceedsWithdrawable.selector, 0, 1));
        staking.recoverERC20(address(rewardsToken), 1);
        assertEq(staking.rewardBudget(), 1_000e18);

        vm.prank(alice);
        staking.getReward();
        assertEq(rewardsToken.balanceOf(alice), due);
        assertEq(staking.rewardBudget(), 1_000e18 - due);
    }

    function test_NoStakers_NoBackpay() public {
        _fundEpoch(3_000e18);
        vm.warp(block.timestamp + 15 days);
        vm.prank(alice);
        staking.stake(1_000e18);
        assertEq(staking.earned(alice), 0, "late stakers earn only from here on");
    }

    function testFuzz_Earned_NeverExceedsFunded(uint256 stakeAmt, uint256 rewardAmt, uint256 warpTo) public {
        stakeAmt = bound(stakeAmt, 1e18, 10_000e18);
        rewardAmt = bound(rewardAmt, 1e18, 100_000e18);
        vm.prank(alice);
        staking.stake(stakeAmt);
        rewardsToken.mint(address(staking), rewardAmt);
        vm.prank(owner);
        staking.notifyRewardAmount(rewardAmt);
        warpTo = bound(warpTo, block.timestamp, block.timestamp + 2 * DURATION);
        vm.warp(warpTo);
        assertLe(staking.earned(alice), rewardAmt, "protocol can never owe more than funded");
    }

    function testFuzz_StakeWithdraw_Symmetry(uint256 a, uint256 b) public {
        a = bound(a, 1, 5_000e18);
        b = bound(b, 1, a); // withdraw(0) reverts by design; fuzz non-trivial paths
        vm.prank(alice);
        staking.stake(a);
        vm.prank(alice);
        staking.withdraw(b);
        assertEq(staking.balanceOf(alice), a - b);
        assertEq(stakingToken.balanceOf(alice), 10_000e18 - (a - b));
    }
}
