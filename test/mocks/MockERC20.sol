// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable precision;
    uint256 public feeBps;
    uint8 public transferMode;
    bool public rejectBalance;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackBlocked;

    constructor(uint8 decimals_) ERC20("Fixture token", "FIX") {
        precision = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return precision;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(uint256 fee, uint8 mode, bool badBalance) external {
        feeBps = fee;
        transferMode = mode;
        rejectBalance = badBalance;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(!rejectBalance, "balance rejected");
        return super.balanceOf(account);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transferMode == 1) revert("transfer rejected");
        if (transferMode == 2) return false;
        if (transferMode == 4) {
            assembly { invalid() }
        }
        _callback();
        bool ok = super.transfer(to, amount);
        if (transferMode == 3) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (transferMode == 5) {
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _callback();
        return super.transferFrom(from, to, amount);
    }

    function _callback() private {
        if (callbackTarget != address(0)) {
            (bool ok,) = callbackTarget.call(callbackData);
            callbackBlocked = !ok;
        }
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = amount * feeBps / 10_000;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}
