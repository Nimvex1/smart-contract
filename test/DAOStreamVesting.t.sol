// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAOStreamVesting} from "../contracts/DAOStreamVesting.sol";

contract VestMint is ERC20 {
    constructor() ERC20("Vest", "VST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev 5% fee-on-transfer token: recipient gets 95% of the sent amount.
contract FeeMint is ERC20 {
    constructor() ERC20("Fee", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * 5) / 100;
        super._update(from, address(0), fee); // burn the fee
        super._update(from, to, value - fee);
    }
}

/// @dev P1-1 tests: linear math (cliff/partial/full), claim flow, revocation trust
///      (vested stays, unvested returns, only revoker), and input validation.
contract DAOStreamVestingTest is Test {
    VestMint internal token;
    DAOStreamVesting internal vesting;

    address internal funder = makeAddr("funder");
    address internal beneficiary = makeAddr("beneficiary");
    address internal rando = makeAddr("rando");

    uint48 internal start;
    uint48 internal constant CLIFF_DELAY = 30 days;
    uint48 internal constant DURATION = 360 days;

    function setUp() public {
        token = new VestMint();
        vesting = new DAOStreamVesting();
        token.mint(funder, 1_000_000e18);
        vm.prank(funder);
        token.approve(address(vesting), type(uint256).max);
        start = uint48(block.timestamp);
    }

    function _create(uint256 amount, bool revocable) internal returns (uint256 id) {
        vm.prank(funder);
        id = vesting.create(
            beneficiary, IERC20(address(token)), amount, start, start + CLIFF_DELAY, DURATION, revocable
        );
    }

    function test_Create_PullsFundsAndEmits() public {
        vm.expectEmit(true, true, true, true, address(vesting));
        emit DAOStreamVesting.VestingCreated(
            1, beneficiary, address(token), 12_000e18, start, start + CLIFF_DELAY, DURATION, true
        );
        uint256 id = _create(12_000e18, true);
        assertEq(id, 1);
        assertEq(token.balanceOf(address(vesting)), 12_000e18);
        assertTrue(vesting.scheduleExists(id));
    }

    function test_Vesting_CliffThenLinearThenFull() public {
        uint256 id = _create(12_000e18, false);
        assertEq(vesting.vested(id), 0, "nothing vests at start");
        vm.warp(uint256(start + CLIFF_DELAY) - 1);
        assertEq(vesting.vested(id), 0, "nothing vests before cliff");
        vm.warp(uint256(start) + uint256(DURATION) / 2);
        assertApproxEqAbs(vesting.vested(id), 6_000e18, 2, "half time ~= half tokens");
        vm.warp(uint256(start) + DURATION);
        assertEq(vesting.vested(id), 12_000e18, "everything vested at end");
        vm.warp(uint256(start) + DURATION + 365 days);
        assertEq(vesting.vested(id), 12_000e18, "vested never exceeds total");
    }

    function test_Claim_PaysBeneficiaryAndTracksReleased() public {
        uint256 id = _create(12_000e18, false);
        vm.warp(uint256(start) + DURATION);
        vm.expectEmit(true, true, false, true, address(vesting));
        emit DAOStreamVesting.VestedClaimed(id, beneficiary, 12_000e18);
        vesting.claim(id);
        assertEq(token.balanceOf(beneficiary), 12_000e18);
        assertEq(vesting.claimable(id), 0);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.NothingToClaim.selector, id));
        vesting.claim(id);
    }

    function test_Claim_PermissionlessPartial() public {
        uint256 id = _create(12_000e18, false);
        vm.warp(uint256(start) + uint256(DURATION) / 2);
        uint256 half = vesting.claimable(id);
        assertGt(half, 0);
        vm.prank(rando); // anyone may poke the claim
        vesting.claim(id);
        assertEq(token.balanceOf(beneficiary), half);
    }

    function test_Revoke_ReturnsUnvestedKeepsVestedClaimable() public {
        uint256 id = _create(12_000e18, true);
        vm.warp(uint256(start) + uint256(DURATION) / 2);
        uint256 vestedBefore = vesting.vested(id);
        uint256 funderBefore = token.balanceOf(funder);

        vm.expectEmit(true, false, false, true, address(vesting));
        emit DAOStreamVesting.VestingRevoked(id, 12_000e18 - vestedBefore);
        vm.prank(funder);
        vesting.revoke(id);

        assertEq(token.balanceOf(funder) - funderBefore, 12_000e18 - vestedBefore, "unvested returns to funder");

        // Revocation must freeze vesting AT THE REVOCATION POINT, not merely at the
        // end of the schedule. Asserting only after `warp(start + DURATION + 1)` used
        // to hide a double-fraction bug in `_vested`: the elapsed-time fraction was
        // re-applied to the already-frozen `totalAmount`, so the curve dipped and
        // re-vested through the whole remaining window. Pin the interim window too.
        assertEq(vesting.vested(id), vestedBefore, "vested frozen in the same block as revoke");
        assertEq(vesting.claimable(id), vestedBefore, "claimable frozen in the same block as revoke");

        vm.warp(uint256(start) + (uint256(DURATION) * 3) / 4);
        assertEq(vesting.vested(id), vestedBefore, "revocation freezes vesting mid-window");
        assertEq(vesting.claimable(id), vestedBefore, "claimable stays flat mid-window");

        vm.warp(uint256(start) + DURATION + 1);
        assertEq(vesting.vested(id), vestedBefore, "revocation freezes vesting");
        vesting.claim(id);
        assertEq(token.balanceOf(beneficiary), vestedBefore, "vested remains claimable after revoke");
    }

    function test_Revoke_RevertsWhen_NotRevocableNotRevokerOrTwice() public {
        uint256 plain = _create(1_000e18, false);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.NotRevocable.selector, plain));
        vesting.revoke(plain);

        uint256 id = _create(1_000e18, true);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.CallerNotRevoker.selector, id, rando));
        vesting.revoke(id);

        vm.prank(funder);
        vesting.revoke(id);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.AlreadyRevoked.selector, id));
        vesting.revoke(id);
    }

    function test_Create_RevertsWhen_InvalidInputs() public {
        vm.prank(funder);
        vm.expectRevert(DAOStreamVesting.InvalidBeneficiary.selector);
        vesting.create(address(0), IERC20(address(token)), 1e18, start, start, DURATION, false);

        vm.prank(funder);
        vm.expectRevert(DAOStreamVesting.InvalidZeroAmount.selector);
        vesting.create(beneficiary, IERC20(address(token)), 0, start, start, DURATION, false);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.InvalidTimeRange.selector, start, start - 1, DURATION));
        vesting.create(beneficiary, IERC20(address(token)), 1e18, start, start - 1, DURATION, false);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.InvalidTimeRange.selector, start, start, 0));
        vesting.create(beneficiary, IERC20(address(token)), 1e18, start, start, 0, false);

        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.ScheduleNotFound.selector, 999));
        vesting.claim(999);
    }

    function test_EndToEnd_FundVestClaim() public {
        // Flow C (tokenomics leg): fund -> vest -> claim, all real calls.
        uint256 id = _create(12_000e18, true);
        vm.warp(uint256(start) + DURATION);
        assertEq(vesting.claimable(id), 12_000e18);
        vesting.claim(id);
        assertEq(token.balanceOf(beneficiary), 12_000e18);
        assertEq(token.balanceOf(address(vesting)), 0, "no dust left behind");
    }

    function testFuzz_Vested_NeverExceedsTotal(uint48 at, uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        uint256 id = _create(amount, false);
        at = uint48(bound(at, 0, uint48(block.timestamp) + 720 days));
        vm.warp(at);
        assertLe(vesting.vested(id), amount);
        assertEq(vesting.claimable(id) + vesting.getSchedule(id).released, vesting.vested(id));
    }

    function test_Create_RecordsActuallyReceivedForFeeToken() public {
        FeeMint fee = new FeeMint();
        fee.mint(funder, 10_000e18);
        vm.prank(funder);
        fee.approve(address(vesting), type(uint256).max);

        vm.prank(funder);
        uint256 id =
            vesting.create(beneficiary, IERC20(address(fee)), 10_000e18, start, start + CLIFF_DELAY, DURATION, false);
        // 5% fee: schedule vests exactly the 9,500 that arrived — no phantom allocation.
        assertEq(vesting.getSchedule(id).totalAmount, 9_500e18);

        vm.warp(uint256(start) + DURATION);
        vesting.claim(id);
        // Claim itself also pays the 5% fee: 9,500 vested -> 9,025 to beneficiary.
        assertEq(fee.balanceOf(beneficiary), 9_025e18, "claims pay out, nothing stranded");
        assertEq(fee.balanceOf(address(vesting)), 0);
    }
}
