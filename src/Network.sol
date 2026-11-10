// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed dependencies of this test launch on Robinhood Chain (4663).
abstract contract Network {
    string public constant NOTICE = "TEST ONLY. SIMD TEST 3 vault set. Not the real SIMD. Do not buy.";
    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address public constant FACTORY = 0xA25B02A1e93903b790E6aaf7dA1b8B8d50294645;
    address public constant DEV = 0xdFA1f1F6FEAA04F7874efF0b7754b7FFaEBd8BC0;
    address public constant MARKETING = DEV;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
}
