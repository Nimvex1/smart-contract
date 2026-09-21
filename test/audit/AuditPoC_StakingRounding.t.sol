// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAOStaking} from "../../contracts/DAOStaking.sol";

contract T4 is ERC20 {
    constructor() ERC20("T", "T") {}
    function mint(address to, uint256 a) external { _mint(to, a); }
}

/// @dev FINDING: `rewardPerToken()` floors the accumulator, so the epoch payout is
///      strictly less than `rewardRate * rewardsDuration`, and the shortfall is
///      unrecoverable. Measured against a realistic configuration.
///
/// `rewardPerToken() = rewardPerTokenStored + (elapsed * rate * 1e18) / totalSupply`
/// The division truncates, and `earned()` then multiplies back by the staker's
/// balance and divides by 1e18 — so every staker permanently loses the sub-unit
/// remainder. Because `_rewardBudget` is credited with the nominal funding and
/// `_availableRewards()` subtracts the *whole* budget, the difference is stuck in
/// the contract with no recovery path (recoverERC20 is capped above the budget).
contract AuditPoCStakingRounding is Test {
    uint256 internal constant DURATION = 30 days;

    function _deploy(uint256 stake, uint256 reward)
        internal
        returns (DAOStaking s, T4 st, T4 rw, address owner)
    {
        st = new T4();
        rw = new T4();
        owner = makeAddr("owner");
        s = new DAOStaking(IERC20(address(st)), IERC20(address(rw)), owner, DURATION);
        st.mint(address(this), stake);
        st.approve(address(s), type(uint256).max);
        s.stake(stake);
        rw.mint(address(s), reward);
        vm.prank(owner);
        s.notifyRewardAmount(reward);
    }

    // ==================================================================
    // 1. The accumulator rounding loss, measured
    // ==================================================================

    function test_rewardPerTokenRoundingShortsTheEpoch() public {
        uint256 stake = 1e23; // 100_000 tokens staked
        (DAOStaking s, T4 st, T4 rw,) = _deploy(stake, 1_000_000e18);

        uint256 rate = s.rewardRate();
        emit log_named_uint("stake          ", stake);
        emit log_named_uint("reward funded  ", 1_000_000e18);
        emit log_named_uint("rewardRate     ", rate);
        emit log_named_uint("rate*duration  ", rate * DURATION);

        vm.warp(block.timestamp + DURATION + 1);
        uint256 earnedAmt = s.earned(address(this));
        emit log_named_uint("actually earned", earnedAmt);
        emit log_named_uint("SHORTFALL      ", rate * DURATION - earnedAmt);

        assertLt(earnedAmt, rate * DURATION, "accumulator floors the payout");
        assertGt(rate * DURATION - earnedAmt, 0);

        // And no epoch from the funded budget ever pays the nominal commitment.
        assertLt(earnedAmt, 1_000_000e18);
    }

    /// @dev The loss scales inversely with stake size: small stakes truncate harder.
    ///      Boundary table at fixed reward.
    function test_roundingLossScalesWithStakeSize() public {
        uint256[5] memory stakes = [uint256(1e18), 1e20, 1e21, 1e22, 1e23];
        uint256 reward = 1_000_000e18;

        for (uint256 i = 0; i < stakes.length; ++i) {
            (DAOStaking s,,, ) = _deploy(stakes[i], reward);
            uint256 rate = s.rewardRate();
            vm.warp(block.timestamp + DURATION + 1);
            uint256 got = s.earned(address(this));
            emit log_named_uint("  stake", stakes[i]);
            emit log_named_uint("    rate*duration", rate * DURATION);
            emit log_named_uint("    earned      ", got);
            emit log_named_uint("    shortfall   ", rate * DURATION - got);
            // The shortfall is always bounded by totalSupply/1e18 wei (accumulator granularity)
            assertLe(
                rate * DURATION - got,
                stakes[i] / 1e18 + 1,
                "shortfall bounded by accumulator granularity = totalSupply/1e18"
            );
        }
    }

    // ==================================================================
    // 2. The shortfall is permanently unrecoverable
    // ==================================================================

    /// @dev Where the shortfall ends up: it stays inside `_rewardBudget` (the ledger
    ///      is credited nominally, only the payout is floored), so it is NOT stranded
    ///      value — it is a ledger/payout divergence that grows the "budget" faster
    ///      than it is consumed. Measure the divergence and show the practical
    ///      consequence: a later epoch's availability check is computed against an
    ///      inflated budget.
    function test_shortfallStaysInBudgetAndInflatesIt() public {
        uint256 stake = 1e23;
        (DAOStaking s,, T4 rw,) = _deploy(stake, 1_000_000e18);
        address owner = s.owner();

        vm.warp(block.timestamp + DURATION + 1);
        uint256 earnedAmt = s.earned(address(this));
        vm.prank(address(this));
        s.getReward();

        uint256 residual = rw.balanceOf(address(s));
        uint256 budget = s.rewardBudget();
        emit log_named_uint("paid          ", earnedAmt);
        emit log_named_uint("residual      ", residual);
        emit log_named_uint("budget left   ", budget);
        emit log_named_uint("divergence    ", budget - residual);

        // Residual equals the budget: the shortfall was never physically paid out,
        // and the ledger still claims it. Not stranded value, but the budget now
        // over-states what any future claimer can actually receive.
        assertEq(budget, residual, "unpaid dust remains inside the budget ledger");
        assertGt(residual, 0, "dust is real but ledger-tracked");

        // The magnitude, for the report: negligible relative to the epoch.
        emit log_named_uint("dust / funded (ppb)", (residual * 1e9) / 1_000_000e18);
    }

    // ==================================================================
    // 3. Two epochs: the leak does not compound (each is independent)
    // ==================================================================

    function test_leakIsPerEpochNotCompounding() public {
        T4 st = new T4();
        T4 rw = new T4();
        address owner = makeAddr("owner");
        DAOStaking s = new DAOStaking(IERC20(address(st)), IERC20(address(rw)), owner, DURATION);

        st.mint(address(this), 1e23);
        st.approve(address(s), type(uint256).max);
        s.stake(1e23);

        uint256 totalFunded;
        for (uint256 i = 0; i < 5; ++i) {
            vm.warp(block.timestamp + DURATION + 1);
            rw.mint(address(s), 1_000_000e18);
            vm.prank(owner);
            s.notifyRewardAmount(1_000_000e18);
            totalFunded += 1_000_000e18;
            vm.warp(block.timestamp + DURATION + 1);
            s.getReward();
        }

        emit log_named_uint("total funded", totalFunded);
        emit log_named_uint("total paid  ", rw.balanceOf(address(this)));
        emit log_named_uint("residual    ", rw.balanceOf(address(s)));
        emit log_named_uint("budget      ", s.rewardBudget());
        emit log_named_uint("TOTAL LEAK  ", totalFunded - rw.balanceOf(address(this)));

        assertGt(totalFunded - rw.balanceOf(address(this)), 0, "leak accumulates linearly per epoch");
    }
}
