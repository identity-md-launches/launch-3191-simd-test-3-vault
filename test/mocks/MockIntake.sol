// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

contract MockIntake is IIntake {
    using SafeERC20 for IERC20;
    address public immutable treasury;
    uint256 public price;
    uint256 public nonce;
    bool public reject;
    bool public leaveAllowance;
    address public lastPayer;
    bytes32 public lastAction;
    bytes public lastBody;
    address public lastTarget;
    bytes4 public lastSelector;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public allowanceObserved;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryBlocked;

    constructor(address treasury_) {
        treasury = treasury_;
    }

    function configure(uint256 price_, bool reject_, bool leaveAllowance_) external {
        price = price_;
        reject = reject_;
        leaveAllowance = leaveAllowance_;
    }

    function setReentry(address to, bytes calldata data) external {
        reentryTarget = to;
        reentryData = data;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        require(!reject, "intake rejected");
        require(price > 0 && amount == price, "wrong price");
        require(body.length > 0 && body.length <= 16_384, "bad body");
        lastPayer = msg.sender;
        lastAction = action;
        lastBody = body;
        lastTarget = callback.target;
        lastSelector = callback.selector;
        lastAsset = asset;
        lastAmount = amount;
        allowanceObserved = IERC20(asset).allowance(msg.sender, address(this));
        require(allowanceObserved == amount, "not exact approval");
        IERC20(asset).safeTransferFrom(msg.sender, treasury, leaveAllowance ? amount / 2 : amount);
        if (reentryTarget != address(0)) {
            (bool ok,) = reentryTarget.call(reentryData);
            reentryBlocked = !ok;
        }
        requestId = keccak256(abi.encode(msg.sender, ++nonce));
    }
}
