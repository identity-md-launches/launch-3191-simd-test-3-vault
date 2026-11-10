// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDVault} from "../src/SIMDVault.sol";

contract ConstructionProbe {
    function deploy(bytes32 salt) external returns (SIMDVault) {
        return new SIMDVault{salt: salt}();
    }
}

contract DeploymentTest is Test {
    function test_factoryConstructionLinksFourBoundedContractsWithoutEscapeOpcodesOrOwners() public {
        // Empty external chain state, and a contract (not an EOA) is the constructor's caller.
        ConstructionProbe factory = new ConstructionProbe();
        SIMDVault vault = factory.deploy(keccak256("deployment rehearsal"));
        address[4] memory applications =
            [address(vault), address(vault.stakeRewards()), address(vault.jobsVault()), address(vault.airdrop())];
        assertEq(vault.stakeRewards().vault(), address(vault));
        assertEq(vault.jobsVault().vault(), address(vault));
        assertEq(vault.airdrop().vault(), address(vault));
        for (uint256 i; i < applications.length; ++i) {
            bytes memory code = applications[i].code;
            assertGt(code.length, 0);
            assertLe(code.length, 24_576);
            (bool hasOwner,) = applications[i].staticcall(abi.encodeWithSignature("owner()"));
            assertFalse(hasOwner);
            // Same reachable-opcode floor as the supplied deployment checks, applied to children too.
            bool reachable = true;
            for (uint256 j; j < code.length; ++j) {
                uint8 op = uint8(code[j]);
                if (op == 0x5b) reachable = true;
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                if (reachable) assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
                if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) {
                    reachable = false;
                }
            }
        }
    }
}
