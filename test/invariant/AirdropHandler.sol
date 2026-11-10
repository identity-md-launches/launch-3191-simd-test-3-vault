// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDVault} from "src/SIMDVault.sol";
import {SimdAirdrop} from "src/SimdAirdrop.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Runs once against the unmodified commitment, and separately against a clearly labelled
/// synthetic four-leaf commitment. Only the latter can exercise valid proofs without the real list.
contract AirdropHandler is Test {
    SIMDVault public immutable vault;
    SimdAirdrop public immutable drop;
    MockERC20 public immutable token;
    bool public immutable fixture;
    uint256 public immutable totalWeight;
    bytes32 public immutable originalRoot;
    address[5] public actors;
    uint256[4] public weights;
    bool[4] public hasClaimed;
    uint256[4] public paidTo;
    bool public violated;
    bool public boundOnce;
    uint256 public issued;
    uint256 public snapshotBalance;
    uint256 public deadline;
    uint256 public paid;
    uint256 public burned;
    uint256 public successes;
    uint256 public rejections;

    constructor(SIMDVault vault_, MockERC20 token_, bool fixture_) {
        vault = vault_;
        drop = vault_.airdrop();
        token = token_;
        fixture = fixture_;
        totalWeight = drop.TOTAL_WEIGHT();
        originalRoot = drop.MERKLE_ROOT();
        uint256 assigned;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("airdrop invariant claimant ", vm.toString(i)));
            if (i < 4) {
                weights[i] = i == 3 ? totalWeight - assigned : totalWeight * (i + 1) / 10;
                assigned += weights[i];
            }
        }
    }

    function leaf(uint256 i) public view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(actors[i], weights[i]))));
    }

    function pair(bytes32 a, bytes32 b) public pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function fixtureRoot() external view returns (bytes32) {
        return pair(pair(leaf(0), leaf(1)), pair(leaf(2), leaf(3)));
    }

    function _check(bool condition) internal {
        if (!condition) violated = true;
    }

    function _outcome(bool ok, bool expected) internal {
        _check(ok == expected);
        if (ok) ++successes;
        else ++rejections;
    }

    function donate(uint256 raw) public {
        uint256 amount = bound(raw, 0, 1e30);
        token.mint(address(drop), amount);
        issued += amount;
    }

    function bind(bool unauthorized) public {
        uint256 balance = issued - paid - burned;
        bool expected = !unauthorized && !boundOnce && balance >= totalWeight;
        bool ok;
        bytes memory reason;
        if (unauthorized) {
            vm.prank(actors[4]);
            (ok, reason) = address(drop).call(abi.encodeCall(drop.bind, (uint64(3200))));
        } else {
            (ok, reason) = address(vault).call(abi.encodeCall(vault.bindAirdrop, ()));
        }
        _outcome(ok, expected);
        if (ok) {
            boundOnce = true;
            snapshotBalance = balance;
            deadline = block.timestamp + 30 days;
        } else {
            bytes4 errorSelector = unauthorized
                ? SimdAirdrop.NotVault.selector
                : boundOnce ? SimdAirdrop.AlreadyBound.selector : SimdAirdrop.InsufficientRemainder.selector;
            _check(keccak256(reason) == keccak256(abi.encodeWithSelector(errorSelector)));
        }
    }

    function advance(uint32 raw) public {
        uint256 elapsed = uint256(raw) % (3 days + 1);
        vm.warp(block.timestamp + elapsed);
        vm.roll(block.number + elapsed / 12 + 1);
    }

    function claim(uint8 actor, uint8 corruption, bool rejectTransfer) public {
        uint256 index = actor % 5;
        uint256 listedIndex = index % 4;
        uint256 weight = weights[listedIndex];
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaf(listedIndex ^ 1);
        proof[1] = listedIndex < 2 ? pair(leaf(2), leaf(3)) : pair(leaf(0), leaf(1));
        if (corruption % 3 == 1) ++weight;
        if (corruption % 3 == 2) proof[0] = bytes32(uint256(proof[0]) ^ 1);
        bool duplicate = index < 4 && hasClaimed[index];
        bool validProof = fixture && index < 4 && corruption % 3 == 0;
        bool expected = boundOnce && block.timestamp < deadline && !duplicate && validProof && !rejectTransfer;
        token.configure(0, rejectTransfer ? 2 : 0, false);
        vm.prank(actors[index]);
        (bool ok, bytes memory reason) = address(drop).call(abi.encodeCall(drop.claim, (weight, proof)));
        _outcome(ok, expected);
        if (ok) {
            uint256 amount = snapshotBalance * weight / totalWeight;
            // A valid payout must belong to one of the fixture's four listed accounts.
            if (index >= 4) {
                violated = true;
            } else {
                hasClaimed[index] = true;
                paidTo[index] += amount;
            }
            paid += amount;
        } else if (!boundOnce || block.timestamp >= deadline || duplicate || !validProof) {
            bytes4 errorSelector = !boundOnce
                ? SimdAirdrop.NotBound.selector
                : block.timestamp >= deadline
                    ? SimdAirdrop.ClaimClosed.selector
                    : duplicate ? SimdAirdrop.AlreadyClaimed.selector : SimdAirdrop.InvalidProof.selector;
            _check(keccak256(reason) == keccak256(abi.encodeWithSelector(errorSelector)));
        }
        token.configure(0, 0, false);
    }

    function burn(bool rejectTransfer) public {
        uint256 balance = issued - paid - burned;
        bool expected = boundOnce && block.timestamp >= deadline && (!rejectTransfer || balance == 0);
        token.configure(0, rejectTransfer ? 2 : 0, false);
        (bool ok, bytes memory reason) = address(drop).call(abi.encodeCall(drop.burnUnclaimed, ()));
        _outcome(ok, expected);
        if (ok) {
            burned += balance;
        } else if (!boundOnce || block.timestamp < deadline) {
            bytes4 errorSelector = !boundOnce ? SimdAirdrop.NotBound.selector : SimdAirdrop.ClaimStillOpen.selector;
            _check(keccak256(reason) == keccak256(abi.encodeWithSelector(errorSelector)));
        }
        token.configure(0, 0, false);
    }

    /// @dev Not fuzz-targeted: once funded and bound, the final balance must always be burnable.
    function settle() external {
        if (!boundOnce) {
            if (issued < totalWeight) donate(totalWeight - issued);
            bind(false);
        }
        if (block.timestamp < deadline) vm.warp(deadline);
        burn(false);
    }
}
