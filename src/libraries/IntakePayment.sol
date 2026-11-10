// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IIntake} from "../interfaces/IIntake.sol";

library IntakePayment {
    using SafeERC20 for IERC20;
    error ActionNotSold();

    function request(address intake, address asset, bytes32 action, bytes calldata body)
        internal
        returns (bytes32 requestId, uint256 price)
    {
        price = IIntake(intake).priceOf(action, asset);
        if (price == 0) revert ActionNotSold();
        IERC20(asset).forceApprove(intake, price);
        requestId = IIntake(intake).request(action, body, IIntake.Callback(address(0), bytes4(0)), asset, price);
        IERC20(asset).forceApprove(intake, 0);
    }
}
