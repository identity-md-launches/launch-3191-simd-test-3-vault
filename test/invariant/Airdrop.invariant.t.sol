// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultTestBase} from "../helpers/VaultTestBase.sol";
import {MerkleFixture} from "../helpers/MerkleFixture.sol";
import {AirdropHandler} from "./AirdropHandler.sol";

abstract contract AirdropInvariantBase is VaultTestBase, MerkleFixture {
    AirdropHandler internal handler;
    bytes32 internal testedRoot;

    function usesFixture() internal pure virtual returns (bool);

    function setUp() public override {
        super.setUp();
        _bind(false);
        handler = new AirdropHandler(vault, launchedToken, usesFixture());
        testedRoot = usesFixture() ? handler.fixtureRoot() : drop.MERKLE_ROOT();
        if (usesFixture()) _installFixtureRoot(drop, testedRoot);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.donate.selector;
        selectors[1] = handler.bind.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.claim.selector;
        selectors[4] = handler.burn.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        // Leave binding to the random sequence; there are both valid and invalid early actions.
        handler.donate(drop.TOTAL_WEIGHT());
    }

    function invariant_airdropConservesTokensAndCannotReopenOrReallocate() public view {
        assertFalse(handler.violated(), "wrong claim/bind/burn outcome or revert reason");
        assertEq(drop.MERKLE_ROOT(), testedRoot);
        assertEq(drop.TOTAL_WEIGHT(), handler.totalWeight());
        assertEq(drop.WALLET_COUNT(), 457);
        assertEq(drop.startBalance(), handler.snapshotBalance(), "donations and rebinding cannot resize allocations");
        assertEq(drop.claimEnd(), handler.deadline(), "claim window cannot restart");
        assertEq(drop.token(), handler.boundOnce() ? address(launchedToken) : address(0));
        assertEq(launchedToken.balanceOf(address(drop)) + handler.paid() + handler.burned(), handler.issued());
        assertEq(launchedToken.balanceOf(DEAD), handler.burned());
        uint256 sumPaid;
        uint256 unclaimed;
        for (uint256 i; i < 4; ++i) {
            address who = handler.actors(i);
            assertEq(drop.claimed(who), handler.hasClaimed(i), "failed transfers/proofs cannot consume claims");
            assertEq(launchedToken.balanceOf(who), handler.paidTo(i));
            uint256 share = handler.snapshotBalance() * handler.weights(i) / handler.totalWeight();
            assertLe(handler.paidTo(i), share, "no account receives its allocation twice");
            if (!handler.hasClaimed(i)) unclaimed += share;
            sumPaid += handler.paidTo(i);
        }
        assertEq(sumPaid, handler.paid());
        assertLe(sumPaid, handler.snapshotBalance());
        assertFalse(drop.claimed(handler.actors(4)));
        assertEq(launchedToken.balanceOf(handler.actors(4)), 0, "unlisted wallet never receives a share");
        if (handler.boundOnce() && block.timestamp < handler.deadline()) {
            assertEq(handler.burned(), 0, "no premature burns");
            assertGe(launchedToken.balanceOf(address(drop)), unclaimed, "remaining allocations stay funded");
        }
        if (!usesFixture()) assertEq(sumPaid, 0, "synthetic proofs must fail against the original commitment");
    }

    function afterInvariant() public {
        handler.settle();
        invariant_airdropConservesTokensAndCannotReopenOrReallocate();
        assertEq(launchedToken.balanceOf(address(drop)), 0);
    }
}

/// @notice The production commitment and implementation are untouched in this invariant suite.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract AirdropCommitmentInvariantTest is AirdropInvariantBase {
    function usesFixture() internal pure override returns (bool) {
        return false;
    }
}

/// @notice Claim state machine only: the supplied list has no published proof fixture in this repo.
/// A synthetic root does not validate membership or the weight sum of the real 457-wallet list.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
contract AirdropFixtureInvariantTest is AirdropInvariantBase {
    function usesFixture() internal pure override returns (bool) {
        return true;
    }

    function test_handlerExercisesClaimFailureRetryDuplicateAndLateDonation() public {
        handler.bind(false);
        handler.claim(0, 0, true); // transfer fails; claim remains available
        handler.claim(0, 0, false);
        handler.claim(0, 0, false); // duplicate
        handler.claim(1, 1, false); // altered weight
        handler.claim(2, 2, false); // altered proof
        handler.claim(4, 0, false); // unlisted sender using a listed proof
        handler.donate(7);
        handler.burn(false); // still open
        invariant_airdropConservesTokensAndCannotReopenOrReallocate();
        vm.warp(handler.deadline() - 1);
        handler.claim(1, 0, false);
        vm.warp(handler.deadline());
        handler.claim(2, 0, false); // exact expiry
        handler.burn(true); // failed transfer preserves all unclaimed funds
        handler.burn(false);
        handler.donate(11);
        handler.burn(false);
        assertEq(handler.paid(), handler.snapshotBalance() * 3 / 10);
        assertGe(handler.rejections(), 8);
        afterInvariant();
    }
}
