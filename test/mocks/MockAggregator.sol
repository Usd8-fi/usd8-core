// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev Minimal Chainlink-style feed for testing the cover-asset size cap.
contract MockAggregator {
    int256 public answer;
    uint8 public decimals;
    bool public broken;

    constructor(int256 _answer, uint8 _decimals) {
        answer = _answer;
        decimals = _decimals;
    }

    function setAnswer(int256 a) external {
        answer = a;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (1, answer, 0, 0, 1);
    }
}
