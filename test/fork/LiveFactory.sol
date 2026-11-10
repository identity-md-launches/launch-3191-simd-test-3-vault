// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey, ILaunchFactory} from "../../src/interfaces/ILaunchFactory.sol";

/// @dev Test-only ABI transcribed from the named factory's Sourcify-verified source.
interface ILiveFactory is ILaunchFactory {
    struct Record {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct LaunchParams {
        uint64 launchNumber;
        bytes32 kind;
        bytes tokenCreationCode;
        bytes hookCreationCode;
        bytes32 hookSalt;
        uint160 hookFlags;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        address pairedCurrency;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        Record record;
        uint256[] agentIds;
        address requester;
    }
    function deployer() external view returns (address);
    function poolManager() external view returns (address);
    function predictToken(uint64 number, bytes calldata code) external view returns (address);
    function launch(LaunchParams calldata params) external returns (address token, address hook, address distributor);
    function setRequester(uint64 number, address next) external;
}

/// @dev Exists only on a disposable fork. It is not part of the deliverable's application contracts.
contract ForkLaunchToken is ERC20 {
    constructor() ERC20("SIMD fork fixture - DO NOT BUY", "FIX") {
        _mint(msg.sender, 1e30);
    }
}

contract ForkInitHook {
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return this.beforeInitialize.selector;
    }
}

interface IForkPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (int256 delta);
    function sync(address token) external;
    function settle() external payable returns (uint256);
    function take(address token, address to, uint256 amount) external;
}

/// @dev Executes a real swap against the live v4 manager to generate actual requester LP fees.
contract ForkSwapActor {
    IForkPoolManager public immutable manager;

    constructor(address manager_) {
        manager = IForkPoolManager(manager_);
    }

    function swap(PoolKey calldata key, bool zeroForOne, uint160 limit) external {
        manager.unlock(abi.encode(key, zeroForOne, limit));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (PoolKey memory key, bool zeroForOne, uint160 limit) = abi.decode(data, (PoolKey, bool, uint160));
        int256 delta = manager.swap(key, IForkPoolManager.SwapParams(zeroForOne, -int256(1e24), limit), "");
        _settle(key.currency0, int128(delta >> 128));
        _settle(key.currency1, int128(delta));
        return "";
    }

    function _settle(address currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            require(IERC20(currency).transfer(address(manager), uint256(uint128(-delta))));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}
