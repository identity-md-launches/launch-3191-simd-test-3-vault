// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev ABI-equivalent to Uniswap v4's PoolKey; Currency and IHooks encode as addresses.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface ILaunchFactory {
    function positionOf(uint64 launchNumber)
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, address requester);
    function claimFees(uint64 launchNumber) external returns (uint256 amount0, uint256 amount1);
}
