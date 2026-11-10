// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "../helpers/VaultTestBase.sol";
import {VaultSystemHandler} from "./VaultSystemHandler.sol";

/// @notice Joint invariants for SIMDVault, StakeRewards and JobsVault, including their shared IMD.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract VaultSystemInvariantTest is VaultTestBase {
    VaultSystemHandler internal handler;

    function setUp() public override {
        super.setUp();
        _bind(false);
        handler = new VaultSystemHandler(vault, launchedToken);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.donateOtherAssets.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.stake.selector;
        selectors[4] = handler.withdraw.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.notify.selector;
        selectors[7] = handler.distribute.selector;
        selectors[8] = handler.requestJob.selector;
        selectors[9] = handler.launch.selector;
        selectors[10] = handler.unauthorized.selector;
        targetSelector(FuzzSelector(address(handler), selectors));

        // Seed an earning, locked position as well as an unlocked position. Random runs can then
        // exercise both successful and rejected withdrawals without needing a lucky setup order.
        handler.fund(10000 ether, 0);
        handler.stake(0, 1_000_000 ether);
        handler.stake(1, 2_000_000 ether);
        handler.distribute(0, false, false);
        handler.requestJob(0, 2, uint96(PRICE), false);
    }

    function invariant_allFundsAndLiabilitiesRemainAccountedFor() public view {
        assertFalse(handler.violated(), "unexpected success, failure, payout, or rollback");
        uint256 sumStakes;
        uint256 sumEarned;
        uint256 sumPaid;
        for (uint256 i; i < 3; ++i) {
            address who = handler.actors(i);
            uint256 principal = handler.principalIn(who) - handler.principalOut(who);
            assertEq(rewards.stakeOf(who), principal, "principal cannot move between accounts");
            assertEq(launchedToken.balanceOf(who), handler.principalOut(who), "withdraw exactly owned principal");
            assertEq(imd.balanceOf(who), handler.paidTo(who), "only claims pay stakers IMD");
            assertEq(rewards.lockedUntil(who), handler.lockUntil(who), "failed jobs cannot extend locks");
            assertEq(jobs.nextJobAt(who), handler.lockUntil(who), "one cooldown per successful job");
            sumStakes += principal;
            sumEarned += rewards.earned(who);
            sumPaid += handler.paidTo(who);
        }
        assertEq(rewards.totalStaked(), sumStakes);
        assertEq(launchedToken.balanceOf(address(rewards)), sumStakes + handler.principalDonations());
        assertEq(sumPaid, handler.rewardPaid());
        assertLe(sumPaid, handler.rewardNotified(), "claims never exceed notified funding");
        assertEq(rewards.reserved() + sumPaid, handler.rewardNotified());
        assertGe(imd.balanceOf(address(rewards)), rewards.reserved());
        assertLe(sumEarned, rewards.reserved(), "all currently claimable rewards are solvent together");

        assertEq(imd.balanceOf(address(jobs)) + handler.jobsSpent(), handler.jobsFunded());
        assertEq(imd.balanceOf(treasury), handler.launchSpent() + handler.jobsSpent());
        assertEq(imd.balanceOf(DEV), handler.beneficiariesPaid());
        assertEq(
            imd.balanceOf(address(vault)) + imd.balanceOf(address(rewards)) + imd.balanceOf(address(jobs))
                + imd.balanceOf(FACTORY) + imd.balanceOf(treasury) + imd.balanceOf(DEV) + sumPaid,
            handler.issuedIMD(),
            "global IMD conservation across fees, spending, distributions, donations and claims"
        );
        assertEq(address(vault).balance + handler.nativePaid(), handler.nativeFunded());
        assertEq(MARKETING.balance, handler.nativePaid());
        assertEq(launchedToken.balanceOf(address(vault)) + launchedToken.balanceOf(DEAD), handler.burnFunding());
        assertEq(imd.allowance(address(vault), INTAKE), 0);
        assertEq(imd.allowance(address(jobs), INTAKE), 0);
        assertEq(vault.launched(), handler.launchPaid());
        assertEq(vault.nextDistributionAt(), handler.nextDistribution());
        assertEq(vault.token(), address(launchedToken));
        assertEq(rewards.token(), address(launchedToken));
        assertEq(rewards.jobsVault(), address(jobs));
        assertEq(jobs.token(), address(launchedToken));
    }

    function afterInvariant() public {
        handler.settle();
        invariant_allFundsAndLiabilitiesRemainAccountedFor();
        assertEq(rewards.totalStaked(), 0, "every unlocked actor can recover all principal");
        assertEq(launchedToken.balanceOf(address(rewards)), handler.principalDonations());
    }

    function test_handlerExercisesSuccessfulAndRejectedTransitions() public {
        handler.withdraw(0, 1, false); // locked
        handler.requestJob(0, 2, uint96(PRICE), false); // cooldown
        handler.fund(100 ether, 3); // pending factory fees
        handler.fund(13 ether, 1); // reward donation, not yet notified
        handler.donateOtherAssets(1 ether, 0);
        handler.donateOtherAssets(1 ether, 1);
        handler.advance(uint32(WEEK));
        handler.distribute(2, true, true); // all best-effort external calls fail
        invariant_allFundsAndLiabilitiesRemainAccountedFor();
        handler.advance(uint32(WEEK));
        handler.distribute(0, false, false); // retained ETH/tokens/fees recover
        handler.requestJob(1, 2, uint96(PRICE), false);
        handler.fund(PRICE, 0);
        handler.launch(true, uint96(PRICE), false);
        handler.launch(true, uint96(PRICE), false); // one-time payment
        assertEq(handler.successfulDistributions(), 3);
        assertEq(handler.successfulJobs(), 2);
        assertGe(handler.rejectedCalls(), 3);
        afterInvariant();
    }
}
