// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Network} from "./Network.sol";
import {LaunchPool} from "./libraries/LaunchPool.sol";

/// @notice Immutable weighted list, funded before binding, with a thirty-day self-claim window.
contract SimdAirdrop is Network, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error NotVault();
    error InvalidAddress();
    error AlreadyBound();
    error NotBound();
    error OldLaunch();
    error InsufficientRemainder();
    error ClaimClosed();
    error ClaimStillOpen();
    error AlreadyClaimed();
    error InvalidProof();

    event Bound(uint64 indexed launchNumber, address indexed token, uint256 startBalance, uint256 claimEnd);
    event Claimed(address indexed account, uint256 weight, uint256 amount);
    event UnclaimedBurned(uint256 amount);

    bytes32 public constant MERKLE_ROOT = 0xe1fc34a5aee64c3cd01e62934929bc57511b5718c2f5ae80072ae25045e50cb4;
    uint256 public constant TOTAL_WEIGHT = 633028988023500000000000000;
    uint256 public constant WALLET_COUNT = 457;
    uint256 public constant CLAIM_DURATION = 30 days;
    uint64 public constant MIN_LAUNCH_EXCLUSIVE = 3187;
    address public immutable vault;
    address public token;
    uint64 public launchNumber;
    uint256 public startBalance;
    uint256 public claimEnd;
    mapping(address => bool) public claimed;

    constructor(address vault_) {
        if (vault_ == address(0)) revert InvalidAddress();
        vault = vault_;
    }

    function bind(uint64 number) external nonReentrant {
        if (msg.sender != vault) revert NotVault();
        if (token != address(0)) revert AlreadyBound();
        if (number <= MIN_LAUNCH_EXCLUSIVE) revert OldLaunch();
        address launchedToken = LaunchPool.tokenOf(FACTORY, number, vault, IMD);
        uint256 balance = IERC20(launchedToken).balanceOf(address(this));
        if (balance < TOTAL_WEIGHT) revert InsufficientRemainder();
        token = launchedToken;
        launchNumber = number;
        startBalance = balance;
        claimEnd = block.timestamp + CLAIM_DURATION;
        emit Bound(number, launchedToken, balance, claimEnd);
    }

    function amountOf(uint256 weight) public view returns (uint256) {
        return Math.mulDiv(startBalance, weight, TOTAL_WEIGHT);
    }

    function claim(uint256 weight, bytes32[] calldata proof) external nonReentrant {
        if (token == address(0)) revert NotBound();
        if (block.timestamp >= claimEnd) revert ClaimClosed();
        if (claimed[msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, weight))));
        if (!MerkleProof.verifyCalldata(proof, MERKLE_ROOT, leaf)) revert InvalidProof();
        claimed[msg.sender] = true;
        uint256 amount = amountOf(weight);
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, weight, amount);
    }

    /// @notice Re-callable after the deadline so late token donations can also be burned.
    function burnUnclaimed() external nonReentrant {
        if (token == address(0)) revert NotBound();
        if (block.timestamp < claimEnd) revert ClaimStillOpen();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(DEAD, amount);
        emit UnclaimedBurned(amount);
    }
}
