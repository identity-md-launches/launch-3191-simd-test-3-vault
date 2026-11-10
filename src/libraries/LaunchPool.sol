// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILaunchFactory, PoolKey} from "../interfaces/ILaunchFactory.sol";

library LaunchPool {
    error WrongRequester();
    error InvalidPair();

    function tokenOf(address factory, uint64 number, address vault, address imd) internal view returns (address token) {
        (PoolKey memory key,,, address requester) = ILaunchFactory(factory).positionOf(number);
        if (requester != vault) revert WrongRequester();
        if (key.currency0 == imd) token = key.currency1;
        else if (key.currency1 == imd) token = key.currency0;
        else revert InvalidPair();
        if (token == imd || token.code.length == 0) revert InvalidPair();
    }
}
