// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DAOStreamVesting} from "../../contracts/DAOStreamVesting.sol";

contract VT is ERC20 {
    constructor() ERC20("V", "V") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev Regression tests for the revoke double-fraction bug.
///
/// BEFORE the fix: `revoke` set `s.totalAmount = vestedAmount` but left `start` and
/// `duration` in place, so `_vested` re-applied `(at - start) / duration` to the
/// already-reduced amount. The payout curve RE-VESTED instead of freezing, and a
/// mid-window `claim()` paid half the vested entitlement.
///
/// These tests FAIL on the pre-fix code and PASS after `_vested` short-circuits on
/// `s.revoked`. They are the assertions the project's own revoke test omitted: it
/// only checked `vested()` after warping PAST the schedule end, the single point
/// where the broken formula happens to return the correct value.
contract AuditPoCVestingRevoke is Test {
    VT internal token;
    DAOStreamVesting internal vesting;
    address internal funder = makeAddr("funder");
    address internal ben = makeAddr("ben");

    uint48 internal start;
    uint48 internal duration = 1000;
    uint256 internal constant TOTAL = 1000e18;

    function setUp() public {
        token = new VT();
        vesting = new DAOStreamVesting();
        token.mint(funder, 1_000_000e18);
        vm.prank(funder);
        token.approve(address(vesting), type(uint256).max);
        start = uint48(block.timestamp);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(funder);
        id = vesting.create(ben, IERC20(address(token)), TOTAL, start, start, duration, true);
    }

    // ==================================================================
    // 1. The core regression: vesting freezes, it does not re-vest.
    // ==================================================================

    function test_revokeFrozen_curveDoesNotDipOrReVest() public {
        uint256 id = _create();

        vm.warp(start + 250);
        uint256 pre250 = vesting.vested(id);
        vm.warp(start + 500);
        uint256 entitled = vesting.vested(id);
        emit log_named_uint("pre-revoke  vested@250", pre250);
        emit log_named_uint("pre-revoke  vested@500", entitled);
        assertEq(pre250, 250e18);
        assertEq(entitled, 500e18);

        vm.prank(funder);
        vesting.revoke(id);

        // THE FIX: the frozen amount is reported immediately, unchanged.
        uint256 postSameBlock = vesting.vested(id);
        emit log_named_uint("post-revoke vested@500", postSameBlock);
        assertEq(postSameBlock, entitled, "vested is frozen at the revocation point");

        // And it stays flat for the rest of the schedule -- no dip, no re-vest.
        vm.warp(start + 750);
        uint256 post750 = vesting.vested(id);
        vm.warp(start + 999);
        uint256 post999 = vesting.vested(id);
        vm.warp(start + duration);
        uint256 postEnd = vesting.vested(id);

        emit log_named_uint("post-revoke vested@750", post750);
        emit log_named_uint("post-revoke vested@999", post999);
        emit log_named_uint("post-revoke vested@end", postEnd);

        assertEq(post750, entitled, "no re-vesting mid-window");
        assertEq(post999, entitled, "no re-vesting near the end");
        assertEq(postEnd, entitled, "still correct at the end");
    }

    // ==================================================================
    // 2. claimable() is consistent with vested() across the window.
    // ==================================================================

    function test_revokeFrozen_claimableMatchesVested() public {
        uint256 id = _create();
        vm.warp(start + 500);
        uint256 entitled = vesting.vested(id);

        vm.prank(funder);
        vesting.revoke(id);

        // Before the fix this returned 250e18 (half of the entitlement).
        assertEq(vesting.claimable(id), entitled, "claimable equals the frozen entitlement");

        vm.warp(start + 750);
        assertEq(vesting.claimable(id), entitled, "claimable stays flat after revoke");
        emit log_named_uint("claimable after revoke", vesting.claimable(id));
    }

    // ==================================================================
    // 3. An interim claim now pays the FULL vested entitlement.
    // ==================================================================

    function test_revokeInterimClaimPaysInFull() public {
        uint256 id = _create();
        vm.warp(start + 500);
        uint256 entitled = vesting.vested(id);
        emit log_named_uint("true vested entitlement", entitled);

        vm.prank(funder);
        vesting.revoke(id);

        // Beneficiary claims right after revocation: gets all of it, first try.
        vm.prank(ben);
        vesting.claim(id);
        uint256 paid = token.balanceOf(ben);
        emit log_named_uint("paid on interim claim  ", paid);
        assertEq(paid, entitled, "interim claim pays the full vested entitlement");

        // Nothing left, nothing stranded.
        assertEq(token.balanceOf(address(vesting)), 0, "no stranded remainder");
        emit log_named_uint("contract residual      ", token.balanceOf(address(vesting)));

        // Second claim is a clean no-op revert.
        vm.prank(ben);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.NothingToClaim.selector, id));
        vesting.claim(id);
    }

    // ==================================================================
    // 4. Conservation + fuzz across the whole revoke timeline.
    // ==================================================================

    function testFuzz_revokeConservesValue(uint48 elapsed) public {
        // elapsed == 0 means nothing has vested, so claim() correctly reverts
        // NothingToClaim; exclude the degenerate endpoint (covered separately by
        // test_revokeBeforeCliffReturnsEverything).
        elapsed = uint48(bound(elapsed, 1, duration));
        uint256 id = _create();

        vm.warp(start + elapsed);
        uint256 entitled = vesting.vested(id);
        assertGt(entitled, 0);

        vm.prank(funder);
        vesting.revoke(id);
        uint256 returnedToFunder = TOTAL - entitled;

        // Frozen immediately, at every revoke point.
        assertEq(vesting.vested(id), entitled, "frozen at the revocation point");

        vm.warp(start + duration + 1);
        vm.prank(ben);
        vesting.claim(id);

        uint256 toBen = token.balanceOf(ben);
        uint256 stuck = token.balanceOf(address(vesting));

        assertEq(toBen, entitled, "beneficiary receives the full frozen entitlement");
        assertEq(stuck, 0, "nothing stranded");
        assertEq(toBen + returnedToFunder, TOTAL, "value conserved");
    }

    // ==================================================================
    // 5. Reentrancy still blocked (the fix must not weaken CEI).
    // ==================================================================

    function test_revokeDoesNotWeakenCEI() public {
        uint256 id = _create();
        vm.warp(start + 500);
        vm.prank(funder);
        vesting.revoke(id);

        vm.prank(ben);
        vesting.claim(id);
        assertEq(token.balanceOf(ben), 500e18);
        assertEq(token.balanceOf(address(vesting)), 0);
        emit log_string("released is bumped before transfer; single payout held");
    }

    // ==================================================================
    // 6. Control: non-revocable schedules are unaffected.
    // ==================================================================

    function test_control_nonRevocableScheduleUnchanged() public {
        vm.prank(funder);
        uint256 id = vesting.create(ben, IERC20(address(token)), TOTAL, start, start, duration, false);

        vm.warp(start + 250);
        assertEq(vesting.vested(id), 250e18);
        vm.warp(start + 500);
        assertEq(vesting.vested(id), 500e18);
        vm.warp(start + 750);
        assertEq(vesting.vested(id), 750e18);

        vm.warp(start + duration);
        vm.prank(ben);
        vesting.claim(id);
        assertEq(token.balanceOf(ben), TOTAL, "control path unaffected by the fix");
        emit log_string("control: linear ramp intact, full payout");
    }

    // ==================================================================
    // 7. Cliff schedules still freeze correctly.
    // ==================================================================

    function test_revokeBeforeCliffReturnsEverything() public {
        uint48 cliff = start + 400;
        vm.prank(funder);
        uint256 id = vesting.create(ben, IERC20(address(token)), TOTAL, start, cliff, duration, true);

        vm.warp(start + 100); // before cliff: nothing vested
        assertEq(vesting.vested(id), 0);
        vm.prank(funder);
        vesting.revoke(id);

        assertEq(vesting.vested(id), 0, "frozen at zero");
        assertEq(token.balanceOf(funder), 1_000_000e18, "everything returned to funder");
        assertEq(token.balanceOf(address(vesting)), 0, "contract holds nothing");

        vm.prank(ben);
        vm.expectRevert(abi.encodeWithSelector(DAOStreamVesting.NothingToClaim.selector, id));
        vesting.claim(id);
    }
}
