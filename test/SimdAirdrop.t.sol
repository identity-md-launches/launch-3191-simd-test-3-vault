// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "./helpers/VaultTestBase.sol";
import {MerkleFixture} from "./helpers/MerkleFixture.sol";
import {SimdAirdrop} from "../src/SimdAirdrop.sol";
import {LaunchPool} from "../src/libraries/LaunchPool.sol";

contract SimdAirdropTest is VaultTestBase, MerkleFixture {
    function test_productionRootListSizeWeightAndUnknownWalletRejection() public {
        _bind(true);
        assertEq(drop.MERKLE_ROOT(), 0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4);
        assertEq(drop.TOTAL_WEIGHT(), 633028988023500000000000000);
        assertEq(drop.WALLET_COUNT(), 457);
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(1, new bytes32[](0));
        assertFalse(drop.claimed(alice));
        assertEq(launchedToken.balanceOf(alice), 0);
    }

    function test_bindOnlyVaultOnceAndRequiresFundedRemainder() public {
        vm.expectRevert(SimdAirdrop.NotVault.selector);
        drop.bind(NUMBER);
        uint256 weight = drop.TOTAL_WEIGHT();
        launchedToken.mint(address(drop), weight - 1);
        vm.prank(address(vault));
        vm.expectRevert(SimdAirdrop.InsufficientRemainder.selector);
        drop.bind(NUMBER);
        assertEq(drop.claimEnd(), 0);
        launchedToken.mint(address(drop), 1);
        vm.prank(address(vault));
        drop.bind(NUMBER);
        assertEq(drop.startBalance(), weight);
        vm.prank(address(vault));
        vm.expectRevert(SimdAirdrop.AlreadyBound.selector);
        drop.bind(NUMBER);
    }

    function test_oldLaunchForeignRequesterAndNonIMDPoolRejected() public {
        vm.prank(address(vault));
        vm.expectRevert(SimdAirdrop.OldLaunch.selector);
        drop.bind(3187);
        factory.setPosition(NUMBER, IMD, address(launchedToken), alice);
        vm.prank(address(vault));
        vm.expectRevert(LaunchPool.WrongRequester.selector);
        drop.bind(NUMBER);
        factory.setPosition(NUMBER, address(launchedToken), address(launchedToken), address(vault));
        vm.prank(address(vault));
        vm.expectRevert(LaunchPool.InvalidPair.selector);
        drop.bind(NUMBER);
        factory.setPosition(3188, IMD, address(launchedToken), address(vault));
        launchedToken.mint(address(drop), drop.TOTAL_WEIGHT());
        vm.prank(address(vault));
        drop.bind(3188);
    }

    function test_claimAndBurnBeforeBindingRejected() public {
        vm.expectRevert(SimdAirdrop.NotBound.selector);
        drop.claim(1, new bytes32[](0));
        vm.expectRevert(SimdAirdrop.NotBound.selector);
        drop.burnUnclaimed();
    }

    function test_fixtureClaimsProRataOnlySenderOnceBadProofAndUnlistedGetNothing() public {
        uint256 total = drop.TOTAL_WEIGHT();
        uint256 a = total / 4;
        uint256 b = total - a;
        _installFixtureRoot(drop, _pair(_leaf(alice, a), _leaf(bob, b)));
        launchedToken.mint(address(drop), total); // additional prebind donation doubles the snapshot
        _bind(true);
        bytes32[] memory proofA = _proof(_leaf(bob, b));
        bytes32[] memory proofB = _proof(_leaf(alice, a));
        vm.prank(carol);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(a, proofA);
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(a + 1, proofA);
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.InvalidProof.selector);
        drop.claim(a, proofB);
        vm.prank(alice);
        drop.claim(a, proofA);
        assertEq(launchedToken.balanceOf(alice), 2 * a);
        vm.prank(alice);
        vm.expectRevert(SimdAirdrop.AlreadyClaimed.selector);
        drop.claim(a, proofA);
        vm.prank(bob);
        drop.claim(b, proofB);
        assertEq(launchedToken.balanceOf(bob), 2 * b);
        assertEq(launchedToken.balanceOf(carol), 0);
        assertEq(launchedToken.balanceOf(address(drop)), 0);
    }

    function test_fixtureClaimWindowAndBurnExactBoundaryAndLateDonation() public {
        uint256 a = drop.TOTAL_WEIGHT() / 2;
        _installFixtureRoot(drop, _pair(_leaf(alice, a), _leaf(bob, a)));
        _bind(true);
        uint256 end = drop.claimEnd();
        launchedToken.mint(address(drop), 13); // never changes the snapshot
        assertEq(drop.amountOf(a), a);
        vm.warp(end - 1);
        vm.expectRevert(SimdAirdrop.ClaimStillOpen.selector);
        drop.burnUnclaimed();
        vm.prank(alice);
        drop.claim(a, _proof(_leaf(bob, a)));
        vm.warp(end);
        vm.prank(bob);
        vm.expectRevert(SimdAirdrop.ClaimClosed.selector);
        drop.claim(a, _proof(_leaf(alice, a)));
        drop.burnUnclaimed();
        assertEq(launchedToken.balanceOf(DEAD), a + 13);
        assertEq(drop.claimEnd(), end);
        launchedToken.mint(address(drop), 7);
        drop.burnUnclaimed();
        assertEq(launchedToken.balanceOf(DEAD), a + 20);
    }

    function test_fixtureFailedTransferDoesNotConsumeClaimAndReentryCannotDoubleClaim() public {
        uint256 a = drop.TOTAL_WEIGHT();
        // Make the token itself a fixture beneficiary to exercise the reentrancy guard with a valid proof.
        _installFixtureRoot(drop, _leaf(address(launchedToken), a));
        _bind(true);
        launchedToken.configure(0, 2, false);
        vm.prank(address(launchedToken));
        vm.expectRevert();
        drop.claim(a, new bytes32[](0));
        assertFalse(drop.claimed(address(launchedToken)));
        launchedToken.configure(0, 0, false);
        launchedToken.setCallback(address(drop), abi.encodeCall(drop.claim, (a, new bytes32[](0))));
        vm.prank(address(launchedToken));
        drop.claim(a, new bytes32[](0));
        assertTrue(launchedToken.callbackBlocked());
        assertTrue(drop.claimed(address(launchedToken)));
        assertEq(launchedToken.balanceOf(address(launchedToken)), a);
    }

    function test_failedBurnCanBeRetried() public {
        _bind(true);
        _advance(30 days);
        launchedToken.configure(0, 1, false);
        vm.expectRevert("transfer rejected");
        drop.burnUnclaimed();
        assertEq(launchedToken.balanceOf(address(drop)), drop.startBalance());
        launchedToken.configure(0, 0, false);
        drop.burnUnclaimed();
        assertEq(launchedToken.balanceOf(DEAD), drop.startBalance());
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_proRataFloorsWithoutOverflow(uint256 balance, uint256 weight) public {
        balance = bound(balance, drop.TOTAL_WEIGHT(), type(uint256).max);
        weight = bound(weight, 0, drop.TOTAL_WEIGHT());
        launchedToken.mint(address(drop), balance);
        vm.prank(address(vault));
        drop.bind(NUMBER);
        uint256 payout = drop.amountOf(weight);
        uint256 rest = drop.amountOf(drop.TOTAL_WEIGHT() - weight);
        assertLe(payout, balance);
        assertLe(rest, balance - payout);
        assertLe(balance - payout - rest, 1);
    }
}
