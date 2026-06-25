// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Fee-on-transfer ERC20 for tests: burns `feeBps` of every transfer to a
///      sink so the recipient receives less than the sent amount.
contract MockFeeToken is ERC20 {
    uint256 public immutable feeBps;
    address internal constant SINK = address(0xFEE);

    constructor(uint256 _feeBps) ERC20("Fee", "FEE") {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, SINK, fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}
