// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SimdAirdrop} from "../../src/SimdAirdrop.sol";

/// @dev The brief supplies a root but no wallet/proof dataset. Positive-path tests replace ONLY
/// that 32-byte constant in deployed test bytecode with a synthetic two-leaf root. No production
/// setter, override, alternate implementation, or pretend proof for the committed root exists.
abstract contract MerkleFixture is Test {
    function _leaf(address account, uint256 weight) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, weight))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _installFixtureRoot(SimdAirdrop drop, bytes32 root) internal {
        bytes32 original = drop.MERKLE_ROOT();
        bytes memory code = address(drop).code;
        uint256 replacements;
        for (uint256 i; i + 32 <= code.length; ++i) {
            bytes32 word;
            assembly ("memory-safe") { word := mload(add(add(code, 32), i)) }
            if (word == original) {
                assembly ("memory-safe") { mstore(add(add(code, 32), i), root) }
                ++replacements;
                i += 31;
            }
        }
        assertGt(replacements, 0, "root constant not found in bytecode");
        vm.etch(address(drop), code);
        assertEq(drop.MERKLE_ROOT(), root);
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }
}
