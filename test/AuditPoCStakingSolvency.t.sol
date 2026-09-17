// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAOStaking} from "../contracts/DAOStaking.sol";

contract Mintable is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Regression test for the staking-solvency audit finding: with
///      stakingToken == rewardsToken (the natural config for a fixed-supply
///      governance token), the old balance-derived collateralization check
///      counted user stakes as reward collateral, so an unfunded epoch could
///      pay "rewards" out of pooled principal (first claimants drained later
///      stakers). The explicit `_rewardBudget` ledger now backs every epoch;
///      this test pins both the reverted underfunded epoch AND the fully
///      solvent same-token happy path.
contract AuditPoCStakingSolvency is Test {
    Mintable internal token; // same token for staking AND rewards
    DAOStaking internal staking;

    address internal owner = makeAddr("owner"); // stands in for the timelock
    address internal alice = makeAddr("alice"); // honest staker
    address internal bob = makeAddr("bob"); // opportunistic first claimant

    uint256 internal constant DURATION = 30 days;

    function setUp() public {
        token = new Mintable("Gov", "GOV");
        staking = new DAOStaking(IERC20(address(token)), IERC20(address(token)), owner, DURATION);
        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        token.mint(bob, 1_000e18);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
    }

    /// @dev The exploit: fund an epoch with ZERO reward tokens. Staked
    ///      principal must NOT count as collateral — the call now reverts and
    ///      no phantom rewards can accrue or drain principal.
    function test_exploit_undercollateralizedEpochDrainsPrincipal() public {
        vm.prank(alice);
        staking.stake(1_000e18);
        vm.prank(bob);
        staking.stake(1_000e18);

        uint256 required = 1_000e18;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DAOStaking.InsufficientRewardBudget.selector, 0, required));
        staking.notifyRewardAmount(1_000e18); // reverts: no reward tokens funded

        // No epoch is live, so nothing has accrued for anyone.
        assertEq(staking.rewardBudget(), 0);
        vm.warp(block.timestamp + DURATION + 1);
        assertEq(staking.earned(bob), 0, "no phantom rewards accrued");

        // Both stakers withdraw principal in full — nothing was drained.
        vm.prank(bob);
        staking.withdraw(1_000e18);
        vm.prank(alice);
        staking.withdraw(1_000e18);
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(address(staking)), 0);
    }

    /// @dev Happy path on the same-token config: a genuinely funded epoch pays
    ///      out of the reward budget, principal is never touched, and the
    ///      budget ledger tracks exactly what remains.
    function test_sameTokenFundedEpoch_StaysSolvent() public {
        vm.prank(alice);
        staking.stake(1_000e18);
        vm.prank(bob);
        staking.stake(1_000e18);

        // Real funding: the reward transfer MUST precede notifyRewardAmount.
        token.mint(address(staking), 1_000e18);
        vm.prank(owner);
        staking.notifyRewardAmount(1_000e18);
        assertEq(staking.rewardBudget(), 1_000e18, "budget credited on funding");

        vm.warp(block.timestamp + DURATION + 1);
        assertApproxEqAbs(staking.earned(bob), 500e18, 1e12, "half epoch for half the pool");

        // Bob claims and exits: reward paid from budget, principal intact.
        vm.prank(bob);
        staking.exit();
        assertApproxEqAbs(token.balanceOf(bob), 1_500e18, 1e12, "stake + funded reward");
        uint256 bobReward = token.balanceOf(bob) - 1_000e18;
        assertEq(staking.rewardBudget(), 1_000e18 - bobReward, "budget debited by actual payout");

        // Alice withdraws in full — the contract holds her principal + her
        // half of the funded budget, exactly. Solvency held for both.
        vm.prank(alice);
        staking.exit();
        assertApproxEqAbs(token.balanceOf(alice), 1_500e18, 1e12, "stake + funded reward");
        uint256 aliceReward = token.balanceOf(alice) - 1_000e18;
        assertEq(staking.rewardBudget(), 1_000e18 - bobReward - aliceReward, "budget retains unpaid dust");
        assertEq(token.balanceOf(address(staking)), staking.rewardBudget());
        assertEq(staking.totalSupply(), 0);
    }

    /// @dev Rollover must stay solvent under the ledger: unspent budget from a
    ///      live epoch carries into the next, never inferred from balance.
    function test_sameTokenRollover_StaySolvent() public {
        vm.prank(alice);
        staking.stake(1_000e18);

        token.mint(address(staking), 3_000e18);
        vm.prank(owner);
        staking.notifyRewardAmount(3_000e18);

        vm.warp(block.timestamp + 15 days); // half unspent (~1_500e18)
        token.mint(address(staking), 3_000e18);
        vm.prank(owner);
        staking.notifyRewardAmount(3_000e18); // rollover: ~4_500e18 over new epoch

        assertApproxEqAbs(staking.rewardBudget(), 6_000e18, 1e6, "all funding is in the budget");
        assertApproxEqAbs(staking.rewardRate(), 4_500e18 / DURATION, 1e6, "leftover rolled over");
    }

    /// @dev The rescue path must never touch staked principal (same-token
    ///      config): the staking-token block holds, and reward-token rescues
    ///      are capped above the budget so earned rewards stay payable.
    function test_sameTokenRescue_NeverDrainsPrincipalOrEarned() public {
        vm.prank(alice);
        staking.stake(1_000e18);
        token.mint(address(staking), 1_000e18); // funded budget
        vm.prank(owner);
        staking.notifyRewardAmount(1_000e18);

        // Staking token is never rescuable, even though it is also the
        // reward token here — principal protection wins.
        vm.prank(owner);
        vm.expectRevert(DAOStaking.CannotRecoverStakingToken.selector);
        staking.recoverERC20(address(token), 1);

        token.mint(address(staking), 5e18);
        vm.prank(owner);
        vm.expectRevert(DAOStaking.CannotRecoverStakingToken.selector);
        staking.recoverERC20(address(token), 5e18);
        assertEq(token.balanceOf(owner), 0);
        assertEq(staking.balanceOf(alice), 1_000e18);
        assertEq(token.balanceOf(address(staking)), 2_005e18);
        assertEq(staking.rewardBudget(), 1_000e18, "earned-reward backing untouched");
    }
}
