// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Network} from "./Network.sol";
import {StakeRewards} from "./StakeRewards.sol";
import {IntakePayment} from "./libraries/IntakePayment.sol";

/// @notice Stakers may spend this vault's IMD on one job per wallet per day.
contract JobsVault is Network, ReentrancyGuard {
    error NotVault();
    error AlreadySet();
    error InvalidToken();
    error InvalidAddress();
    error TokenNotSet();
    error InsufficientStake();
    error TooSoon(uint256 availableAt);
    error InvalidBody();

    event TokenSet(address indexed token, uint256 minimumStake);
    event JobRequested(address indexed account, bytes32 indexed requestId, uint256 price, uint256 lockedUntil);

    bytes32 public constant ACTION = bytes32("job.open@job-1");
    uint256 public constant COOLDOWN = 24 hours;
    uint256 public constant MAX_BODY_BYTES = 16_384;
    uint256 public constant MIN_WHOLE_TOKENS = 1_000_000;
    address public immutable vault;
    StakeRewards public immutable stakeRewards;
    address public token;
    uint256 public minimumStake;
    mapping(address => uint256) public nextJobAt;

    constructor(address vault_, StakeRewards stakeRewards_) {
        if (vault_ == address(0) || address(stakeRewards_) == address(0)) revert InvalidAddress();
        vault = vault_;
        stakeRewards = stakeRewards_;
    }

    function setToken(address token_) external {
        if (msg.sender != vault) revert NotVault();
        if (token != address(0)) revert AlreadySet();
        if (token_ == IMD || token_.code.length == 0) revert InvalidToken();
        uint8 decimals = IERC20Metadata(token_).decimals();
        // 1,000,000 * 10**72 does not fit uint256.
        if (decimals > 71) revert InvalidToken();
        token = token_;
        minimumStake = MIN_WHOLE_TOKENS * 10 ** uint256(decimals);
        emit TokenSet(token_, minimumStake);
    }

    function requestJob(bytes calldata body) external nonReentrant returns (bytes32 requestId) {
        if (token == address(0)) revert TokenNotSet();
        if (body.length == 0 || body.length > MAX_BODY_BYTES) revert InvalidBody();
        if (stakeRewards.stakeOf(msg.sender) < minimumStake) revert InsufficientStake();
        if (block.timestamp < nextJobAt[msg.sender]) revert TooSoon(nextJobAt[msg.sender]);
        uint256 until = block.timestamp + COOLDOWN;
        nextJobAt[msg.sender] = until;
        stakeRewards.lock(msg.sender, until);
        uint256 price;
        (requestId, price) = IntakePayment.request(INTAKE, IMD, ACTION, body);
        emit JobRequested(msg.sender, requestId, price, until);
    }
}
