// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";

contract RewardPropertiesTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        _bind(false);
    }

    /// @dev A time-integral economic oracle: each staker owns their fraction of the first
    /// interval; after Bob leaves Alice owns the entire remaining interval. Since stake < SCALE,
    /// each interval can lose at most one raw reward unit to per-token and per-account flooring.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_departingStakerGetsOnlyTheirTimeWeightedShare(
        uint96 rawAlice,
        uint96 rawBob,
        uint96 rawRate,
        uint32 rawElapsed
    ) public {
        uint256 a = bound(uint256(rawAlice), 1, 1e24);
        uint256 b = bound(uint256(rawBob), 1, 1e24);
        uint256 rate = bound(uint256(rawRate), 1, 1e22);
        uint256 elapsed = uint256(rawElapsed) % (WEEK + 1);
        _stake(alice, a);
        _stake(bob, b);
        uint256 deposited = rate * WEEK;
        _deposit(deposited);
        _advance(elapsed);
        vm.prank(bob);
        rewards.exit();
        uint256 expectedBob = rate * elapsed * b / (a + b);
        assertLe(imd.balanceOf(bob), expectedBob);
        assertApproxEqAbs(imd.balanceOf(bob), expectedBob, 1);
        assertEq(launchedToken.balanceOf(bob), b);
        _advance(WEEK - elapsed);
        _claim(alice);
        uint256 expectedAlice = rate * elapsed * a / (a + b) + rate * (WEEK - elapsed);
        assertApproxEqAbs(imd.balanceOf(alice), expectedAlice, 2);
        uint256 paid = imd.balanceOf(alice) + imd.balanceOf(bob);
        assertLe(paid, deposited);
        assertEq(paid + rewards.reserved(), deposited);
        assertEq(imd.balanceOf(address(rewards)), rewards.reserved());
        _advance(2 * WEEK);
        _claim(alice);
        _claim(bob);
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), paid, "no earnings after the stream ends");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_midStreamTopupCannotErasePreviouslyEarnedOrFutureRewards(
        uint96 rawFirst,
        uint96 rawSecond,
        uint32 rawElapsed
    ) public {
        uint256 first = bound(uint256(rawFirst), 1, 1e28);
        uint256 second = bound(uint256(rawSecond), 1, 1e28);
        uint256 elapsed = uint256(rawElapsed) % WEEK;
        _stake(alice, 1);
        _deposit(first);
        _advance(elapsed);
        uint256 accrued = rewards.earned(alice);
        _deposit(second);
        assertEq(rewards.earned(alice), accrued, "topup cannot reset already accrued earnings");
        assertEq(rewards.periodFinish(), block.timestamp + WEEK);
        _advance(WEEK);
        _claim(alice);
        uint256 paid = imd.balanceOf(alice);
        assertLe(paid, first + second);
        assertApproxEqAbs(paid, first + second, 1);
        assertEq(rewards.reserved() + paid, first + second);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_emptyPeriodsConserveScaledCarryAndDoNotPayTheNextStakerRetroactively(
        uint96 rawFirst,
        uint96 rawSecond
    ) public {
        uint256 first = bound(uint256(rawFirst), 1, 1e28);
        uint256 second = bound(uint256(rawSecond), 1, 1e28);
        _deposit(first);
        _advance(WEEK);
        _deposit(0);
        assertEq(rewards.carryScaled(), first * 1e36, "stream plus rate dust equals the entire unallocated deposit");
        uint256 finished = rewards.periodFinish();
        _advance(1 days);
        _stake(alice, 1);
        assertEq(rewards.earned(alice), 0);
        _deposit(0);
        assertEq(rewards.periodFinish(), finished, "an empty notification cannot restart carry");
        _deposit(second);
        assertEq(rewards.earned(alice), 0, "carried funds stream forward from the new deposit");
        _advance(WEEK);
        _claim(alice);
        uint256 paid = imd.balanceOf(alice);
        assertLe(paid, first + second);
        assertApproxEqAbs(paid, first + second, 1);
        assertEq(rewards.reserved() + paid, first + second);
        assertEq(imd.balanceOf(address(rewards)), rewards.reserved());
    }
}
