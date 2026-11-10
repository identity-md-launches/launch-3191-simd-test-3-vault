// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILaunchFactory, PoolKey} from "../../src/interfaces/ILaunchFactory.sol";

contract MockFactory is ILaunchFactory {
    struct Position {
        PoolKey key;
        address requester;
    }
    mapping(uint64 => Position) private positions;
    uint256 public fee0;
    uint256 public fee1;
    uint256 public nativeFee;
    uint256 public claimCalls;
    uint8 public mode;
    bool public reentryBlocked;

    function setPosition(uint64 n, address a, address b, address requester) external {
        positions[n] = Position(PoolKey(a, b, 3000, 60, address(0)), requester);
    }

    function configure(uint256 a, uint256 b, uint256 ethAmount, uint8 mode_) external {
        fee0 = a;
        fee1 = b;
        nativeFee = ethAmount;
        mode = mode_;
    }

    function positionOf(uint64 n) external view returns (PoolKey memory, int24, int24, address) {
        return (positions[n].key, -60, 60, positions[n].requester);
    }

    function claimFees(uint64 n) external returns (uint256, uint256) {
        if (mode == 1) revert("claim failed");
        if (mode == 2) {
            assembly { invalid() }
        }
        Position storage p = positions[n];
        ++claimCalls;
        uint256 a = fee0;
        uint256 b = fee1;
        uint256 e = nativeFee;
        fee0 = 0;
        fee1 = 0;
        nativeFee = 0;
        if (a != 0) require(IERC20(p.key.currency0).transfer(p.requester, a));
        if (b != 0) require(IERC20(p.key.currency1).transfer(p.requester, b));
        if (e != 0) {
            (bool sent,) = p.requester.call{value: e}("");
            require(sent);
        }
        if (mode == 3) {
            (bool ok,) = p.requester.call(abi.encodeWithSignature("distribute()"));
            reentryBlocked = !ok;
        }
        return (a, b);
    }
    receive() external payable {}
}

contract RejectNative {
    receive() external payable {
        revert("no ETH");
    }
}

contract ExhaustNative {
    receive() external payable {
        assembly { invalid() }
    }
}
